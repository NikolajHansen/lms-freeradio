package Plugins::FreeRadio::Cache;

use strict;

sub new {
	my ($class, %args) = @_;
	my $size = $args{size} || 200;
	my $default_ttl = $args{default_ttl} || 300;

	return bless {
		capacity    => $size,
		default_ttl => $default_ttl,
		entries     => {},
		order       => [],
	}, $class;
}

sub get {
	my ($self, $key) = @_;
	my $entry = $self->{entries}{$key};
	return unless $entry;

	if ($entry->{expires_at} < time()) {
		delete $self->{entries}{$key};
		$self->_remove_from_order($key);
		return;
	}

	$self->_touch($key);
	return $entry->{value};
}

sub set {
	my ($self, $key, $value, $ttl) = @_;
	$ttl ||= $self->{default_ttl};

	if (!exists $self->{entries}{$key} && scalar @{ $self->{order} } >= $self->{capacity}) {
		my $lru = shift @{ $self->{order} };
		delete $self->{entries}{$lru} if defined $lru;
	}

	$self->{entries}{$key} = {
		value      => $value,
		expires_at => time() + $ttl,
	};

	$self->_touch($key);
}

sub clear {
	my ($self) = @_;
	$self->{entries} = {};
	$self->{order} = [];
}

sub _touch {
	my ($self, $key) = @_;
	$self->_remove_from_order($key);
	push @{ $self->{order} }, $key;
}

sub _remove_from_order {
	my ($self, $key) = @_;
	my @kept = grep { $_ ne $key } @{ $self->{order} };
	$self->{order} = \@kept;
}

1;
