#!/usr/bin/perl 
use strict;
use warnings;
use File::Find;
use FindBin qw($Bin);
use YAML::Tiny;

use lib "$Bin/../lib";
use Cluster::Facts qw(expand_groups);

use Test::Exception;
use Test::More tests => 13;

my @cases = (
    [ "simple", <<CONFIG,
---
attributes:
  alpha:
  beta:
  gamma:
groups:
  foo: alpha
  bar:
   - alpha
  baz:
   - alpha
   - beta
  foozle:
   - baz
   - -beta
  foozle2:
   - baz
   - - beta
  foozle3:
   - baz
   - -gamma
  foozle4:
   - -alpha
   - baz
  barzle:
   - baz
   - baz
  bazzle:
   - baz
   - -baz
CONFIG
      [
          alpha => [qw(alpha)],
          foo => [qw(alpha)],
          bar => [qw(alpha)],
          baz => [qw(alpha beta)],
          foozle => [qw(alpha)],
          foozle2 => [qw(alpha)],
          foozle3 => [qw(alpha beta)],
          foozle4 => [qw(alpha beta)],
          barzle => [qw(alpha beta)],
          bazzle => [],

          # wildcards
          
      ],
  ],
    [ "wildcards (not groups)", <<CONFIG,
---
attributes:
  a1:
  a2:
  b1:
  b2:
  c1:
  c3:
  aa1:
groups:
  aX: a?
  aXX: a*
  alpha1: '[a-z]1'
CONFIG
      [
          aX => [qw(a1 a2)],
          aXX => [qw(a1 a2 aa1)],
          alpha1 => [qw(a1 b1 c1)],
      ],
  ],
  
);


foreach my $case (@cases) {
    my ($label, $config, $tests) = @$case;
    $config = YAML::Tiny::Load($config)
        or die "error parsing config for $label: ", YAML::Tiny->errstr;

    my ($attr_sets, $groups) = @$config{qw(attributes groups)};
    
    while(my ($expr, $expected) = splice @$tests, 0, 2) {
        if (ref $expected eq 'Regexp') {
            throws_ok {
                expand_groups($attr_sets, $groups, $expr);
            } $expected, "$label: $expr throws $expected ok";
        }
        else {
            my @got = sort { $a cmp $b } expand_groups($attr_sets, $groups, $expr);
            is_deeply \@got, $expected, "$label: $expr ok"
                or note explain \@got, "\n", $expected;
        }
    }
}



