# SPDX-FileCopyrightText: SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Mojo::Base -strict, -signatures;

use Test::More;
use Cavil::CLI::Client;
use Mojolicious::Lite;

app->log->level('error');

# Record the size of every batch the client sends, so we can prove it never asks the server for more than one
# chunk of searches at a time (a full batch of 100 could run past the request timeout on a large tree).
my (@sizes, @search_excludes);
post '/api/v1/code/search-batch' => sub ($c) {
  my $queries = $c->req->json->{queries};
  push @sizes,           scalar @$queries;
  push @search_excludes, $c->req->json->{exclude_packages};
  $c->render(json => {results => [map { {id => $_->{id}, matches => []} } @$queries]});
};

# Recognition is chunked too, so a big or slow recognition can show a remaining-count.
my (@known_sizes, @known_excludes);
post '/api/v1/code/known' => sub ($c) {
  my $hashes = $c->req->json->{hashes};
  push @known_sizes,    scalar @$hashes;
  push @known_excludes, $c->req->json->{exclude_packages};
  $c->render(json => {map { $_ => {licenses => [], risk => undef} } @$hashes});
};

my $client = Cavil::CLI::Client->new(token => 'test-token');
$client->ua->server->app(app);
$client->url('http://127.0.0.1:' . $client->ua->server->url->port);

subtest 'search_batch splits large query sets into bounded requests' => sub {
  my @queries = map { {id => "q$_", fingerprints => ['1'], span => 1} } 1 .. 60;
  my @progress;
  my $results = $client->search_batch(\@queries, on_chunk => sub ($done, $chunk) { push @progress, $done });

  is scalar @$results, 60, 'every query gets a result, in order';
  is_deeply \@sizes,    [10, 10, 10, 10, 10, 10], 'sent in small chunks, never one huge request';
  is_deeply \@progress, [10, 20, 30, 40, 50, 60], 'reports the running completed count so the caller can show progress';
  is $results->[0]{id},  'q1',  'first result maps to the first query';
  is $results->[59]{id}, 'q60', 'last result maps to the last query';
};

subtest 'known splits large hash sets and reports a running count' => sub {
  my @hashes = map {"h$_"} 1 .. 1200;
  my @progress;
  my $known = $client->known(\@hashes, on_chunk => sub ($done, $chunk) { push @progress, $done });

  is scalar keys %$known, 1200, 'every hash comes back';
  is_deeply \@known_sizes, [500, 500,  200],  'sent in bounded chunks under the server cap';
  is_deeply \@progress,    [500, 1000, 1200], 'reports the running count of hashes asked about';
};

subtest 'the self-exclude set is sent with each request, and omitted when empty' => sub {
  (@known_sizes, @known_excludes, @sizes, @search_excludes) = ();

  $client->known(['h1'], exclude_packages => ['my-project']);
  is_deeply $known_excludes[0], ['my-project'], 'known carries the exclude set';
  $client->known(['h2']);
  is $known_excludes[1], undef, 'and omits it entirely when there is nothing to exclude';

  $client->search_batch([{id => 'q1', fingerprints => ['1'], span => 1}], exclude_packages => ['my-project']);
  is_deeply $search_excludes[0], ['my-project'], 'search carries the exclude set';
  $client->search_batch([{id => 'q2', fingerprints => ['1'], span => 1}]);
  is $search_excludes[1], undef, 'and omits it when empty';
};

done_testing;
