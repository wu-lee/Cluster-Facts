#!/usr/bin/perl 
use strict;
use warnings;
use File::Find;
use FindBin qw($Bin);
use YAML::Tiny;

use lib "$Bin/../lib";
use Cluster::Facts qw(expand_attr_sets);

use Test::Exception;
use Test::More tests => 9;

my @cases = (
    [ "simple", <<CONFIG,
---
alpha:
  a: 1
  b: 2
  c: 3
beta:
  e: 4
  f: 5
CONFIG
      {
          alpha => {a => 1, b => 2, c => 3},
          beta => {e => 4, f => 5},
      },
  ],
  
    [ "include named", <<CONFIG,
---
alpha:
  a: 1
  b: 2
  c: 3
beta:
  - alpha
  -  e: 4
     f: 5
CONFIG
      {
          alpha => {a => 1, b => 2, c => 3},
          beta => {a => 1, b => 2, c => 3, e => 4, f => 5},
      },
  ],
  
    [ "include named in other order", <<CONFIG,
---
alpha:
  a: 1
  b: 2
  c: 3
beta:
  -  e: 4
     f: 5
  - alpha
CONFIG
      {
          alpha => {a => 1, b => 2, c => 3},
          beta => {a => 1, b => 2, c => 3, e => 4, f => 5},
      },
  ],
 
    [ "include named with override", <<CONFIG,
---
alpha:
  a: 1
  b: 2
  c: 3
beta:
  - alpha
  -  a: 4
     f: 5
CONFIG
      {
          alpha => {a => 1, b => 2, c => 3},
          beta => {a => 4, b => 2, c => 3, f => 5},
      },
  ],
  
    [ "include named with conflict", <<CONFIG,
---
alpha:
  a: 1
  b: 2
  c: 3
beta:
  -  a: 4
     f: 5
  - alpha
CONFIG
      qr{\QIn attribute set beta: failed to compose item #2: attributes already defined in 'alpha': 'a'\E},
  ],


    [ "with braces", <<CONFIG,
---
alpha:
  a{b,c}: %0
  foo{1,2,3}: foo%1-server.co.uk
  c: 3
CONFIG
      {
          alpha => {
              ab => 'ab', ac => 'ac', c => 3,
              foo1 => 'foo1-server.co.uk',
              foo2 => 'foo2-server.co.uk',
              foo3 => 'foo3-server.co.uk',
          },
      },
  ],
  
    [ "include with braces", <<CONFIG,
---
alpha:
  foo{1,2,3}: foo%1-server.co.uk
beta:
  - alpha
  - c: 3

CONFIG
      {
          alpha => {
              foo1 => 'foo1-server.co.uk',
              foo2 => 'foo2-server.co.uk',
              foo3 => 'foo3-server.co.uk',
          },
          beta => {
              foo1 => 'foo1-server.co.uk',
              foo2 => 'foo2-server.co.uk',
              foo3 => 'foo3-server.co.uk',
              c => '3',
          },
      },
  ],
  
    [ "with braces that create conflict", <<CONFIG,
---
alpha:
  a{b,c}: %0
  ac: 3
CONFIG
      qr{\QIn attribute set alpha: expanded attributes will shadow 'ac'\E},
  ],

    [ "include with braces with override", <<CONFIG,
---
alpha:
  foo{1,2,3}: foo%1-server.co.uk
beta:
  - alpha
  - foo1: 3

CONFIG
      {
          alpha => {
              foo1 => 'foo1-server.co.uk',
              foo2 => 'foo2-server.co.uk',
              foo3 => 'foo3-server.co.uk',
          },
          beta => {
              foo1 => '3',
              foo2 => 'foo2-server.co.uk',
              foo3 => 'foo3-server.co.uk',
          },
      },

  ],
 
    [ "include with braces which create conflict", <<CONFIG,
---
alpha:
  foo{1,2,3}: foo%1-server.co.uk
beta:
  - foo1: 3
  - alpha

CONFIG
      qr{\QIn attribute set beta: failed to compose item #2: attributes already defined in 'alpha': 'foo1'\E},
# FIXME this error message might be better worded
  ],
 
);


foreach my $case (@cases) {
    my ($label, $config, $expected) = @$case;
    $config = YAML::Tiny::Load($config)
        or die "error parsing config for $label: ", YAML::Tiny->errstr;


    if (ref $expected eq 'Regexp') {
        throws_ok {
            expand_attr_sets($config);
        } $expected, "$label: throws $expected ok";
    }
    else {
        my $got = expand_attr_sets($config);
        is_deeply $got, $expected, "$label: ok";
    }
}



