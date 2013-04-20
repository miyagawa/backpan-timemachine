#!/usr/bin/env perl
use strict;
use 5.012;
use Dist::Metadata;
use App::Cache;

package BPTM::CLI;
use Moo;
use MooX::late;
use File::Find ();
use Time::Piece ();
use Try::Tiny;
use Path::Tiny ();
use Log::Minimal;
use File::pushd ();

has cache => (is => 'lazy');
has backpan => (is => 'ro', coerce => sub { Path::Tiny::path($_[0]) });
has destination => (is => 'ro', coerce => sub { Path::Tiny::path($_[0]) });
has perms => (is => 'lazy');
has state => (is => 'lazy');

sub _build_cache { App::Cache->new({ ttl => 60 * 60 * 24 }) }

sub _build_perms {
    my $self = shift;

    infof "Downloading 06perms.txt from CPAN. This might take some time.";
    my $txt = $self->cache->get_url("http://www.cpan.org/modules/06perms.txt");
    BPTM::Permissions->new(text => $txt);
}

sub _build_state { BPTM::State->new }

sub run {
    my $self = shift;
    $self->git_init($self->destination);
    # TODO load from state, only newer files
    $self->find_iter(sub { $self->examine_file(@_) });
}

sub git_init {
    my($self, $dir) = @_;

    $dir->mkpath;
    unless ($dir->child('.git')->exists) {
        my $pushd = File::pushd::pushd($dir);
        system 'git', 'init';
    }
}

sub find_iter {
    my($self, $code) = @_;

    my @files;
    my $wanted = sub {
        my @stat = stat $_;
        return unless -f _ && /\.(?:tar\.gz|tar\.bz2|tgz|zip)$/;
        push @files, [ $_, $stat[9] ];
    };
    File::Find::find({ wanted => $wanted, no_chdir => 1 }, $self->backpan->child('authors'));

    for my $file (sort { $a->[1] <=> $b->[1] } @files) {
        my $archive = BPTM::Archive->new(path => $file->[0], mtime => Time::Piece->new($file->[1]));
        try { $code->($archive) }
        catch { warnf "Got an error: $_" };
    }
}

sub examine_file {
    my($self, $archive) = @_;

    infof 'Examining file %s', $archive->path;

    my $versions = $archive->package_versions;

    while (my($pkg, $ver) = each %$versions) {
        my $package = BPTM::Package->new(
            package => $pkg,
            version => $ver // 'undef',
            distinfo => $archive->distinfo,
            mtime   => $archive->mtime,
        );
        if ($self->perms->has_permission($package)) {
            $package->pass;
            $self->state->add($package);
        } else {
            $package->fail;
            $self->state->add($package);
        }
    }

    $self->state->dump_files($self->destination);
    $self->git_commit($archive);
}

sub git_commit {
    my($self, $archive) = @_;

    my $pushd = File::pushd::pushd($self->destination);
    system 'git', 'add', '.';
    system 'git', 'commit', '-q', '-m', $archive->distvname,
      '--author', $archive->git_author,
      '--date', $archive->epoch . " +0000";
}

package BPTM::PAUSEText;
use Moo::Role;

has headers => (is => 'rw', default => sub { +{} });

sub parse_text {
    my($self, $cb) = @_;

    my $txt = $self->text;

    my $in_headers = 1;
    my $curr_hdr;

    while ($txt =~ /^(.*)$/mg) {
        my $chunk = $1;
        if ($in_headers) {
            if ($chunk =~ /^\s*$/) {
                $in_headers = 0;
            } elsif ($chunk =~ s/^\s+//) {
                $self->headers->{$curr_hdr} .= " $chunk";
            } elsif ($chunk =~ /^(\S+):\s*(.*?)$/) {
                $curr_hdr = $1;
                $self->headers->{$curr_hdr} = $2;
            }
        } else {
            $cb->($1);
        }
    }
}

package BPTM::Permissions;
use Moo;
use MooX::late;
with 'BPTM::PAUSEText';

has text => (is => 'ro', isa => 'Str');
has packages => (is => 'lazy');

sub _build_packages {
    my $self = shift;

    my $pkgs = {};
    $self->parse_text(sub {
        my($package, $id, $flag) = split /,/, $_[0], 3;
        $pkgs->{$package, $id} = $flag;
    });

    $pkgs;
}

sub has_permission {
    my($self, $package) = @_;
    # 06perms has no timestamps, so assume everyone who has the perm
    # now had the perm at that point.
    exists $self->packages->{$package->package, $package->cpanid};
}

package BPTM::Package;
use Moo;
use MooX::late;

has package => (is => 'rw', isa => 'Str');
has package_lc => (is => 'lazy');
has version => (is => 'rw');
has distinfo => (is => 'ro', handles => [qw( cpanid )]);
has mtime   => (is => 'ro', handles => [qw( epoch )]);
has status  => (is => 'rw', isa => 'Str');

sub _build_package_lc {
    my $self = shift;
    lc $self->package;
}

sub pass {
    my $self = shift;
    $self->status('pass');
}

sub fail {
    my $self = shift;
    $self->status('fail');
}

sub distfile {
    my $self = shift;
    $self->distinfo->pathname =~ m{^authors/id/(.*)$}
      and return $1;
}

package BPTM::State;
use Moo;
use MooX::late;
use Log::Minimal;

has packages => (is => 'ro', default => sub { [] });
has effective_packages => (is => 'ro', default => sub { +{} });
has last_updated => (is => 'rw');

sub add {
    my($self, $package) = @_;
    push @{$self->packages}, $package;
    $self->update_effective($package);
    $self->last_updated( $package->epoch );
}

sub update_effective {
    my($self, $package) = @_;

    my $pkgs = $self->effective_packages;

    # Compare with the previous version
    # If it's bigger, add a new distpath - version mapping
    # If it's the same, bump the distpath
    # If it's smaller, ignore it

    if (my $existing = $pkgs->{$package->package}) {
        my $new_ver = version->new($package->version);
        if ($new_ver >= version->new($existing->version)) {
            $pkgs->{$package->package} = $package;
        } else {
            warnf "%s has a higher version %s (> %s) in %s. Skipping",
              $package->package, $existing->version, $package->version, $package->distfile;
        }
    } else {
        $pkgs->{$package->package} = $package;
    }
}

sub sorted_effective_packages {
    my $self = shift;

    my $pkgs = $self->effective_packages;
    map $pkgs->{$_}, sort { $pkgs->{$a}->package_lc cmp $pkgs->{$b}->package_lc } keys %$pkgs;
}

sub dump_files {
    my($self, $dir) = @_;

    # TODO only update new files to .state
    $dir->child('backpan-timemachine.state')->spew($self->dump);
    $dir->child('02packages.details.txt')->spew($self->packages_txt);
}

sub dump {
    my $self = shift;
    my $text;
    for my $pkg (@{$self->packages}) {
        $text .= join "\t", $pkg->status, $pkg->package, $pkg->version, $pkg->distfile, $pkg->epoch;
        $text .= "\n";
    }
    $text;
}

sub packages_txt {
    my $self = shift;

    my @packages = $self->sorted_effective_packages;

    my $text = <<EOF;
File:         02packages.details.txt
URL:          http://www.perl.com/CPAN/modules/02packages.details.txt
Description:  Package names found in directory \$CPAN/authors/id/
Columns:      package name, version, path
Intended-For: Automated fetch routines, namespace documentation.
Written-By:   backpan-timemachine
Line-Count:   @{[ $#packages + 1 ]}
Last-Updated: @{[ scalar localtime $self->last_updated ]}

EOF
    for my $p (@packages) {
        $text .= sprintf "%-30s %8s  %s\n", $p->package, $p->version, $p->distfile;
    }

    return $text;
}

package BPTM::Archive;
use Moo;
use MooX::late;
use Try::Tiny;
use CPAN::DistnameInfo;
use Dist::Metadata ();

has path => (is => 'ro');
has mtime => (is => 'ro', handles => [qw( epoch )]);
has metadata => (is => 'lazy');
has distinfo => (is => 'lazy', handles => [qw( cpanid distvname )]);

sub _build_metadata {
    my $self = shift;
    Dist::Metadata->new(file => $self->path);
}

sub _build_distinfo {
    my $self = shift;
    $self->path =~ m!(authors/id/.*)$!
      and CPAN::DistnameInfo->new($1);
}

sub package_versions {
    my $self = shift;

    # 05:38 alh: YOu might want to put a alarm(5) around the ->package_versions
    # 05:39 alh: Otherwise it may run forever when it hits Acme-BadExample-1.01/lib/Acme/BadExample.pm
    my $provides;
    try {
        local $SIG{__WARN__} = sub {};
        local $SIG{ALRM} = sub { die "ALARM\n" };
        alarm 30;
        $provides = $self->metadata->provides;
        alarm 0;
    } catch {
        $self->provides_ignoring_dist_version;
    };

    $self->metadata->package_versions($provides);
}

sub provides_ignoring_dist_version {
    my $self = shift;

    my $meta = $self->metadata->determine_metadata;
    $meta->{version} = '0'; # dist paths might have bad version like 'a1'
    $self->metadata->determine_packages($self->metadata->meta_from_struct($meta));
}

sub git_author {
    my $self = shift;
    sprintf '%s <%s@cpan.org>', $self->cpanid, lc($self->cpanid);
}

package main;

my($backpan_src, $dest) = @ARGV;
BPTM::CLI->new(backpan => $backpan_src, destination => $dest)->run;
