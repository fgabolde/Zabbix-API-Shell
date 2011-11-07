package Zabbix::API::Shell::Utils;

use strict;
use warnings;
use 5.010;

use YAML::Any qw/Load Dump LoadFile DumpFile/;
use Scalar::Util qw/blessed reftype/;
use Storable qw/dclone/;

use parent 'Exporter';

our @EXPORT_OK = qw/interesting_yaml/;

sub interesting_yaml {

    my $thing = shift;

    local $YAML::SortKeys = 1;
    local $YAML::UseFold = 1;

    if (blessed $thing and $thing->can('data')) {

        return Dump(flatten($thing->data));

    } else {

        return Dump(flatten($thing));

    }

}

sub dive {

    my $thing = shift;

    if (my $reftype = ref $thing) {

        given ($reftype) {

            when('Zabbix::API') {

                return 'ROOT OBJECT';

            }

            when(/^Zabbix::API::(.*)$/) {

                my $shortclass = $1;
                return { $shortclass => { name => $thing->name,
                                          id => $thing->id } };

            }

            when ('HASH') {

                return { map { $_ => dive($thing->{$_}) } keys %{$thing} };

            }

            when ('ARRAY') {

                return [ map { dive($_) } @{$thing} ];

            }

            default {

                return $thing;

            }

        }

    } else {

        return $thing;

    }

}

sub flatten {

    my $thing = shift;

    my $clone = do {

        # don't die or warn when trying to clone CODE refs
        local $Storable::forgive_me = 1;
        no warnings 'all';

        dclone($thing);

    };

    return dive($clone);

}

1;
