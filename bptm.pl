#!/usr/bin/env perl
use strict;
use Dist::Metadata;
use App::Cache;

package BPTM::CLI;
use Moo;
use MooX::late;
use File::Find ();
use Time::Piece ();
use Try::Tiny;
use Log::Minimal;

has cache => (is => 'lazy');
has backpan => (is => 'ro');
has perms => (is => 'lazy');

sub _build_cache   { App::Cache->new({ ttl => 60 * 60 * 24 }) }

sub _build_perms {
    my $self = shift;

    infof("Downloading 06perms.txt from CPAN. This might take some time.");
    my $txt = $self->cache->get_url("http://www.cpan.org/modules/06perms.txt");
    BPTM::Permissions->new(text => $txt);
}

sub run {
    my $self = shift;
    $self->find_iter(sub { $self->examine_file(@_) });
}

sub find_iter {
    my($self, $code) = @_;

    my @files;
    my $wanted = sub {
        my @stat = stat $_;
        return unless -f _ && /\.(?:tar\.gz|tar\.bz2|tgz|zip)$/;
        push @files, [ $_, $stat[9] ];
    };
    File::Find::find({ wanted => $wanted, no_chdir => 1 }, $self->backpan . '/authors');

    for my $file (sort { $a->[1] <=> $b->[1] } @files) {
        my $archive = BPTM::Archive->new(path => $file->[0], mtime => Time::Piece->new($file->[1]));
        $code->($archive);
    }
}

sub examine_file {
    my($self, $archive) = @_;

    infof('Examining file %s', $archive->path);

    my $versions;
    try {
        # 05:38 alh: YOu might want to put a alarm(5) around the ->package_versions
        # 05:39 alh: Otherwise it may run forever when it hits Acme-BadExample-1.01/lib/Acme/BadExample.pm
        $versions = $archive->package_versions;
    } catch {
        warnf("Got an error: $_");
    };

    return unless $versions;

    while (my($package, $version) = each %$versions) {
        if ($self->perms->has_permission($archive->pause_id, $package)) {
            infof("%s (%s) by %s", $package, $version || 'undef', $archive->pause_id);
            # Compare with the previous version
            # If it's bigger, add a new distpath - version mapping
            # If it's the same, bump the distpath
            # If it's smaller, ignore it
        } else {
            warnf("%s has no perms on %s", $archive->pause_id, $package);
        }
    }
}

package BPTM::Permissions;
use Moo;
use MooX::late;

has text => (is => 'ro', isa => 'Str');
has packages => (is => 'lazy');

sub _build_packages {
    my $self = shift;

    my $txt = $self->text;
    $txt =~ s/^.*?\n\n//sg;

    my $pkg = {};

    while ($txt =~ /^(.*)$/mg) {
        my($package, $id, $flag) = split /,/, $1, 3;
        $pkg->{$package, $id} = $flag;
    }

    $pkg;
}

sub has_permission {
    my($self, $pause_id, $package) = @_;
    # 06perms has no timestamps, so assume everyone who has the perm
    # now had the perm at that point.
    exists $self->packages->{$package, $pause_id};
}

package BPTM::Archive;
use Moo;
use MooX::late;
use Dist::Metadata ();

has path => (is => 'ro');
has mtime => (is => 'ro');
has metadata => (is => 'lazy', handles => [ qw(package_versions meta) ]);
has pause_id => (is => 'lazy');

sub _build_metadata {
    my $self = shift;
    Dist::Metadata->new(file => $self->path);
}

sub _build_pause_id {
    my $self = shift;
    $self->path =~ m!authors/id/[A-Z]/[A-Z]{2}/([A-Z\-]{2,})/!
      and return $1;
}

package main;

my($backpan_src, $dest) = @ARGV;
BPTM::CLI->new(backpan => $backpan_src, destination => $dest)->run;
