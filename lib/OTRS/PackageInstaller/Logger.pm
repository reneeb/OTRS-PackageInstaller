package OTRS::PackageInstaller::Logger;

use strict;
use warnings;

use Moo;
use IO::All -utf8;

has log => (is => 'ro', required => 1);

sub print {
    my ($self, $tag, %attr) = @_;

    my $attrs   = join " ", map{ sprintf '%s="%s"', $_, $attr{$_} }keys %attr;
    my $message = sprintf "<%s %s />", $tag, $attrs;
    $message >> io $self->log;
}

sub BUILD {
    my ($self) = @_;

    '<?xml version="1.0" encoding="utf-8" ?>' .
    "\n" .
    '<log>'
        > io $self->log
    

sub DEMOLISH {
    my ($self) = @_;

    '</log>' >> io $self->log; 
}

1;
