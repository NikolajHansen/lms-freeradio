package Plugins::FreeRadio::Search;

use strict;

sub new {
	my ($class, %args) = @_;
	return bless {
		store => $args{store},
		cache => $args{cache},
		log   => $args{log},
	}, $class;
}

sub search {
	my ($self, $args) = @_;
	$args ||= {};

	my $query = $args->{query} || '';
	my $filters = $args->{filters} || {};
	my $limit = $args->{limit} || 100;
	my $offset = $args->{offset} || 0;

	my $cacheKey = join('|',
		'search',
		lc($query),
		map { $_ . '=' . lc($filters->{$_} || '') } sort keys %$filters,
		"l=$limit",
		"o=$offset",
	);

	my $hit = $self->{cache}->get($cacheKey);
	return $hit if $hit;

	my $rows = $self->{store}->search_stations(
		query   => $query,
		filters => $filters,
		limit   => $limit,
		offset  => $offset,
	);

	$self->{cache}->set($cacheKey, $rows);
	return $rows;
}

sub distinct_values {
	my ($self, $field) = @_;
	my $cacheKey = "distinct:$field";
	my $hit = $self->{cache}->get($cacheKey);
	return $hit if $hit;

	my $values = $self->{store}->list_distinct_values($field);
	$self->{cache}->set($cacheKey, $values, 900);
	return $values;
}

sub clear_cache {
	my ($self) = @_;
	$self->{cache}->clear();
}

1;
