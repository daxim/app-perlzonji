#!/usr/bin/env perl

use warnings;
use strict;
use App::perlzonji;
use Test::More;

my %seen;
my $errors = 0;
while (my ($file, $words) = each %App::perlzonji::found_in) {
    for (@$words) {
        if ($seen{$_}) {
            fail("$file: Already seen [$_] in [$seen{$_}]");
            $errors++;
        } else {
            $seen{$_} = $file;
        }
    }
}

pass("No duplicates") unless $errors;

done_testing;
