package Plugins::FreeRadio::Store;

use strict;

use DBI;
use File::Spec::Functions qw(catfile);

use Slim::Utils::Prefs;

my %allowedFields = map { $_ => 1 } qw(genre country source codec);

sub new {
	my ($class, %args) = @_;
	my $serverPrefs = preferences('server');
	my $cachedir = $serverPrefs->get('cachedir') || '/config/cache';
	my $dbPath = catfile($cachedir, 'freeradio.db');

	my $self = {
		log     => $args{log},
		db_path => $dbPath,
		dbh     => undef,
	};

	bless $self, $class;
	$self->_init();
	return $self;
}

sub _init {
	my ($self) = @_;
	my $dbh = DBI->connect(
		"dbi:SQLite:dbname=$self->{db_path}",
		'',
		'',
		{
			RaiseError         => 1,
			PrintError         => 0,
			AutoCommit         => 1,
			sqlite_unicode     => 1,
			sqlite_busy_timeout => 5000,
		}
	);

	$self->{dbh} = $dbh;

	$dbh->do(qq{
		CREATE TABLE IF NOT EXISTS stations (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			uid TEXT NOT NULL,
			source TEXT NOT NULL,
			source_id TEXT,
			name TEXT NOT NULL,
			description TEXT,
			country TEXT,
			genre TEXT,
			stream_url TEXT NOT NULL,
			codec TEXT,
			bitrate INTEGER,
			homepage TEXT,
			network TEXT,
			channel TEXT,
			search_text TEXT,
			last_seen_at INTEGER NOT NULL
		)
	});

	# Drop legacy raw_payload column if it exists (SQLite >= 3.35).
	eval {
		my $cols = $dbh->selectall_arrayref('PRAGMA table_info(stations)');
		if (grep { $_->[1] eq 'raw_payload' } @$cols) {
			$dbh->do('ALTER TABLE stations DROP COLUMN raw_payload');
		}
	};

	$dbh->do('CREATE INDEX IF NOT EXISTS idx_stations_source ON stations(source)');
	$dbh->do('CREATE INDEX IF NOT EXISTS idx_stations_genre ON stations(genre)');
	$dbh->do('CREATE INDEX IF NOT EXISTS idx_stations_country ON stations(country)');
	$dbh->do('CREATE INDEX IF NOT EXISTS idx_stations_search_text ON stations(search_text)');
	$dbh->do('CREATE INDEX IF NOT EXISTS idx_stations_seen ON stations(last_seen_at)');

	$dbh->do(qq{
		CREATE TABLE IF NOT EXISTS genre_index (
			genre_key TEXT PRIMARY KEY,
			genre_label TEXT NOT NULL,
			station_count INTEGER NOT NULL
		)
	});
	$dbh->do('CREATE INDEX IF NOT EXISTS idx_genre_index_count ON genre_index(station_count DESC)');

	$dbh->do(qq{
		CREATE TABLE IF NOT EXISTS genre_station_index (
			genre_key TEXT NOT NULL,
			station_uid TEXT NOT NULL,
			PRIMARY KEY (genre_key, station_uid)
		)
	});
	$dbh->do('CREATE INDEX IF NOT EXISTS idx_genre_station_uid ON genre_station_index(station_uid)');

	$dbh->do(qq{
		CREATE TABLE IF NOT EXISTS station_name_index (
			station_name_key TEXT PRIMARY KEY,
			station_name_label TEXT NOT NULL,
			station_count INTEGER NOT NULL
		)
	});
	$dbh->do('CREATE INDEX IF NOT EXISTS idx_station_name_index_count ON station_name_index(station_count DESC)');

	$dbh->do(qq{
		CREATE TABLE IF NOT EXISTS station_name_station_index (
			station_name_key TEXT NOT NULL,
			station_uid TEXT NOT NULL,
			PRIMARY KEY (station_name_key, station_uid)
		)
	});
	$dbh->do('CREATE INDEX IF NOT EXISTS idx_station_name_station_uid ON station_name_station_index(station_uid)');

	$dbh->do(qq{
		CREATE TABLE IF NOT EXISTS bitrate_quality_index (
			quality_key TEXT PRIMARY KEY,
			quality_label TEXT NOT NULL,
			station_count INTEGER NOT NULL
		)
	});
	$dbh->do('CREATE INDEX IF NOT EXISTS idx_bitrate_quality_count ON bitrate_quality_index(station_count DESC)');

	$dbh->do(qq{
		CREATE TABLE IF NOT EXISTS bitrate_quality_station_index (
			quality_key TEXT NOT NULL,
			station_uid TEXT NOT NULL,
			PRIMARY KEY (quality_key, station_uid)
		)
	});
	$dbh->do('CREATE INDEX IF NOT EXISTS idx_bitrate_quality_station_uid ON bitrate_quality_station_index(station_uid)');

	$dbh->do(qq{
		CREATE TABLE IF NOT EXISTS codec_index (
			codec_key TEXT PRIMARY KEY,
			codec_label TEXT NOT NULL,
			station_count INTEGER NOT NULL
		)
	});
	$dbh->do('CREATE INDEX IF NOT EXISTS idx_codec_index_count ON codec_index(station_count DESC)');

	$dbh->do(qq{
		CREATE TABLE IF NOT EXISTS codec_station_index (
			codec_key TEXT NOT NULL,
			station_uid TEXT NOT NULL,
			PRIMARY KEY (codec_key, station_uid)
		)
	});
	$dbh->do('CREATE INDEX IF NOT EXISTS idx_codec_station_uid ON codec_station_index(station_uid)');

	$dbh->do(qq{
		CREATE TABLE IF NOT EXISTS favorites (
			uid TEXT PRIMARY KEY,
			source TEXT,
			source_id TEXT,
			name TEXT NOT NULL,
			description TEXT,
			country TEXT,
			genre TEXT,
			stream_url TEXT NOT NULL,
			codec TEXT,
			bitrate INTEGER,
			homepage TEXT,
			network TEXT,
			channel TEXT,
			search_text TEXT,
			created_at INTEGER NOT NULL
		)
	});

	$dbh->do(qq{
		CREATE TABLE IF NOT EXISTS search_history (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			query TEXT NOT NULL,
			created_at INTEGER NOT NULL
		)
	});

	$dbh->do(qq{
		CREATE TABLE IF NOT EXISTS sync_state (
			state_key TEXT PRIMARY KEY,
			state_value TEXT,
			updated_at INTEGER NOT NULL
		)
	});

	$dbh->do(qq{
		CREATE TABLE IF NOT EXISTS canonical_genres (
			sort_order INTEGER NOT NULL,
			label      TEXT NOT NULL,
			keywords   TEXT NOT NULL
		)
	});
}

sub dbh {
	return $_[0]->{dbh};
}

use constant DEFAULT_GENRES_TEXT => <<'END_GENRES';
Pop: pop, top 40, pop music, chart, hits, popular, adult contemporary, easy listening
Rock: rock, classic rock, hard rock, punk, grunge, alternative, indie, prog
Metal: metal, heavy metal, death metal, black metal, thrash, doom
Jazz: jazz, smooth jazz, jazz fusion, bebop, big band, swing, blues jazz
Classical: classical, symphony, orchestra, opera, baroque, chamber
Electronic: electronic, edm, techno, trance, house, dance, ambient, dubstep, drum and bass, electro, electronica
Country: country, americana, bluegrass, western, outlaw country
Hip-Hop: hip-hop, hip hop, hiphop, rap, urban, rnb, r&b, rhythm and blues
World: world, latin, reggae, folk, ethnic, celtic, salsa, cumbia, afrobeat
News & Talk: news, talk, speech, information, public radio, commentary, politics
Christian: christian, gospel, religious, worship, praise, spiritual, inspirational
Oldies: oldies, 60s, 70s, 80s, 90s, retro, throwback, classic hits, nostalgia
Blues: blues, delta blues, chicago blues, soul blues
Soul & Funk: soul, funk, motown, disco, groove
END_GENRES

sub sync_canonical_genres {
	my ($self, $text) = @_;
	$text = DEFAULT_GENRES_TEXT unless defined $text && $text =~ /\S/;

	my @genres = _parse_genres_text($text);
	my $dbh = $self->dbh;

	my $in_txn = !$dbh->{AutoCommit};
	$dbh->begin_work unless $in_txn;
	eval {
		$dbh->do('DELETE FROM canonical_genres');
		my $sth = $dbh->prepare(
			'INSERT INTO canonical_genres (sort_order, label, keywords) VALUES (?, ?, ?)'
		);
		my $i = 0;
		for my $g (@genres) {
			$sth->execute($i++, $g->{label}, join(',', @{ $g->{keywords} }));
		}
		$dbh->commit unless $in_txn;
	} or do {
		eval { $dbh->rollback } unless $in_txn;
		die $@ || 'sync_canonical_genres failed';
	};
}

sub list_canonical_genres {
	my ($self) = @_;
	my $sth = $self->dbh->prepare(
		'SELECT label, keywords FROM canonical_genres ORDER BY sort_order ASC'
	);
	$sth->execute();
	my @genres;
	while (my $row = $sth->fetchrow_hashref) {
		push @genres, {
			label    => $row->{label},
			keywords => [ split /,/, $row->{keywords} ],
		};
	}
	return \@genres;
}

sub genres_as_text {
	my ($self) = @_;
	my $genres = $self->list_canonical_genres();
	return DEFAULT_GENRES_TEXT unless @$genres;
	return join("\n", map { "$_->{label}: " . join(', ', @{ $_->{keywords} }) } @$genres) . "\n";
}

sub _parse_genres_text {
	my ($text) = @_;
	my @genres;
	for my $line (split /\n/, $text) {
		$line =~ s/^\s+|\s+$//g;
		next unless $line =~ /\S/;
		next if $line =~ /^#/;
		my ($label, $kw_str) = split /:/, $line, 2;
		next unless defined $kw_str;
		$label   =~ s/^\s+|\s+$//g;
		$kw_str  =~ s/^\s+|\s+$//g;
		next unless length $label && length $kw_str;
		my @keywords = grep { length $_ } map { s/^\s+|\s+$//gr } split /,/, $kw_str;
		next unless @keywords;
		push @genres, { label => $label, keywords => \@keywords };
	}
	return @genres;
}

sub replace_source_stations {
	my ($self, $source, $stations) = @_;
	$stations ||= [];

	my $dbh = $self->dbh;
	$dbh->begin_work;
	eval {
		my $delete = $dbh->prepare('DELETE FROM stations WHERE source = ?');
		$delete->execute($source);

		my $insert = $dbh->prepare(q{
			INSERT INTO stations (
				uid, source, source_id, name, description, country, genre,
				stream_url, codec, bitrate, homepage, network, channel,
				search_text, last_seen_at
			) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		});

		for my $station (@$stations) {
			$insert->execute(
				$station->{uid},
				$source,
				$station->{source_id},
				$station->{name},
				$station->{description},
				$station->{country},
				$station->{genre},
				$station->{stream_url},
				$station->{codec},
				$station->{bitrate},
				$station->{homepage},
				$station->{network},
				$station->{channel},
				$station->{search_text},
				$station->{last_seen_at},
			);
		}

		$self->_rebuild_indexes($dbh);

		$dbh->commit;
		1;
	} or do {
		my $err = $@ || 'unknown sqlite transaction error';
		eval { $dbh->rollback };
		die $err;
	};
}

sub clear_stations {
	my ($self) = @_;
	$self->dbh->do('DELETE FROM stations');
	$self->dbh->do('DELETE FROM genre_station_index');
	$self->dbh->do('DELETE FROM genre_index');
	$self->dbh->do('DELETE FROM station_name_station_index');
	$self->dbh->do('DELETE FROM station_name_index');
	$self->dbh->do('DELETE FROM bitrate_quality_station_index');
	$self->dbh->do('DELETE FROM bitrate_quality_index');
	$self->dbh->do('DELETE FROM codec_station_index');
	$self->dbh->do('DELETE FROM codec_index');
}

sub clear_sync_state {
	my ($self) = @_;
	$self->dbh->do('DELETE FROM sync_state');
}

sub search_stations {
	my ($self, %args) = @_;
	my $query = $args{query};
	my $filters = $args{filters} || {};
	my $limit = $args{limit} || 100;
	my $offset = $args{offset} || 0;

	my @where;
	my @bind;

	if (defined $query && length $query) {
		push @where, 'search_text LIKE ?';
		push @bind, '%' . lc($query) . '%';
	}

	for my $field (keys %$filters) {
		next unless $allowedFields{$field};
		next unless defined $filters->{$field} && length $filters->{$field};
		push @where, "LOWER($field) = LOWER(?)";
		push @bind, $filters->{$field};
	}

	my $sql = q{
		SELECT uid, source, source_id, name, description, country, genre,
		       stream_url, codec, bitrate, homepage, network, channel, search_text
		FROM stations
	};

	if (@where) {
		$sql .= ' WHERE ' . join(' AND ', @where);
	}

	$sql .= ' ORDER BY name COLLATE NOCASE ASC LIMIT ? OFFSET ?';
	push @bind, $limit, $offset;

	my $sth = $self->dbh->prepare($sql);
	$sth->execute(@bind);

	my @rows;
	while (my $row = $sth->fetchrow_hashref) {
		push @rows, $row;
	}

	return \@rows;
}

sub list_distinct_values {
	my ($self, $field) = @_;
	die "invalid field $field" unless $allowedFields{$field};

	if ($field eq 'genre') {
		my $sth = $self->dbh->prepare(q{
			SELECT genre_label AS value
			FROM genre_index
			ORDER BY station_count DESC, genre_label COLLATE NOCASE ASC
		});
		$sth->execute();
		my @values;
		while (my ($value) = $sth->fetchrow_array) {
			push @values, $value;
		}
		return \@values;
	}

	my $sth = $self->dbh->prepare("SELECT DISTINCT $field AS value FROM stations WHERE $field IS NOT NULL AND $field != '' ORDER BY value COLLATE NOCASE");
	$sth->execute();

	my @values;
	while (my ($value) = $sth->fetchrow_array) {
		push @values, $value;
	}

	return \@values;
}

sub list_genre_index {
	my ($self) = @_;
	my $sth = $self->dbh->prepare(q{
		SELECT genre_key, genre_label, station_count
		FROM genre_index
		ORDER BY genre_label COLLATE NOCASE ASC
	});
	$sth->execute();

	my @rows;
	while (my $row = $sth->fetchrow_hashref) {
		push @rows, $row;
	}
	return \@rows;
}

sub search_stations_by_genre_key {
	my ($self, %args) = @_;
	my $genre_key = $args{genre_key};
	my $limit = $args{limit} || 100;
	my $offset = $args{offset} || 0;
	return [] unless defined $genre_key && length $genre_key;

	my $sth = $self->dbh->prepare(q{
		SELECT s.uid, s.source, s.source_id, s.name, s.description, s.country, s.genre,
		       s.stream_url, s.codec, s.bitrate, s.homepage, s.network, s.channel, s.search_text
		FROM genre_station_index gsi
		JOIN stations s ON s.uid = gsi.station_uid
		WHERE gsi.genre_key = ?
		ORDER BY s.name COLLATE NOCASE ASC
		LIMIT ? OFFSET ?
	});
	$sth->execute($genre_key, $limit, $offset);

	my @rows;
	while (my $row = $sth->fetchrow_hashref) {
		push @rows, $row;
	}
	return \@rows;
}

sub list_station_name_index {
	my ($self) = @_;
	my $sth = $self->dbh->prepare(q{
		SELECT station_name_key, station_name_label, station_count
		FROM station_name_index
		ORDER BY station_name_label COLLATE NOCASE ASC
	});
	$sth->execute();

	my @rows;
	while (my $row = $sth->fetchrow_hashref) {
		push @rows, $row;
	}
	return \@rows;
}

sub search_stations_by_station_name_key {
	my ($self, %args) = @_;
	my $station_name_key = $args{station_name_key};
	my $limit = $args{limit} || 100;
	my $offset = $args{offset} || 0;
	return [] unless defined $station_name_key && length $station_name_key;

	my $sth = $self->dbh->prepare(q{
		SELECT s.uid, s.source, s.source_id, s.name, s.description, s.country, s.genre,
		       s.stream_url, s.codec, s.bitrate, s.homepage, s.network, s.channel, s.search_text
		FROM station_name_station_index snsi
		JOIN stations s ON s.uid = snsi.station_uid
		WHERE snsi.station_name_key = ?
		ORDER BY s.name COLLATE NOCASE ASC
		LIMIT ? OFFSET ?
	});
	$sth->execute($station_name_key, $limit, $offset);

	my @rows;
	while (my $row = $sth->fetchrow_hashref) {
		push @rows, $row;
	}
	return \@rows;
}

sub list_bitrate_quality_index {
	my ($self) = @_;
	my $sth = $self->dbh->prepare(q{
		SELECT quality_key, quality_label, station_count
		FROM bitrate_quality_index
		ORDER BY station_count DESC, quality_label COLLATE NOCASE ASC
	});
	$sth->execute();

	my @rows;
	while (my $row = $sth->fetchrow_hashref) {
		push @rows, $row;
	}
	return \@rows;
}

sub search_stations_by_quality_key {
	my ($self, %args) = @_;
	my $quality_key = $args{quality_key};
	my $limit = $args{limit} || 100;
	my $offset = $args{offset} || 0;
	return [] unless defined $quality_key && length $quality_key;

	my $sth = $self->dbh->prepare(q{
		SELECT s.uid, s.source, s.source_id, s.name, s.description, s.country, s.genre,
		       s.stream_url, s.codec, s.bitrate, s.homepage, s.network, s.channel, s.search_text
		FROM bitrate_quality_station_index bqsi
		JOIN stations s ON s.uid = bqsi.station_uid
		WHERE bqsi.quality_key = ?
		ORDER BY s.name COLLATE NOCASE ASC
		LIMIT ? OFFSET ?
	});
	$sth->execute($quality_key, $limit, $offset);

	my @rows;
	while (my $row = $sth->fetchrow_hashref) {
		push @rows, $row;
	}
	return \@rows;
}

sub list_codec_index {
	my ($self) = @_;
	my $sth = $self->dbh->prepare(q{
		SELECT codec_key, codec_label, station_count
		FROM codec_index
		ORDER BY codec_label COLLATE NOCASE ASC
	});
	$sth->execute();

	my @rows;
	while (my $row = $sth->fetchrow_hashref) {
		push @rows, $row;
	}
	return \@rows;
}

sub search_stations_by_codec_key {
	my ($self, %args) = @_;
	my $codec_key = $args{codec_key};
	my $limit = $args{limit} || 100;
	my $offset = $args{offset} || 0;
	return [] unless defined $codec_key && length $codec_key;

	my $sth = $self->dbh->prepare(q{
		SELECT s.uid, s.source, s.source_id, s.name, s.description, s.country, s.genre,
		       s.stream_url, s.codec, s.bitrate, s.homepage, s.network, s.channel, s.search_text
		FROM codec_station_index csi
		JOIN stations s ON s.uid = csi.station_uid
		WHERE csi.codec_key = ?
		ORDER BY s.name COLLATE NOCASE ASC
		LIMIT ? OFFSET ?
	});
	$sth->execute($codec_key, $limit, $offset);

	my @rows;
	while (my $row = $sth->fetchrow_hashref) {
		push @rows, $row;
	}
	return \@rows;
}

sub add_favorite {
	my ($self, $uid) = @_;
	my $sth = $self->dbh->prepare(q{
		SELECT uid, source, source_id, name, description, country, genre,
		       stream_url, codec, bitrate, homepage, network, channel, search_text
		FROM stations WHERE uid = ? LIMIT 1
	});
	$sth->execute($uid);
	my $row = $sth->fetchrow_hashref;
	return unless $row;

	my $insert = $self->dbh->prepare(q{
		INSERT OR REPLACE INTO favorites (
			uid, source, source_id, name, description, country, genre, stream_url,
			codec, bitrate, homepage, network, channel, search_text, created_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	});

	$insert->execute(
		$row->{uid},
		$row->{source},
		$row->{source_id},
		$row->{name},
		$row->{description},
		$row->{country},
		$row->{genre},
		$row->{stream_url},
		$row->{codec},
		$row->{bitrate},
		$row->{homepage},
		$row->{network},
		$row->{channel},
		$row->{search_text},
		time(),
	);
}

sub remove_favorite {
	my ($self, $uid) = @_;
	my $sth = $self->dbh->prepare('DELETE FROM favorites WHERE uid = ?');
	$sth->execute($uid);
}

sub list_favorites {
	my ($self) = @_;
	my $sth = $self->dbh->prepare(q{
		SELECT uid, source, source_id, name, description, country, genre,
		       stream_url, codec, bitrate, homepage, network, channel, search_text
		FROM favorites
		ORDER BY created_at DESC, name COLLATE NOCASE ASC
	});
	$sth->execute();

	my @rows;
	while (my $row = $sth->fetchrow_hashref) {
		push @rows, $row;
	}
	return \@rows;
}

sub record_search {
	my ($self, $query) = @_;
	return unless defined $query && $query ne '';
	eval {
		my $sth = $self->dbh->prepare('INSERT INTO search_history (query, created_at) VALUES (?, ?)');
		$sth->execute($query, time());
		1;
	} or do {
		my $err = $@ || 'unknown sqlite error';
		$self->{log} && $self->{log}->warn("failed recording search history: $err");
	};
}

sub set_sync_state {
	my ($self, $key, $value) = @_;
	my $sth = $self->dbh->prepare(q{
		INSERT OR REPLACE INTO sync_state (state_key, state_value, updated_at)
		VALUES (?, ?, ?)
	});
	$sth->execute($key, defined $value ? "$value" : undef, time());
}

sub get_sync_state {
	my ($self, $key) = @_;
	my $sth = $self->dbh->prepare('SELECT state_value FROM sync_state WHERE state_key = ?');
	$sth->execute($key);
	my ($value) = $sth->fetchrow_array;
	return $value;
}

sub count_stations {
	my ($self) = @_;
	my ($count) = $self->dbh->selectrow_array('SELECT COUNT(*) FROM stations');
	return $count || 0;
}

sub get_station_by_uid {
	my ($self, $uid) = @_;
	return unless defined $uid && length $uid;

	my $sth = $self->dbh->prepare(q{
		SELECT uid, source, source_id, name, description, country, genre,
		       stream_url, codec, bitrate, homepage, network, channel, search_text
		FROM stations
		WHERE uid = ?
		LIMIT 1
	});
	$sth->execute($uid);
	return $sth->fetchrow_hashref;
}

sub get_station_by_stream_url {
	my ($self, $url) = @_;
	return unless defined $url && length $url;

	my $sth = $self->dbh->prepare(q{
		SELECT uid, source, source_id, name, description, country, genre,
		       stream_url, codec, bitrate, homepage, network, channel, search_text
		FROM stations
		WHERE stream_url = ?
		LIMIT 1
	});
	$sth->execute($url);
	my $row = $sth->fetchrow_hashref;
	return $row if $row;

	# Fallback: strip query params for rough matching.
	(my $base = $url) =~ s/\?.*$//;
	return unless length $base;

	$sth = $self->dbh->prepare(q{
		SELECT uid, source, source_id, name, description, country, genre,
		       stream_url, codec, bitrate, homepage, network, channel, search_text
		FROM stations
		WHERE stream_url = ?
		   OR stream_url LIKE ?
		LIMIT 1
	});
	$sth->execute($base, $base . '?%');
	return $sth->fetchrow_hashref;
}

sub is_favorite {
	my ($self, $uid) = @_;
	return 0 unless defined $uid && length $uid;
	my ($exists) = $self->dbh->selectrow_array('SELECT 1 FROM favorites WHERE uid = ? LIMIT 1', undef, $uid);
	return $exists ? 1 : 0;
}

sub _rebuild_indexes {
	my ($self, $dbh) = @_;
	$dbh ||= $self->dbh;

	$dbh->do('DELETE FROM genre_station_index');
	$dbh->do('DELETE FROM genre_index');
	$dbh->do('DELETE FROM station_name_station_index');
	$dbh->do('DELETE FROM station_name_index');
	$dbh->do('DELETE FROM bitrate_quality_station_index');
	$dbh->do('DELETE FROM bitrate_quality_index');
	$dbh->do('DELETE FROM codec_station_index');
	$dbh->do('DELETE FROM codec_index');

	# Load canonical genres — fall back to defaults if table is empty.
	my $canonicalRows = $dbh->selectall_arrayref(
		'SELECT label, keywords FROM canonical_genres ORDER BY sort_order ASC',
		{ Slice => {} }
	) || [];
	if (!@$canonicalRows) {
		$self->sync_canonical_genres(undef);
		$canonicalRows = $dbh->selectall_arrayref(
			'SELECT label, keywords FROM canonical_genres ORDER BY sort_order ASC',
			{ Slice => {} }
		) || [];
	}
	my @canonicalGenres = map {
		my $label = $_->{label};
		my $key   = lc($label);
		$key =~ s/[^a-z0-9]+/_/g;
		{
			key      => $key,
			label    => $label,
			keywords => [ map { lc($_) } split /,/, $_->{keywords} ],
		}
	} @$canonicalRows;

	my $rows = $dbh->selectall_arrayref(
		q{SELECT uid, genre, name, bitrate, codec FROM stations},
		{ Slice => {} }
	) || [];

	my (%genreCounts, %genreStationSeen);
	my (%stationNameCounts, %stationNameLabel, %stationNameStationSeen);
	my (%qualityCounts, %qualityStationSeen);
	my (%codecCounts, %codecStationSeen);

	for my $row (@$rows) {
		my $uid = $row->{uid};
		next unless defined $uid && length $uid;

		my $rawGenre = lc($row->{genre} || '');
		for my $cg (@canonicalGenres) {
			for my $kw (@{ $cg->{keywords} }) {
				if (index($rawGenre, $kw) >= 0) {
					next if $genreStationSeen{ $cg->{key} }{$uid}++;
					$genreCounts{ $cg->{key} }++;
					last;
				}
			}
		}

		my ($nameKey, $nameLabel) = _normalize_station_name($row->{name});
		if ($nameKey) {
			if (!$stationNameStationSeen{$nameKey}{$uid}++) {
				$stationNameCounts{$nameKey}++;
				$stationNameLabel{$nameKey} ||= $nameLabel;
			}
		}

		my ($qualityKey, $qualityLabel) = _bitrate_quality($row->{bitrate});
		if (!$qualityStationSeen{$qualityKey}{$uid}++) {
			$qualityCounts{$qualityKey}++;
		}

		my $codecKey = lc($row->{codec} || '');
		if ($codecKey && $codecKey =~ /^(?:mp3|aac|ogg|opus|flac|webm)$/) {
			if (!$codecStationSeen{$codecKey}{$uid}++) {
				$codecCounts{$codecKey}++;
			}
		}
	}

	my $insertGenre = $dbh->prepare(
		'INSERT INTO genre_index (genre_key, genre_label, station_count) VALUES (?, ?, ?)'
	);
	my $insertGenreRel = $dbh->prepare(
		'INSERT INTO genre_station_index (genre_key, station_uid) VALUES (?, ?)'
	);
	for my $cg (@canonicalGenres) {
		my $key   = $cg->{key};
		my $count = $genreCounts{$key} || 0;
		next unless $count;
		$insertGenre->execute($key, $cg->{label}, $count);
		for my $uid (keys %{ $genreStationSeen{$key} || {} }) {
			$insertGenreRel->execute($key, $uid);
		}
	}

	my @stationNameKeys = sort {
		lc($stationNameLabel{$a}) cmp lc($stationNameLabel{$b})
	} keys %stationNameCounts;

	my $insertStationName = $dbh->prepare(
		'INSERT INTO station_name_index (station_name_key, station_name_label, station_count) VALUES (?, ?, ?)'
	);
	my $insertStationNameRel = $dbh->prepare(
		'INSERT INTO station_name_station_index (station_name_key, station_uid) VALUES (?, ?)'
	);
	for my $key (@stationNameKeys) {
		$insertStationName->execute($key, $stationNameLabel{$key}, $stationNameCounts{$key});
		for my $uid (keys %{ $stationNameStationSeen{$key} || {} }) {
			$insertStationNameRel->execute($key, $uid);
		}
	}

	my @qualityOrder = qw(unknown very_low low medium high very_high);
	my %qualityLabel = (
		unknown   => 'Unknown bitrate',
		very_low  => '< 64 kbps',
		low       => '64-95 kbps',
		medium    => '96-127 kbps',
		high      => '128-191 kbps',
		very_high => '>= 192 kbps',
	);
	my $insertQuality = $dbh->prepare(
		'INSERT INTO bitrate_quality_index (quality_key, quality_label, station_count) VALUES (?, ?, ?)'
	);
	my $insertQualityRel = $dbh->prepare(
		'INSERT INTO bitrate_quality_station_index (quality_key, station_uid) VALUES (?, ?)'
	);
	for my $qualityKey (@qualityOrder) {
		my $count = $qualityCounts{$qualityKey} || 0;
		next unless $count;
		$insertQuality->execute($qualityKey, $qualityLabel{$qualityKey}, $count);
		for my $uid (keys %{ $qualityStationSeen{$qualityKey} || {} }) {
			$insertQualityRel->execute($qualityKey, $uid);
		}
	}

	my %codecLabel = (
		mp3  => 'MP3',
		aac  => 'AAC',
		ogg  => 'OGG',
		opus => 'OPUS',
		flac => 'FLAC',
		webm => 'WebM',
	);
	my @codecOrder = qw(mp3 aac ogg opus flac webm);
	my $insertCodec = $dbh->prepare(
		'INSERT INTO codec_index (codec_key, codec_label, station_count) VALUES (?, ?, ?)'
	);
	my $insertCodecRel = $dbh->prepare(
		'INSERT INTO codec_station_index (codec_key, station_uid) VALUES (?, ?)'
	);
	for my $codecKey (@codecOrder) {
		my $count = $codecCounts{$codecKey} || 0;
		next unless $count;
		$insertCodec->execute($codecKey, $codecLabel{$codecKey}, $count);
		for my $uid (keys %{ $codecStationSeen{$codecKey} || {} }) {
			$insertCodecRel->execute($codecKey, $uid);
		}
	}
}

sub _normalize_station_name {
	my ($name) = @_;
	return unless defined $name;
	$name =~ s/^\s+|\s+$//g;
	return unless length $name;

	my %junk = map { $_ => 1 } (
		'online radio', 'my radio', 'my station', 'my station name',
		'default stream', 'stream', 'radio stream', 'live stream',
		'unspecified name', 'no name', 'station name', 'this is my server name',
		'orban opticodec-pc encoder', 'mb studio', 'pregacao', 'mb studio pro',
		'icecast server', 'shoutcast server', 'internet radio',
	);
	return if $junk{ lc($name) };

	my $label = $name;
	my $key = lc($name);
	$key =~ s/\[[^\]]+\]//g;
	$key =~ s/\([^\)]*\)//g;
	$key =~ s/\b\d{2,3}\s*kbps\b//g;
	$key =~ s/[^a-z0-9]+/ /g;
	$key =~ s/\s+/ /g;
	$key =~ s/^\s+|\s+$//g;
	return unless length $key;
	return if length($key) < 3;
	return ($key, $label);
}

sub _bitrate_quality {
	my ($bitrate) = @_;
	$bitrate = int($bitrate || 0);
	return ('unknown', 'Unknown bitrate') if $bitrate <= 0;
	return ('very_low', '< 64 kbps') if $bitrate < 64;
	return ('low', '64-95 kbps') if $bitrate < 96;
	return ('medium', '96-127 kbps') if $bitrate < 128;
	return ('high', '128-191 kbps') if $bitrate < 192;
	return ('very_high', '>= 192 kbps');
}

1;
