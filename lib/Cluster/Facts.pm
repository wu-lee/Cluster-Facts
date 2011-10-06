package Cluster::Facts;
use warnings;
use strict;
use Carp qw(croak);
use Text::Glob::Expand;

use version; our $VERSION = qv('0.1');

use Exporter qw(import);
our @EXPORT_OK = qw(expand_attr_sets expand_node_groups);

sub _comma_and {
    return '' unless @_;
    my $last = pop;
    return "'$last'" unless @_;
    return "'". join("' and '", join("', '", @_), $last). "'";
}

sub _is_glob {
    # Are there any (possibly escaped) braces?
    return unless
        my @matches = shift =~ /([\\]*)[{]/g;

    # Are any of these not escaped?
    length($_) % 2 or return 1
        for @matches;
    
    # Found none
    return;
}

sub serialize {
    my ($name, $attrs) = @_;

    # Order the values
    my @values = ($name, map { $_ => $attrs->{$_} } sort keys %$attrs);

    # Escape and quote these values
    s/'/\\'/g, $_="'$_'"
        for @values;

    # Recombine as space-delimited pairs of 'a'='b', with the first
    # pair being a special case of ='name'
    unshift @values, '';
    
    my $string = join ' ', map { 
        join '=', splice @values, 0, 2;
    } 1..@values/2;

    return $string;
}

# Split a string created by serialise_line into a name and an
# attribute-value list. Note, this function should *not* leak sensitive
# information, yet alone include passwords in error messages!
use Text::ParseWords qw(parse_line);
sub deserialize {
    my $line = shift;
    my ($empty, $name, @values) = parse_line qr/\s*(=\s*|\s+)/, 0, $line;

    # Perform some sanity checking
    die "line does not start with '='\n"
        if length $empty;

    die "number of attribute values does not match number of keys"
        if @values % 2;

    # Count each key's frequency whilst converting to a hash
    my %counts;
    my %attrs = map {
        $counts{$values[0]}++;
        splice @values, 0 ,2;
    } 1..@values/2;

    # collect (quoted) names of duplicates
    my $duplicates = _comma_and map {
        s/'/\\'/g; 
        "'$_'";
    } grep {
        $counts{$_} > 1;
    } keys %counts;
    
    die "duplicated keys\n"
        if $duplicates;

    return $name, \%attrs;
}



sub expand_attr_sets {
    my $attr_sets = shift;

    # This memcaches a subroutine based on a single ref argument and a
    # single ref return value.  The cache (%seen) only lasts as long as the
    # closures in this method.
    my %seen;
    my $memcache = sub {
        my $original = shift;
        return sub {
            my $arg = shift;
            return $seen{$arg} || ($seen{$arg} = $original->($arg));
        };
    };



    my $expand_simple_attrs = sub {
        my $attrs = shift;

        # Process simple attribute maps.
        my @names = keys %$attrs;
        my $invalids = _comma_and grep { ref $attrs->{$_} } @names;

        # If there are sub-elements, there is something wrong
        die "attribute sets can only contain scalar values; ",
            "the attributes $invalids are not scalars\n"
                if $invalids;
 
        # expand (unescaped) braces
        my (@new_attrs, @new_values);
        foreach my $name (@names) {
            next 
                if !_is_glob $name;

            my $value = delete $attrs->{$name};

            my $glob = Text::Glob::Expand->parse($name);
            my $permutations = $glob->explode;
            push @new_attrs, map { $_->text } @$permutations;
            push @new_values, map { $_->expand($value) } @$permutations;
        }
        
        # Now, having removed all the expandable attributes, we can
        # check if the expanded results will clobber any of the
        # remaining ones.
        my $preexisting = _comma_and grep { exists $attrs->{$_} } @new_attrs;
            
        die "expanded attributes will shadow $preexisting\n"
            if $preexisting;
        
        # Now we can do the insertion
        @$attrs{@new_attrs} = @new_values;

        return $attrs
    };


    my $expand_attrs; # predeclaration
    my $append = sub {
        my ($to_append, $target) = @_;

        if (ref \$to_append eq 'SCALAR') {
            # Append another named attribute set.  
            my $raw_name = $to_append;
            my @names = $raw_name;
            $to_append = {};

            # Do we need to expand the name?
            if (_is_glob $raw_name) {
                # We do
                my $exploded = Text::Glob::Expand->parse($raw_name)->explode;

                @names = map { $_->text } @$exploded;
            }

            foreach my $name (@names) {
                # Get the attribute set for this name
                my $attr_set = $attr_sets->{$name}; 

                # We must expand it first
                $attr_set = $expand_attrs->($attr_set);
            
                # Now we must warn if any of the attributes pre-exist in the target
                my @new_attrs = keys %$attr_set;
                my $preexisting = _comma_and grep { exists $target->{$_} } @new_attrs;
                
                die "included attribute set '$name' would overwrite the existing attributes $preexisting\n"
                    if $preexisting;

                # And also if any of the attributes in other expansions coincide
                $preexisting = _comma_and grep { exists $to_append->{$_} } @new_attrs;
                
                die "the expansion of '$raw_name' defines duplicates of the attributes $preexisting\n"
                    if $preexisting;

                # Queue them to be added
                @$to_append{@new_attrs} = values %$attr_set;
            }
        }
        elsif (ref $to_append eq 'HASH') {
            # Append a simple attribute set
            $to_append = $expand_simple_attrs->($to_append);
        }
        else {
            die "you can't nest lists inside lists within attributes\n";
        }
        
        # Actually do the append
        @$target{keys %$to_append} = values %$to_append;
        return;
    };

    $expand_attrs = sub {
        my $attrs = shift;

        if (ref $attrs eq 'HASH') {
            return $expand_simple_attrs->($attrs);
        }
        elsif (ref $attrs eq 'ARRAY') {
            # Process attribute compositions. The default is to unify
            # attribute sets (in the set-theoretic sense) but we need
            # to additionally arbitrate what happens if two attributes
            # are unified.  The rules are described in $append.
            my (%result, $ix);
            foreach my $elem (@$attrs) {
                $ix++;
                eval {
                    $append->($elem, \%result);
                    1;
                }
                or do {
                    die "failed to compose item #$ix: $@"; # $@ should have a \n appened already
                };
            }
            return \%result;
        }
        else {
            $attrs = defined $attrs? "'$attrs'" : '<undef>';
            die "attributes must be an array or hash ref (not $attrs)\n";
        }
    };

    # wrap $expand_attrs to do memchaching
    $expand_attrs = $memcache->($expand_attrs);

    # Extract and expand names with braces first
    if (my @globbing_names = grep { _is_glob $_ } keys %$attr_sets) {

        my @new_names;
        my @new_values;
        foreach my $name (@globbing_names) {
            my $attr_set = delete @$attr_sets{$name};
            my $glob = Text::Glob::Expand->parse($name);
            my $exploded = $glob->explode;
            push @new_names, map { $_->text } @$exploded;

            # Note, we don't expand the attribute set yet, it will
            # cause problems if one of these globbed attribute set
            # names tries to include another (which happens to be
            # expanded afterwards).  Let the expansion happen 
            # later.

            # Store a reference to the expanded attribute set in each
            # (we assume these won't be modified, so a reference is acceptable)
            push @new_values, ($attr_set) x @$exploded;
        }

        # Do any of the names coincide?
        my %count;
        $count{$_}++
            for @new_names, keys %$attr_sets;

        my $duplicates = _comma_and grep { $count{$_} > 1 } keys %count;

        croak "There are duplicate attribute set names after brace expansion: $duplicates\n"
            if $duplicates;

        # All ok, add the new names back
        @$attr_sets{@new_names} = @new_values;
    }
    

    foreach my $name (keys %$attr_sets) {
        
        eval {
            # Delete the unexpanded set first (to avoid self-recursive
            # definitions creating an infinite loop).
            my $unexpanded = delete $attr_sets->{$name};

            # Now expand it (recursively).
            $attr_sets->{$name} = $expand_attrs->($unexpanded);
            1;
        }
        or do {
            chomp (my $error = $@);
            croak "In attribute set $name: $error\n";
        };
    }

    return $attr_sets;
}


sub expand_node_groups {
    my $nodes = shift;
    my $groups = shift;
    my $input = \@_;

    my %seen; # record traversal, so that we don't get stuck in a loop

    my $expand;
    $expand = sub {
        my @attr_sets;
        foreach my $name (@_) {
            next unless defined $name; # don't expand undef values

            #print "expanding: $name\n";# DB

            # Don't expand things we've seen already
            next if $seen{$name}++;

            # expand globs
            if (_is_glob $name) {
                my $exploded = Text::Glob::Expand->parse($name)->explode;
                push @attr_sets, $expand->(map { $_->text } @$exploded);
                next;
            }

            # use a node attribute set if possible
            my $def = $nodes->{$name};
            if ($def) {
                push @attr_sets, $name => $def;
                next;
            }

            # else try to recursively expand the name
            croak "unknown group name '$name' in expansion of: @$input\n"
                unless $def = $groups->{$name};

            $def = [$def]
                if ref \$def eq 'SCALAR';

            croak "group '$name' is not a scalar or a list, cannot expand it\n"
                unless ref $def eq 'ARRAY';
            
            push @attr_sets, $expand->(@$def);
        } 

        return @attr_sets;
    };

    return $expand->(@_);
}


1; # Magic true value required at end of module
__END__

=head1 NAME

Cluster::Facts - define concise connection attributes


=head1 VERSION

This document describes Cluster::Facts version 0.1


=head1 SYNOPSIS

    use Cluster::Facts;

=for author to fill in:
    Brief code example(s) here showing commonest usage(s).
    This section will be as far as many users bother reading
    so make it as educational and exeplary as possible.
  
  
=head1 DESCRIPTION

=for author to fill in:
    Write a full description of the module and its features here.
    Use subsections (=head2, =head3) as appropriate.


=head1 INTERFACE 

=for author to fill in:
    Write a separate section listing the public components of the modules
    interface. These normally consist of either subroutines that may be
    exported, or methods that may be called on objects belonging to the
    classes provided by the module.


=head1 DIAGNOSTICS

=for author to fill in:
    List every single error and warning message that the module can
    generate (even the ones that will "never happen"), with a full
    explanation of each problem, one or more likely causes, and any
    suggested remedies.

=over

=item C<< Error message here, perhaps with %s placeholders >>

[Description of error here]

=item C<< Another error message here >>

[Description of error here]

[Et cetera, et cetera]

=back


=head1 CONFIGURATION AND ENVIRONMENT

=for author to fill in:
    A full explanation of any configuration system(s) used by the
    module, including the names and locations of any configuration
    files, and the meaning of any environment variables or properties
    that can be set. These descriptions must also include details of any
    configuration language used.
  
Cluster::Facts requires no configuration files or environment variables.


=head1 DEPENDENCIES

=for author to fill in:
    A list of all the other modules that this module relies upon,
    including any restrictions on versions, and an indication whether
    the module is part of the standard Perl distribution, part of the
    module's distribution, or must be installed separately. ]

None.


=head1 INCOMPATIBILITIES

=for author to fill in:
    A list of any modules that this module cannot be used in conjunction
    with. This may be due to name conflicts in the interface, or
    competition for system or program resources, or due to internal
    limitations of Perl (for example, many modules that use source code
    filters are mutually incompatible).

None reported.


=head1 BUGS AND LIMITATIONS

=for author to fill in:
    A list of known problems with the module, together with some
    indication Whether they are likely to be fixed in an upcoming
    release. Also a list of restrictions on the features the module
    does provide: data types that cannot be handled, performance issues
    and the circumstances in which they may arise, practical
    limitations on the size of data sets, special cases that are not
    (yet) handled, etc.

No bugs have been reported.

Please report any bugs or feature requests to
C<bug-Cluster-Facts@rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org>.


=head1 AUTHOR

Nick Stokoe  C<< <npw@cpan.org> >>


=head1 LICENCE AND COPYRIGHT

Copyright (c) 2011, Nick Stokoe C<< <npw@cpan.org> >>. All rights reserved.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself. See L<perlartistic>.


=head1 DISCLAIMER OF WARRANTY

BECAUSE THIS SOFTWARE IS LICENSED FREE OF CHARGE, THERE IS NO WARRANTY
FOR THE SOFTWARE, TO THE EXTENT PERMITTED BY APPLICABLE LAW. EXCEPT WHEN
OTHERWISE STATED IN WRITING THE COPYRIGHT HOLDERS AND/OR OTHER PARTIES
PROVIDE THE SOFTWARE "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER
EXPRESSED OR IMPLIED, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE. THE
ENTIRE RISK AS TO THE QUALITY AND PERFORMANCE OF THE SOFTWARE IS WITH
YOU. SHOULD THE SOFTWARE PROVE DEFECTIVE, YOU ASSUME THE COST OF ALL
NECESSARY SERVICING, REPAIR, OR CORRECTION.

IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED TO IN WRITING
WILL ANY COPYRIGHT HOLDER, OR ANY OTHER PARTY WHO MAY MODIFY AND/OR
REDISTRIBUTE THE SOFTWARE AS PERMITTED BY THE ABOVE LICENCE, BE
LIABLE TO YOU FOR DAMAGES, INCLUDING ANY GENERAL, SPECIAL, INCIDENTAL,
OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OR INABILITY TO USE
THE SOFTWARE (INCLUDING BUT NOT LIMITED TO LOSS OF DATA OR DATA BEING
RENDERED INACCURATE OR LOSSES SUSTAINED BY YOU OR THIRD PARTIES OR A
FAILURE OF THE SOFTWARE TO OPERATE WITH ANY OTHER SOFTWARE), EVEN IF
SUCH HOLDER OR OTHER PARTY HAS BEEN ADVISED OF THE POSSIBILITY OF
SUCH DAMAGES.
