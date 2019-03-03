#!/usr/bin/env perl -w

use strict;

my $readme = do { local( @ARGV, $/ ) = 'README.md'; <> };

my ($before, $command, $end);

$readme =~ s#(?<before>```bash\nsh>>>)(?<command>.*?)\n(?<output>.*?)(?<end>```)#
    $+{before} . $+{command} . "\n" . `$+{command}` . $+{end}
  #sge;

open(FILE, '>', 'README.md');
print FILE $readme;
close(FILE);
