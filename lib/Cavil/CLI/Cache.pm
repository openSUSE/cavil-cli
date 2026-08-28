# SPDX-FileCopyrightText: SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package Cavil::CLI::Cache;
use Mojo::Base -base, -signatures;

use Mojo::File qw(path);
use Mojo::JSON qw(from_json to_json);
use Mojo::SQLite;
use Mojo::URL;
use Mojo::Util qw(sha1_sum);

# A persistent, per-instance cache so repeated and interrupted scans put almost no load on Cavil. SQLite (not a
# single rewritten file) so each batch is a cheap upsert that scales to a huge tree and is durable the moment
# it is written, which is what makes an interrupted scan resume. Two things are cached, keyed by content hash:
#   known  - a recognized hash's licenses and risk (a property of the bytes), plus a package/path that carries
#            it and that carrier's declared license; kept indefinitely.
#   search - the provenance of a residual file, which depends on what the server has indexed, so it is tagged
#            with the index generation and cleared when that changes (a reindex must not leave a stale answer).
# The database is one file per instance host, so two Cavil servers never collide.
#
# ponytail: known is kept across reindexes for its immutable licenses/risk, but the carrier package and its
# declared license it also holds are index-derived and can go stale after a reindex (a rare, advisory-only drift
# - the declared license is a display hint that never drives the gate). Generation-tag known like search if that
# staleness ever matters.

# Well under SQLite's bound variable limit, for reading a set of hashes back.
use constant IN_CHUNK => 500;

has 'url';
has exclude    => sub { [] };    # the self-exclude set; results depend on it, so it namespaces the cache file
has dir        => sub { path($ENV{XDG_CACHE_HOME} || (($ENV{HOME} // '.') . '/.cache'))->child('cavil-cli') };
has generation => 0;
has sqlite     => sub ($self) {
  $self->dir->make_path unless -d $self->dir;
  my $sql = Mojo::SQLite->new('sqlite:' . $self->_file);
  $sql->auto_migrate(1)->migrations->name('cavil-cli')->from_string(<<'MIGRATIONS');
-- 1 up
-- Both tables store the whole record as JSON: known keeps a recognition (licenses, risk, carrier package/path,
-- declared license), search keeps a generation-tagged provenance result. Regenerable, so it is fine to drop.
CREATE TABLE known  (hash TEXT PRIMARY KEY, result TEXT NOT NULL);
CREATE TABLE search (hash TEXT PRIMARY KEY, generation INTEGER NOT NULL, result TEXT NOT NULL);
MIGRATIONS
  return $sql;
};

sub load ($self) { $self->sqlite->db; return $self }

# Adopt the server's index generation and drop cached search results from any older one; recognition is kept.
sub for_generation ($self, $gen) {
  $self->generation($gen // 0);
  $self->sqlite->db->query('DELETE FROM search WHERE generation <> ?', $self->generation);
  return $self;
}

sub known  ($self, $hashes) { return $self->_load('known',  $hashes) }
sub search ($self, $hashes) { return $self->_load('search', $hashes) }

# Read a set of hashes back from one table, chunked to stay under SQLite's bound-variable limit. The table name
# is internal (never user input), so interpolating it is safe.
sub _load ($self, $table, $hashes) {
  my %out;
  my $db = $self->sqlite->db;
  for my $chunk (_chunks($hashes)) {
    my $sql = "SELECT hash, result FROM $table WHERE hash IN (" . join(',', ('?') x @$chunk) . ')';
    $out{$_->{hash}} = from_json($_->{result}) for @{$db->query($sql, @$chunk)->hashes};
  }
  return \%out;
}

sub store_known ($self, $map) {
  return $self unless %$map;
  my $db = $self->sqlite->db;
  my $tx = $db->begin;
  $db->query('INSERT OR REPLACE INTO known (hash, result) VALUES (?, ?)', $_, to_json($map->{$_})) for keys %$map;
  $tx->commit;
  return $self;
}

sub store_search ($self, $map) {
  return $self unless %$map;
  my $db = $self->sqlite->db;
  my $tx = $db->begin;
  $db->query('INSERT OR REPLACE INTO search (hash, generation, result) VALUES (?, ?, ?)',
    $_, $self->generation, to_json($map->{$_}))
    for keys %$map;
  $tx->commit;
  return $self;
}

# One database per instance host, and per self-exclude set: a recognition or search answer depends on which
# packages are excluded, so a run that excludes "foo" must not read rows a plain run (or a different repo) wrote.
# The empty set keeps the plain "host.sqlite" name, so the common case is unchanged.
sub _file ($self) {
  my $host = Mojo::URL->new($self->url // '')->host // 'default';
  $host =~ s/[^A-Za-z0-9._-]/_/g;
  my %seen;
  my @exclude = sort grep { !$seen{$_}++ } @{$self->exclude};
  my $suffix  = @exclude ? '.' . substr(sha1_sum(join "\0", @exclude), 0, 12) : '';
  return $self->dir->child("$host$suffix.sqlite")->to_string;
}

sub _chunks ($list) {
  my @chunks;
  for (my $i = 0; $i < @$list; $i += IN_CHUNK) {
    my $end = $i + IN_CHUNK - 1;
    $end = $#$list if $end > $#$list;
    push @chunks, [@{$list}[$i .. $end]];
  }
  return @chunks;
}

1;
