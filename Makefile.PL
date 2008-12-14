use inc::Module::Install;

name		'Catalyst-Plugin-HTTP-MeetsConditions';
license		'perl';
all_from	'lib/Catalyst/Plugin/HTTP/MeetsConditions.pm';
author		'Bernhard Graf <graf@cpan.org>';

build_requires	'Catalyst::Runtime';
build_requires	'Test::WWW::Mechanize::Catalyst';
build_requires	'Test::More';
build_requires	'ok';

requires	'Class::Accessor::Fast';
requires	'HTTP::Headers::ETag';
requires	'List::Util';
requires	'NEXT';

WriteAll;
