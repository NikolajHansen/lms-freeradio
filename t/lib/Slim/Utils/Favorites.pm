package Slim::Utils::Favorites;
use strict;

sub enabled  { 0 }
sub new      { return bless {}, shift }
sub hasUrl   { 0 }
sub add      {}
sub deleteUrl {}

1;
