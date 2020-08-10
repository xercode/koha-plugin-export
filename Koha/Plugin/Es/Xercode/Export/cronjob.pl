#!/usr/bin/perl

use Modern::Perl;

use C4::Context;
use lib C4::Context->config("pluginsdir");

use Koha::Plugin::Es::Xercode::Export;

my $plugin = Koha::Plugin::Es::Xercode::Export->new();
$plugin->cronjob();
