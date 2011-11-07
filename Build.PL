use 5.006;
use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
    module_name         => 'Zabbix::API::Shell',
    license             => 'perl',
    dist_author         => q{Fabrice Gabolde <fabrice.gabolde@gmail.com>},
    dist_version_from   => 'lib/Zabbix/API/Shell.pm',
    build_requires => {
        'Test::More' => 0,
    },
    requires => {
        'perl' => 5.006,
    },
    add_to_cleanup      => [ 'zapishell-*' ],
    create_makefile_pl => 'traditional',
);

$builder->create_build_script();
