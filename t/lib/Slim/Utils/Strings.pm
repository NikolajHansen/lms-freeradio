package Slim::Utils::Strings;
use strict;
use Exporter 'import';
our @EXPORT_OK = qw(cstring string);
sub cstring { $_[1] }
sub string  { $_[1] }
1;
