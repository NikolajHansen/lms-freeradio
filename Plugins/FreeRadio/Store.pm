package Plugins::FreeRadio::Store;

use strict;

use DBI;
use File::Spec::Functions qw(catfile);

use Slim::Utils::Prefs;

my %allowedFields = map { $_ => 1 } qw(genre country source);

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
			last_seen_at INTEGER NOT NULL,
			raw_payload TEXT
		)
	});

	$dbh->do('CREATE INDEX IF NOT EXISTS idx_stations_source ON stations(source)');
	$dbh->do('CREATE INDEX IF NOT EXISTS idx_stations_genre ON stations(genre)');
	$dbh->do('CREATE INDEX IF NOT EXISTS idx_stations_country ON stations(country)');
	$dbh->do('CREATE INDEX IF NOT EXISTS idx_stations_search_text ON stations(search_text)');
	$dbh->do('CREATE INDEX IF NOT EXISTS idx_stations_seen ON stations(last_seen_at)');

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
}

sub dbh {
	return $_[0]->{dbh};
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
				search_text, last_seen_at, raw_payload
			) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
				$station->{raw_payload},
			);
		}

		$dbh->commit;
		1;
	} or do {
		my $err = $@ || 'unknown sqlite transaction error';
		eval { $dbh->rollback };
		die $err;
	};
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

	my $sth = $self->dbh->prepare("SELECT DISTINCT $field AS value FROM stations WHERE $field IS NOT NULL AND $field != '' ORDER BY value COLLATE NOCASE");
	$sth->execute();

	my @values;
	while (my ($value) = $sth->fetchrow_array) {
		push @values, $value;
	}

	return \@values;
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
	my $sth = $self->dbh->prepare('INSERT INTO search_history (query, created_at) VALUES (?, ?)');
	$sth->execute($query, time());
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

1;
