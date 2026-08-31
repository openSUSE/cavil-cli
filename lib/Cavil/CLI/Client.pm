# SPDX-FileCopyrightText: SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package Cavil::CLI::Client;
use Mojo::Base -base, -signatures;

use Mojo::URL;
use Mojo::UserAgent;

# Per-request batch sizes. Hash lookups are cheap indexed queries, so they go in large chunks; each fingerprint
# search is a real index scan, so it goes in small chunks. Both are sized short enough to stay well under the
# request timeout on a large tree, and frequent enough that the remaining-count visibly drops instead of sitting
# on a big static number. The server caps at 1000 hashes and 100 queries.
use constant KNOWN_CHUNK  => 500;
use constant SEARCH_CHUNK => 10;

has 'log';
has 'on_wait';    # optional coderef, called ~10x/sec while a request is in flight (drives the spinner)
has token => sub { die "A Cavil API token is required (run 'cavil-cli config', or set CAVIL_API_KEY)\n" };
has ua    => sub { Mojo::UserAgent->new->connect_timeout(30)->inactivity_timeout(120) };
has url   => sub { die "A Cavil URL is required (run 'cavil-cli config', or set CAVIL_URL)\n" };

# The identity the API token belongs to: a quick way to confirm the url and token are set up right.
sub whoami ($self) {
  return $self->_request('GET', '/api/v1/whoami')->json;
}

# The winnowing parameters this instance's index uses; the client must fingerprint with the same values.
sub config ($self) {
  return $self->_request('GET', '/api/v1/code/config')->json;
}

# Batch content-hash recognition. Returns {hash => {licenses => [...], risk => N, ...}} for the hashes Cavil
# knows; unknown hashes are absent. Chunked so one huge tree stays within the per-request cap. opts{on_chunk} is
# called after each chunk with the running count of hashes asked about and that chunk's recognized hashes, so
# the caller can run a remaining-count down and persist incrementally (an interrupted recognize then resumes).
sub known ($self, $hashes, %opts) {
  my $exclude = $opts{exclude_packages};
  my %known;
  my $done = 0;
  for (my $i = 0; $i < @$hashes; $i += KNOWN_CHUNK) {
    my $end = $i + KNOWN_CHUNK - 1;
    $end = $#$hashes if $end > $#$hashes;
    my $chunk = [@{$hashes}[$i .. $end]];
    my $body  = {hashes => $chunk, ($exclude && @$exclude ? (exclude_packages => $exclude) : ())};
    my $res   = $self->_request('POST', '/api/v1/code/known', {json => $body})->json;
    %known = (%known, %$res);
    $done += @$chunk;
    $opts{on_chunk}->($done, $res) if $opts{on_chunk};
  }
  return \%known;
}

# Batch fingerprint search. Each query is {id, fingerprints => [decimal strings], span => N}; returns the
# per-query results in request order. Chunked to keep each request within the server cap; opts{on_chunk} is
# called after each chunk with the running completed count and that chunk's results, so the caller can show
# progress and persist incrementally (an interrupted scan then resumes where it left off).
sub search_batch ($self, $queries, %opts) {
  my $limit   = $opts{limit} // 10;
  my $exclude = $opts{exclude_packages};
  my @results;
  for (my $i = 0; $i < @$queries; $i += SEARCH_CHUNK) {
    my $end = $i + SEARCH_CHUNK - 1;
    $end = $#$queries if $end > $#$queries;
    my $chunk = [@{$queries}[$i .. $end]];
    my $body  = {queries => $chunk, limit => $limit, ($exclude && @$exclude ? (exclude_packages => $exclude) : ())};
    my $res   = $self->_request('POST', '/api/v1/code/search-batch', {json => $body})->json;
    my $got   = $res->{results} // [];
    push @results, @$got;
    $opts{on_chunk}->(scalar @results, $got) if $opts{on_chunk};
  }
  return \@results;
}

sub _headers ($self) {
  return {Authorization => 'Bearer ' . $self->token};
}

sub _request ($self, $method, $path, $options = {}) {
  my $ua = $self->ua;
  my $tx = $ua->build_tx($method => $self->_url($path) => $self->_headers,
    $options->{json} ? (json => $options->{json}) : ());

  # A recurring timer on the UA's own loop fires during the blocking request (that loop is what start() runs),
  # so the caller's spinner keeps moving while we wait on the server.
  my $spin = $self->on_wait;
  my $tid  = $spin ? $ua->ioloop->recurring(0.1 => $spin) : undef;
  $tx = $ua->start($tx);
  $ua->ioloop->remove($tid) if defined $tid;

  return $tx->result if $options->{ignore_errors} || !(my $err = $tx->error);

  # These are expected operational errors the caller turns into a friendly message, not bugs, so die with a
  # newline-terminated string (no Carp file/line suffix leaking to the user). Code search off is a clean 404.
  die "code_search_disabled\n"                                              if $err->{code} && $err->{code} == 404;
  die "$err->{code} response from Cavil ($method $path): $err->{message}\n" if $err->{code};
  die "Connection error from Cavil ($method $path): $err->{message}\n";
}

sub _url ($self, $path) {
  return Mojo::URL->new($self->url . $path);
}

1;
