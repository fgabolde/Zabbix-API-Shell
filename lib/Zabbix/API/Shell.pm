package Zabbix::API::Shell;

use 5.010;
use strict;
use warnings;

our $VERSION = '0.01';

use parent qw/Term::Shell/;
use Data::Dumper;
use Zabbix::API 0.003;
use Regexp::Common qw/URI/;
use YAML::Any qw/Load Dump LoadFile DumpFile/;
use Class::Inspector;
use Storable qw/dclone/;

use Zabbix::API::Shell::Utils qw/interesting_yaml/;

sub get_object {

    my ($self, $type, $id) = @_;

    my $object;

    if (defined $type and defined $id) {

        $type =~ s/(?:Zabbix::API::)?/Zabbix::API::/;
        my $prefix = eval { $type->prefix };

        if ($@) {

            say "Can't find prefix for object type $type";
            return 0;

        }

        if ($object = eval { $self->_zabber->stash->{$prefix}->{$id} }) {

            return $object;

        } else {

            say "Can't find object type $type id $id";
            return 0;

        }

    } elsif ($object = $self->{SHELL}->{current_thing}) {

        return $object;

    } else {

        say "No currently selected object and no object specified";
        return 0;

    }

}

sub preloop {

    my $self = shift;

    say "This is zapishell version $Zabbix::API::Shell::VERSION.

This application is free software; you can redistribute it and/or modify it
under the same terms as Perl itself, either Perl version 5.10.0 or, at your
option, any later version of Perl 5 you may have available.";

    $self->{SHELL}->{options} = eval { LoadFile($ENV{HOME}.'/.zapishellrc') } || {};

    if ($@) {

        my $error = $@;
        say sprintf("Could not load external configuration from %s:\n%s", $ENV{HOME}.'/.zapishellrc', $error);

    }

    # local copy that config subcommands operate on
    $self->{SHELL}->{options_local} = dclone($self->{SHELL}->{options});

    # Term::ReadLine::Gnu underlines the prompt, which is ugly IMHO
    $self->{term}->ornaments($self->_config_local->{prompt_ornaments} || 0);

    # fetch the history if the readline class supports it
    if ($self->{term}->Features->{setHistory}) {

        my $filename = $ENV{HOME}.'/.zapishell_history';

        if (-r $filename) {

            open my $fh, '<', $filename
                or die "can't open history file $filename: $!\n";

            chomp(my @history = <$fh>);
            $self->{term}->SetHistory(@history);
            $fh->close;

        }

    }

    # set the default pager for ->page
    $self->{API}->{pager} = '/usr/bin/less';

}

sub postloop {

    my $self = shift;

    # save the history if the readline class supports it
    if ($self->{term}->Features->{getHistory}) {

        my $filename = $ENV{HOME}.'/.zapishell_history';
        open my $fh, '>', $filename
            or die "can't open history file $filename for writing: $!\n";

        $fh->say($_) for grep { length } $self->{term}->GetHistory;
        $fh->close or die "can't close history file $filename: $!\n";

    }

}

sub _zabber {

    my $self = shift;
    return $self->{SHELL}->{connection};

}

sub _config {

    ## mutator for options

    my ($self, $value) = @_;

    if (defined $value) {

        $self->{SHELL}->{options} = $value;
        return $self->{SHELL}->{options};

    } else {

        return $self->{SHELL}->{options};

    }

}

sub _config_local {

    ## mutator for options_local

    my ($self, $value) = @_;

    if (defined $value) {

        $self->{SHELL}->{options_local} = $value;
        return $self->{SHELL}->{options_local};

    } else {

        return $self->{SHELL}->{options_local};

    }

}

sub run_config {

    my ($self, $op, $key, $value) = @_;

    given ($op) {

        when ('set') {

            $self->_config_local->{$key} = $value;

        }

        when ('unset') {

            delete $self->_config_local->{$key};

        }

        when ('dump') {

            if ($key) {

                $self->page(interesting_yaml($self->_config_local->{$key}));

            } else {

                $self->page(interesting_yaml($self->_config_local));

            }

        }

        when ('commit') {

            if ($key) {

                my $answer = $self->prompt(sprintf(q{This will overwrite the stored value of %s ('%s') with '%s'.  Proceed? [yN] },
                                                   $key, $self->_config->{$key} // 'undef', $self->_config_local->{$key} // 'undef'),
                                           'n',
                                           ['yes', 'no'],
                                           1);

                return $self if $answer =~ /n(?:o)?/i;

                if (ref $self->_config_local->{$key}) {

                    $self->_config->{$key} = dclone($self->_config_local->{$key});

                } else {

                    $self->_config->{$key} = $self->_config_local->{$key};

                }

            } else {

                my $answer = $self->prompt(q{This will overwrite the stored configuration with the values changed so far.  Proceed? [yN] },
                                           'n',
                                           ['yes', 'no'],
                                           1);

                return $self if $answer =~ /n(?:o)?/i;

                $self->_config(dclone($self->_config_local));

            }

            DumpFile($ENV{HOME}.'/.zapishellrc', $self->_config);

        }

        default {

            say "`commit' does not have a '$op' subcommand";

        }

    }

    return $self;

}

sub run_connect {

    my ($self, $url, $user, $password) = @_;

    $self->_zabber->logout if $self->_zabber;

    $self->{SHELL}->{connection} = Zabbix::API->new(server => $url,
                                                    env_proxy => $self->_config_local->{env_proxy} || 0);

    eval { $self->_zabber->login(user => $user, password => $password) };

    if ($@) {

        my $error = $@;

        say "Could not connect to '$url':\n$error";

        return 1;

    }

    my $version = $self->_zabber->api_version;

    say "Connected to '$url' as '$user'.  JSON-RPC API version is $version.";

}

sub is_connected {

    return eval { shift->_zabber->cookie };

}

sub prompt_str {

    my $self = shift;

    my $location = $self->{SHELL}->{location};

    my $who_at_where = 'nobody@nowhere';

    if ($self->is_connected) {

        my $host;

        if ($self->_zabber->{server} =~ $RE{URI}{HTTP}{-keep}) {

            # the host (name or address)
            $host = $3;

        } else {

            $host = '[!!!]';

        }

        $who_at_where = sprintf('%s@%s',
                                $self->_zabber->{user},
                                $host);

    }

    return sprintf('%s:%s$ ',
                   $who_at_where,
                   $location || '/');

}

sub run_select {

    my ($self, $type, $id) = @_;

    if (!$self->is_connected) {

        say 'Not connected.';

    } else {

        $type =~ s/(?:Zabbix::API::)?/Zabbix::API::/;

        my $prefix = eval { $type->prefix };

        if ($@) {

            say "Can't find prefix for object type $type";

            return 1;

        } else {

            if (exists $self->_zabber->stash->{$type->prefix}->{$id}) {

                my $thing = $self->_zabber->stash->{$type->prefix}->{$id};

                $self->{SHELL}->{location} = sprintf('[%s %s]', $thing->prefix, eval { $thing->name } || $thing->id);
                $self->{SHELL}->{current_thing} = $thing;

                { no strict 'refs';

                    say q{This thing you're in can do: }.join(' ', sort map { s/^.*::([^:]+)$/$1/; $_ } grep { m/^Zabbix::API/ } @{Class::Inspector->methods($type, 'full')});

                }

            } else {

                say "Object $id of type $type does not exist in the stash.";

            }

        }

    }

}

sub run_fetch {

    my ($self, $type, %args) = @_;

    if (!$self->is_connected) {

        say 'Not connected.';

    } else {

        print 'Fetching... ';

        my @things = @{$self->_zabber->fetch($type, params => { search => \%args })};

        say 'done.';

        say sprintf("%s object, ID: %s", $type, $_->id) foreach @things;

    }

}

sub run_examine {

    my ($self, $type, $id) = @_;

    if (!$self->is_connected) {

        say 'Not connected.';

    } else {

        if (my $object = $self->get_object($type, $id)) {

            $self->page(interesting_yaml($object));

        }

    }

}

sub run_filter {

    my ($self, $type, $key, $value) = @_;

    if (!$self->is_connected) {

        say 'Not connected.';

    } else {

        $type =~ s/(?:Zabbix::API::)?/Zabbix::API::/;
        my $prefix = eval { $type->prefix };

        if ($@) {

            say "Can't find prefix for object type $type";
            return 0;

        }

        my $results = { map { $_ => $self->_zabber->stash->{$prefix}->{$_} } grep { $self->_zabber->stash->{$prefix}->{$_}->data->{$key} ~~ $value } keys %{$self->_zabber->stash->{$prefix}} };

        $self->page(interesting_yaml($results));

    }

}

sub run_list {

    my ($self, $type) = @_;

    if (!$self->is_connected) {

        say 'Not connected.';

    } else {

        $type =~ s/(?:Zabbix::API::)?/Zabbix::API::/;
        my $prefix = eval { $type->prefix };

        if ($@) {

            say "Can't find prefix for object type $type";
            return 0;

        }

        my $results = { map { $_ => $self->_zabber->stash->{$prefix}->{$_} } keys %{$self->_zabber->stash->{$prefix}} };

        $self->page(interesting_yaml($results));        

    }

}

sub run_set {

    my ($self, $type, $id, $key, $value) = @_;

    if (!$self->is_connected) {

        say 'Not connected.';

    } else {

        $type =~ s/(?:Zabbix::API::)?/Zabbix::API::/;

        my $prefix = eval { $type->prefix };

        if ($@) {

            say "Can't find prefix for object type $type";

            return 1;

        } else {

            if (exists $self->_zabber->stash->{$type->prefix}->{$id}) {

                my $thing = $self->_zabber->stash->{$type->prefix}->{$id};

                $thing->data->{$key} = $value;

            } else {

                say "Object $id of type $type does not exist in the stash.";

            }

        }

    }

}

sub catch_run {

    my ($self, $command, @args) = @_;

    if (my $thing = $self->{SHELL}->{current_thing}) {

        eval {

            local $Data::Dumper::Maxdepth = 3;

            if (my $sub = $thing->can($command)) {

                my $result = $sub->($thing, @args);

                $self->page(interesting_yaml($result));

            } else {

                say "The currently selected object can not do $command";

            }

        };

        if ($@) {

            my $error = $@;
            say "Can't do $command on currently selected object:\n$error";

        }

    } else {

        say "Can't call a method without a selected object";

    }

}

1;
__END__
=pod

=head1 NAME

Zabbix::API::Shell -- Command line shell to interact with a Zabbix instance

=head1 SYNOPSIS

  use Zabbix::API::Shell;

  Zabbix::API::Shell->new->cmdloop;

=head1 DESCRIPTION

This is a class derived from Term::Shell.  Running its instance method
C<cmdloop> brings up a console client for Zabbix servers.

=head1 METHODS

All of these C<run_foo> methods implement the corresponding C<foo> command.  The
methods specific to each object (e.g. a Host's C<items> command) are implemented
by C<catch_run>, in an ugly catch-all eval-if block.

The existence of a C<Zabbix::API::Unicorn> class, mapping a (sadly,
hypothetical) unicorn-like object in the remote API, is assumed.  This class is
mentioned wherever the actual type does not matter.

=over 4

=item run_config

This command manipulates zapishell's configuration interactively.  There are
several subcommands for the C<config> command:

=over 4

=item set

  $ config set foo bar

Set the config value C<foo> to C<bar>.

=item unset

  $ config unset foo

Delete the config value C<foo>.

=item dump

  $ config dump

Dump the current configuration to screen, in YAML format.

  $ config dump foo

Dump the value of C<foo> in the current configuration.

=item commit

Both of these require interactive confirmation by the user.

  $ config commit

Writes the current configuration to file.  If you do not do this, your
modifications will be forgotten once you exit C<zapishell>!

  $ config commit foo

Writes the value of C<foo> in the current configuration to the config file.

=back

=item run_connect

  $ connect http://127.0.0.1/zabbix/api_jsonrpc.php username password

Creates a Zabbix::API object connected to the URL given as the first argument,
logs in as C<username> with password C<password>, and displays the remote API's
version.

All other commands (except C<config>) will complain if the user has not
connected.

=item run_select

  $ select Unicorn 10018

Select a stashed item by type and ID. (see C<run_fetch> for an explanation of
the stash).  The user can now run commands without needing to specify the object
every time, and the selected object's own commands (e.g. C<items> for Host type
objects) become available.

This means that in the documentation of other commands which require an object's
type and ID, you can remove those two parameters:

  $ examine Unicorn 10018

becomes

  $ examine

=item run_fetch

  $ fetch Unicorn id 10018

Fetches (pulls) an item from the server, by type and arbitrary parameters.  The
parameters are given as a hashref to the type's search parameter.

The example above results in something like

  $ $zabbix->fetch('Unicorn', params => { search => { id => 10018 }});

The item(s) fetched are then stashed, which means they can be used by the other
commands if referred to by type and ID, and they can be selected.

You can't use C<select> to indicate an object to be fetched, but you can use the
object's own C<pull> method instead (that's probably what you were looking for,
right?).

=item run_examine

  $ examine Unicorn 10018

Dumps the object's data to screen, in YAML format.

=item run_filter

  $ filter Unicorn color white

Prints the list of IDs of Unicorns whose color smart-matches "white".  For this
to work, C<color> needs to be a member of the object's data.  For now this only
does a very simple direct match; we could later expand this to regexes,
parent-child relationships ("hosts that have items like system.uptime"), etc.

Later on this might become C<list Unicorn color white>, since C<list> does not
take any useful arguments beyond a type.

=item run_list

  $ list Unicorn

Prints the list of IDs of stashed objects whose type is given as parameter.  If
you can't see an object and you're pretty sure it's on the server, you probably
haven't C<fetch>ed it.

=item run_set

  # turn it into a cross-aligned unicorn
  $ set Unicorn 10018 color black

Sets the object's attribute to a specific value.  There are several caveats
associated with this command, the most important being "It may not work."

=over 4

=item

It doesn't understand C<select>ed objects, because of the very primitive way we
handle parameters.

=item

It doesn't understand complex data structures, because we have no elegant way of
specifying them on the command line (maybe JSON-encoded).

=item

The user needs to remember to C<push> the object afterwards, and object methods
are still not entirely reliable.

=back

=item catch_run

This method attempts to make sense of nonsense commands by assuming they're
methods of the currently C<select>ed object and YAML-dumping the result to
screen, so for instance this works:

  $ select Host 10024
  $ items

Since a YAML dump of the actual C<Zabbix::API::Item> objects would be huge, it's
reduced to a representative form of each element in the resulting structure,
which in this case is a list of name => NAME, id => ID hashes.  It's a naive,
recursive data walk with no state, so dumping the contents of recursive data
structures may not be the best idea (it loops forever).

=back

=head2 FOR DEVELOPERS ONLY

If you are not interested in hacking C<zapishell>, only in using it, then you're
probably not interested in this section either.

=over 4

=item get_object

Multipurpose helper to return the currently selected object, or the object
specified in the command:

  # $zapishell->get_object('Unicorn', 10018) under the hood
  $ examine Unicorn 10018

  $ select Unicorn 10018
  # same thing
  $ examine

=item preloop

Displays the banner and sets up a few internals: configuration, readline-related
things (prompt, history), default pager (better hope you have /usr/bin/less --
don't worry, this will change in a future release).

=item postloop

Saves the readline history if the underlying implementation understands it.

=item is_connected

Returns a true value if the shell is connected to a remote API.

=item prompt_str

Builds an appropriate prompt string.  It looks like this:

  # not connected
  $ nobody@nowhere:/$ 

  # connected
  $ username@hostname:/$ 

  # connected and object selected
  $ username@hostname:[unicorn IPU]$ 

=back

=head1 SEE ALSO

L<zapishell>.

=head1 AUTHOR

Fabrice Gabolde <fabrice.gabolde@uperto.com>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2011 Devoteam

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself, either Perl version 5.10.0 or, at your option,
any later version of Perl 5 you may have available.

=cut
