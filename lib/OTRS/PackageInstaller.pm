package OTRS::PackageInstaller;

use strict;
use warnings;

use Moo;

use Capture::Tiny ':all';
use HTTP::Tiny;
use IO::All;
use OTRS::Unittest;
use OTRS::Repository;
use OTRS::OPM::Analyzer::Util::OPMFile;
use Try::Tiny;

use OTRS::PackageInstaller::Logger;

our $VERSION = 0.01;

has otrs      => (is => 'ro', required => 1);
has package   => (is => 'ro', required => 1);
has manager   => (is => 'ro', lazy => 1, builder => 1);
has test      => (is => 'ro', default => sub { 1 } );
has logger    => (is => 'ro', required => 1, default => sub { OTRS::PackageInstaller::Logger->new( shift->log ) } );
has log       => (is => 'ro', required => 1, default => sub { io '?' } );
has framework => (is => 'ro', required => 1, lazy => 1, builder => 1);
has config    => (is => 'ro', lazy => 1, builder => 1);
has repo      => (is => 'ro', lazy => 1, builder => 1);
has db        => (is => 'ro', lazy => 1, builder => 1);

sub install {
    my ($self) = @_;

    $self->_install( $self->package );
}

sub _install {
    my ($self, $package) = @_;

    my $url  = $self->repo->find( $url, $self->framework );

    if ( !$url ) {
        $self->logger->print( 'error', message => sprintf "%s not found for OTRS %s", $package, $self->framework );
        return;
    }

    my $path = $self->_download( $url );
    my $opm  = OTRS::OPM::Analyzer::Util::OPMFile->new( opm_file => $path );

    $self->_install_perl( $opm );
    $self->_install_otrs( $opm );

    my $content < io $path;
    $self->manager->PackageInstall(
        String => $content,
    );

    $self->_do_unittests if $self->test;

    return 1;
}

sub _install_otrs {
    my ($self, $opm) = @_;

    my @otrs_deps = grep{
        $_->{type} eq 'OTRS';
    } $opm->dependencies;

    for my $otrs_dep ( @otrs_deps ) {
        my $name    = $otrs_dep->{name};
        my $version = $otrs_dep->{version};

        my $is_installed = $self->_is_dep_installed(
            package => $name,
            version => $version,
        );

        next OTRSDEP if $is_installed;

        my $success = $self->_install( $name );
        if ( !$success ) {
            $self->logger->print( 'otrs_dependency', success => 0, name => $name );
        }
        else {
            $self->logger->print( 'otrs_dependency', success => 1, name => $name );
        }
    }
}

sub _is_dep_installed {
    my ($self, %param) = @_;

    return if !$param{package};
    return if !$param{version};

    my $sql = 'SELECT version FROM package_repository WHERE name = ?';
    $self->db->Prepare(
        SQL  => $sql,
        Bind => [ \$param{package} ],
    );

    my $version;
    while ( my ($value) = $self->db->FetchrowArray() ) {
        $version = $value;
    }

    return if !$version;

    return $self->manager->_CheckVersion(
        VersionNew => $param{version},
        VersionInstalled => $version,
        Type             => 'Min',
        ExternalPackage  => 1,
    );
}

sub _install_perl {
    my ($self, $opm) = @_;

    my @perl_deps = grep{
        $_->{type} eq 'CPAN';
    } $opm->dependencies;

    CPANDEP:
    for my $cpan_dep ( @perl_deps ) {
        my $module  = $cpan_dep->{name};
        my $version = $cpan_dep->{version};
  
        eval "use $module $version" and next CPANDEP;

        my ($out, $err, $exit) = capture {
            system 'cpanm', $module;
        };

        if ( $out !~ m{Successfully installed $module} ) {
            $self->logger->print( 'cpan_dependency', success => 0, name => $module );
        }
        else {
            $self->logger->print( 'cpan_dependency', success => 1, name => $module );
        }
    }
}

sub _download {
    my ($self, $url) = @_;

    my $file     = io '?';
    my $response = HTTP::Tiny->new->mirror( $url, $file );

    $self->logger->print( 'download', file => $file, success => $response->{success} );

    return $file;
}

sub _build_framework {
    my ($self) = @_;

    my $version = $self->config->Get( 'Version' );
    $version =~ s/\.\d+\z//;

    return $version;
}

sub _build_db {
    my ($self) = @_;

    return $self->manager->{DBObject};
}

sub _build_config {
    my ($self) = @_;

    push @INC, $self->otrs;

    try {
        require Kernel::Config;
    }
    catch {
        die "Can't load OTRS modules!";
    };

    return Kernel::Config->new;
}

sub _build_repo {
    my ($self) = @_;

    my $repo = OTRS::Repository->new(
        sources => [
            'http://ftp.otrs.org/pub/otrs/itsm/packages33/otrs.xml',
            'http://ftp.otrs.org/pub/otrs/itsm/packages32/otrs.xml',
            'http://ftp.otrs.org/pub/otrs/itsm/packages31/otrs.xml',
            'http://ftp.otrs.org/pub/otrs/itsm/packages30/otrs.xml',
            'http://ftp.otrs.org/pub/otrs/itsm/packages21/otrs.xml',
            'http://ftp.otrs.org/pub/otrs/itsm/packages20/otrs.xml',
            'http://ftp.otrs.org/pub/otrs/itsm/packages13/otrs.xml',
            'http://ftp.otrs.org/pub/otrs/itsm/packages12/otrs.xml',
            'http://ftp.otrs.org/pub/otrs/itsm/packages11/otrs.xml',
            'http://ftp.otrs.org/pub/otrs/itsm/packages10/otrs.xml',
            'http://opar.perl-services.de/otrs.xml',
            'http://ftp.otrs.org/pub/otrs/packages/otrs.xml',
        ],
    );

    return $repo;
}

sub _build_manager {
    my ($self) = @_;

    push @INC, $self->otrs;

    try {
        require Kernel::Config;
        require Kernel::System::Main;
        require Kernel::System::Encode;
        require Kernel::System::Log;
        require Kernel::System::DB;
        require Kernel::System::Time;
        require Kernel::System::Package;
    }
    catch {
        die "Can't load OTRS modules!";
    };

    my %objects = ( ConfigObject => Kernel::Config->new );
    $objects{EncodeObject} = Kernel::System::Encode->new( %objects );
    $objects{LogObject}    = Kernel::System::Log->new( %objects );
    $objects{MainObject}   = Kernel::System::Main->new( %objects );
    $objects{DBObject}     = Kernel::System::DB->new( %objects );
    $objects{TimeObject}   = Kernel::System::Time->new( %objects );

    my $package_object = Kernel::System::Package->new( %objects );
    return $package_object;
}

1;
