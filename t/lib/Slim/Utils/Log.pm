package Slim::Utils::Log;
use strict;
sub addLogCategory { bless {}, 'Slim::Utils::Log::Logger' }
package Slim::Utils::Log::Logger;
sub is_info  { 0 }
sub is_debug { 0 }
sub info  {}
sub debug {}
sub warn  {}
sub error { warn "[ERR] $_[1]\n" if $ENV{TEST_VERBOSE} }
1;
