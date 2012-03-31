package WWW::CPANGrep::Index::Worker;
use Moose;
use namespace::autoclean;

use JSON;
use CPAN::Visitor;
use File::MMagic::XS;
use WWW::CPANGrep::Slabs;
use File::Basename qw(dirname);

with 'WWW::CPANGrep::Role::RedisConnection';

has cpan_dir => (
  is => 'ro',
  isa => 'Str',
);

has slab_dir => (
  is => 'ro',
  isa => 'Str',
);

has jobs => (
  is => 'ro',
  isa => 'Int'
);

has _slab => (
  is => 'rw',
  isa => 'WWW::CPANGrep::Slabs',
  lazy => 1,
  default => sub {
    my($self) = @_;
    WWW::CPANGrep::Slabs->new(
      dir => $self->slab_dir,
      redis => $self->redis);
  }
);

has _mmagic => (
  is => 'ro',
  isa => 'File::MMagic::XS',
  default => sub {
    my $dir = dirname(__FILE__);
    # Magic shipped with File::MMagic::XS misses things like BDB databases...
    File::MMagic::XS->new($dir . "/magic");
  }
);

sub run {
  my($self, $queue) = @_;

  # Do not call ->redis before this forks.
  # (XXX: Probably should make Tie::Redis handle this somehow).

  for(1 .. ($self->jobs - 1)) {
    my $pid = fork;
    if($pid) {
      next;
    } else {
      last;
    }
  }

  my $redis_conn = (tied %{$self->redis})->{_conn};
  $redis_conn->incr("cpangrep:indexer");

  while(my $dist = pop @{$self->redis->{$queue}}) {
    print "Processing $dist\n";

    CPAN::Visitor->new(
      cpan => $self->cpan_dir,
      files => [$dist]
    )->iterate(
      visit => sub { $self->index_dist($dist, @_) },
      jobs => 0,
    );
  }

  my $name = $self->_slab->finish;

  # Tie::Redis currently won't autovivify :(
  $self->redis->{"new-index"} ||= [];
  push @{$self->redis->{"new-index"}}, @{$self->redis->{$name}};

  if($redis_conn->decr("cpangrep:indexer") == 0) {
    eval { $redis_conn->rename("cpangrep:slabs", "cpangrep:slabs-old") };
    $redis_conn->rename("new-index", "cpangrep:slabs");
    $redis_conn->save;

    for my $slab(@{$self->redis->{"cpangrep:slabs-old"}}) {
      unlink $self->slab_dir . "/" . $slab;
    }
  }
}

sub index_dist {
  my($self, $dist, $cpanv_job) = @_;
  # We're now in the right directory

  my @files;
  File::Find::find {
    no_chdir => 1,
    wanted => sub {
      s{^./}{};
      push @files, $_ if -f;
    }
  }, ".";

  my $redis_conn = (tied %{$self->redis})->{_conn};

  for my $file(@files) {
    next if $file eq 'MANIFEST';
    my $mime_type = $self->_mmagic->get_mime($file);
    $redis_conn->hincrby("mime_stats", $mime_type, 1);

    if($mime_type !~ /^text/) {
      warn "Ignoring binary file $file ($mime_type, in $dist)\n";
    } else {
      $self->_slab->index($dist, $file);
    }
  }
}

__PACKAGE__->meta->make_immutable;

1;
