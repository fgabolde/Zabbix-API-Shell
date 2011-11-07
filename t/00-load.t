#!perl -T

use Test::More tests => 1;

BEGIN {
    use_ok( 'Zabbix::API::Shell' ) || print "Bail out!\n";
}

diag( "Testing Zabbix::API::Shell $Zabbix::API::Shell::VERSION, Perl $], $^X" );
