use v5.10.0;
use strict;
use warnings;

package App::grindperl;
# VERSION

use autodie;
use Getopt::Lucid ':all';
use Path::Class;
use Carp qw/carp croak/;
use File::Copy qw/copy/;
use File::HomeDir 0.98;
use namespace::autoclean;

sub new {
  my $class = shift;

  my $self = bless {}, $class;

  if ( -r $self->config_file ) {
    unshift @ARGV, $self->read_config_file;
  }

  my $opt = Getopt::Lucid->getopt([
    Param("jobs|j")->default(9),
    Param("testjobs|t")->default(9),
    Param("output|o"),
    Param("install_root")->default("/tmp"),
    Param("prefix"),
    Switch("debugging")->default(1),
    Switch("threads")->default(1),
    Switch("porting|p"),
    Switch("install"),
    Switch("config"),
    Switch("cache"),
    Switch("man"),
    Switch("edit"),
    Switch("verbose|v"),
    Keypair("define|D"),
    List("undefine|U"),
  ]);

  $self->{opt} = $opt;
  $self->{is_git} = -d '.git';

  return $self;
}

sub opt { return $_[0]->{opt} }

sub is_git { return $_[0]->{is_git} }

sub logfile { return $_[0]->opt->get_output };

sub vlog {
  my ($self, @msg) = @_;
  return unless $self->opt->get_verbose;
  say for map { (my $s = $_) =~ s/\n$//; $s } @msg;
}

sub prefix {
  my $self = shift;
  my $prefix = $self->opt->get_prefix;
  return $prefix if defined $prefix && length $prefix;

  my $root = $self->opt->get_install_root;

  if ( $self->is_git ) {
    my $branch = qx/git symbolic-ref HEAD/;
    if ( $? ) {
      # HEAD not a symbolic ref?
      $branch = "fromgit";
    }
    els {
      chomp $branch;
      $branch =~ s{refs/heads}{};
      $branch =~ s{/}{-}g;
    }
    my $describe = qx/git describe/;
    chomp $describe;
    return "$root/$branch-$describe";
  }
  else {
    my $perldir = dir()->absolute->basename;
    return "$root/$perldir-" . time();
  }
}

sub configure_args {
  my ($self) = @_;
  my %defines = $self->opt->get_define;
  my @undefines = $self->opt->get_undefine;
  my @args = qw/-des -Dusedevel/;
  push @args, "-Dusethreads" if $self->opt->get_threads;
  push @args, "-DDEBUGGING" if $self->opt->get_debugging;
  push @args, "-r" if $self->opt->get_cache;
  if ( ! $self->opt->get_man ) {
    push @args, qw/-Dman1dir=none -Dman3dir=none/;
  }
  push @args, map { "-D$_=$defines{$_}" } keys %defines;
  push @args, map { "-U$_" } @undefines;
  push @args, "-Dprefix=" . $self->prefix;
  return @args;
}

sub cache_dir {
  my ($self) = @_;
  return dir(File::HomeDir->my_dist_data(__PACKAGE__, {create=>1}))->stringify;
}

sub cache_file {
  my ($self,$file) = @_;
  croak "No filename given to cache_file()"
    unless defined $file && length $file;
  return file( $self->cache_dir, $file )->stringify;
}

sub config_file {
  my ($self) = @_;
  my $config_dir = dir(File::HomeDir->my_dist_config(__PACKAGE__, {create=>1}));
  return $config_dir->file("config");
}

sub read_config_file {
  my ($self) = @_;
  open my $fh, "<", $self->config_file;
  return map { chomp; $_ } <$fh>;
}

sub do_cmd {
  my ($self, $cmd, @args) = @_;

  my $cmdline = join( q{ }, $cmd, @args);
  if ( $self->logfile ) {
    $cmdline .= " >" . $self->logfile . " 2>&1";
  }
  $self->vlog("Running '$cmdline'");
  system($cmdline);
  return $? == 0;
}

sub verify_dir {
  my ($self) = @_;
  my $prefix = dir($self->prefix);
  return -w $prefix->dirname;
}

sub configure {
  my ($self) = @_;
  croak("Executable Configure program not found") unless -x "Configure";

  # used cached files
  for my $f ( qw/config.sh Policy.sh/ ) {
    next unless -f $self->cache_file($f);
    if ( $self->opt->get_cache ) {
      copy( $self->cache_file($f), $f );
      if ( -f $f ) {
        $self->vlog("Copied $f from cache");
      }
      else {
        $self->vlog("Faild to copy $f from cache");
      }
    }
    else {
      unlink $self->cache_file($f);
    }
  }

  $self->do_cmd( "./Configure", $self->configure_args )
    or croak("Configure failed!");

  # save files back into cache if updated
  dir( $self->cache_dir )->mkpath;
  for my $f ( qw/config.sh Policy.sh/ ) {
    copy( $f, $self->cache_file($f) )
      if (! -f $self->cache_file($f)) || (-M $f > -M $self->cache_file($f));
  }

  return 1;
}

sub run {
  my ($self) = @_;

  if ( $self->opt->get_edit ) {
    my $cf_file = $self->config_file;
    if ( $ENV{EDITOR} ) {
      system( $ENV{EDITOR}, $cf_file )
          and die "Error editing config file: $!\n";
    }
    else {
      say "No EDITOR set. Edit $cf_file manually.";
    }
    exit 0;
  }

  croak "Doesn't look like a perl source dirctory" unless -f "perl.c";

  $self->verify_dir
    or croak($self->prefix . " does not appear to be writable");

  if ( $self->is_git ) {
    $self->do_cmd("git clean -dxf")
  }
  else {
    $self->do_cmd("make distclean") if -f 'Makefile';
  }

  $self->configure;

  exit 0 if $self->opt->get_config; # config only

  my $test_jobs = $self->opt->get_testjobs;
  my $jobs = $self->opt->get_jobs;

  if ( $test_jobs ) {
    $ENV{TEST_JOBS} = $test_jobs if $test_jobs > 1;

    if ( $self->opt->get_porting ) {
      $self->vlog("Running 'make test_porting' with $test_jobs jobs");
      $self->do_cmd("make -j $jobs test_porting")
        or croak ("make test_porting failed");
    }
    else {
      $self->vlog("Running 'make test_harness' with $test_jobs jobs");
      $self->do_cmd("make -j $jobs test_harness")
        or croak ("make test_harness failed");
    }
  }
  else {
    $self->vlog("Running 'make test_prep' with $test_jobs jobs");
    $self->do_cmd("make -j $jobs test_prep")
      or croak("make test_prep failed!");
  }

  if ( $self->opt->get_install ) {
    $self->vlog("Running 'make install'");
    $self->do_cmd("make install")
      or croak("make install failed!");
  }

  return 1;
}

1;

# ABSTRACT:  Guts of the grindperl tool

=for Pod::Coverage
new
opt
is_git
logfile
vlog
default_args
prefix
configure_args
cache_dir
cache_file
config_file
read_config_file
do_cmd
verify_dir
configure
run

=begin wikidoc

= SYNOPSIS

  use App::grindperl;
  my $app = App::grindperl->new;
  exit $app->run;

= DESCRIPTION

This module contains the guts of the [grindperl] program.

= SEE ALSO

[grindperl]

=end wikidoc

=cut

# vim: ts=2 sts=2 sw=2 et: