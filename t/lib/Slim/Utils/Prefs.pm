package Slim::Utils::Prefs;
use strict;
my %_ns;
sub preferences { $_ns{$_[1]} ||= Slim::Utils::Prefs::Namespace->new }

package Slim::Utils::Prefs::Namespace;
sub new     { bless { data => {} }, shift }
sub get     { $_[0]->{data}{$_[1]} }
sub set     { $_[0]->{data}{$_[1]} = $_[2] }
sub init    { my ($self, $d) = @_; for my $k (keys %{$d||{}}) { $self->{data}{$k} //= $d->{$k} } }
sub readonly {}
sub migrate {}
1;
