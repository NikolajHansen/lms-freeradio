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

sub indexed_genres {
	my ($self) = @_;
	my $cacheKey = 'indexed_genres';
	my $hit = $self->{cache}->get($cacheKey);
	return $hit if $hit;

	my $rows = $self->{store}->list_genre_index();
	$self->{cache}->set($cacheKey, $rows, 900);
	return $rows;
}

sub search_by_genre_key {
	my ($self, %args) = @_;
	my $genre_key = $args{genre_key} || '';
	my $limit = $args{limit} || 100;
	my $offset = $args{offset} || 0;

	my $cacheKey = join('|',
		'search_genre_key',
		lc($genre_key),
		"l=$limit",
		"o=$offset",
	);

	my $hit = $self->{cache}->get($cacheKey);
	return $hit if $hit;

	my $rows = $self->{store}->search_stations_by_genre_key(
		genre_key => $genre_key,
		limit     => $limit,
		offset    => $offset,
	);
	$self->{cache}->set($cacheKey, $rows);
	return $rows;
}

sub indexed_station_names {
	my ($self) = @_;
	my $cacheKey = 'indexed_station_names';
	my $hit = $self->{cache}->get($cacheKey);
	return $hit if $hit;

	my $rows = $self->{store}->list_station_name_index();
	$self->{cache}->set($cacheKey, $rows, 900);
	return $rows;
}

sub search_by_station_name_key {
	my ($self, %args) = @_;
	my $station_name_key = $args{station_name_key} || '';
	my $limit = $args{limit} || 100;
	my $offset = $args{offset} || 0;

	my $cacheKey = join('|',
		'search_station_name_key',
		lc($station_name_key),
		"l=$limit",
		"o=$offset",
	);

	my $hit = $self->{cache}->get($cacheKey);
	return $hit if $hit;

	my $rows = $self->{store}->search_stations_by_station_name_key(
		station_name_key => $station_name_key,
		limit            => $limit,
		offset           => $offset,
	);
	$self->{cache}->set($cacheKey, $rows);
	return $rows;
}

sub indexed_bitrate_quality {
	my ($self) = @_;
	my $cacheKey = 'indexed_bitrate_quality';
	my $hit = $self->{cache}->get($cacheKey);
	return $hit if $hit;

	my $rows = $self->{store}->list_bitrate_quality_index();
	$self->{cache}->set($cacheKey, $rows, 900);
	return $rows;
}

sub search_by_quality_key {
	my ($self, %args) = @_;
	my $quality_key = $args{quality_key} || '';
	my $limit = $args{limit} || 100;
	my $offset = $args{offset} || 0;

	my $cacheKey = join('|',
		'search_quality_key',
		lc($quality_key),
		"l=$limit",
		"o=$offset",
	);

	my $hit = $self->{cache}->get($cacheKey);
	return $hit if $hit;

	my $rows = $self->{store}->search_stations_by_quality_key(
		quality_key => $quality_key,
		limit       => $limit,
		offset      => $offset,
	);
	$self->{cache}->set($cacheKey, $rows);
	return $rows;
}

sub indexed_codecs {
	my ($self) = @_;
	my $cacheKey = 'indexed_codecs';
	my $hit = $self->{cache}->get($cacheKey);
	return $hit if $hit;

	my $rows = $self->{store}->list_codec_index();
	$self->{cache}->set($cacheKey, $rows, 900);
	return $rows;
}

sub search_by_codec_key {
	my ($self, %args) = @_;
	my $codec_key = $args{codec_key} || '';
	my $limit = $args{limit} || 100;
	my $offset = $args{offset} || 0;

	my $cacheKey = join('|',
		'search_codec_key',
		lc($codec_key),
		"l=$limit",
		"o=$offset",
	);

	my $hit = $self->{cache}->get($cacheKey);
	return $hit if $hit;

	my $rows = $self->{store}->search_stations_by_codec_key(
		codec_key => $codec_key,
		limit     => $limit,
		offset    => $offset,
	);
	$self->{cache}->set($cacheKey, $rows);
	return $rows;
}

sub clear_cache {
	my ($self) = @_;
	$self->{cache}->clear();
}

1;
