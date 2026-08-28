# SPDX-FileCopyrightText: SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Mojo::Base -strict, -signatures;

use FindBin;
use lib "$FindBin::Bin/lib";

use Test::More;
use CavilCliTest;
use Mojo::File qw(tempdir);
use Mojolicious::Lite;

app->log->level('error');

# One novel file (long enough to fingerprint) that the server does not recognize: it always reaches the
# search. We count recognition and search requests to prove a rerun makes none, and that a generation bump
# re-runs the search.
my $dir = tempdir;
$dir->child('novel.pl')->spew(<<'CODE');
sub reconcile_inventory {
  my ($self, $catalog, $received, $options) = @_;
  my %expected = map { $_->{sku} => $_->{quantity} } @$catalog;
  my %actual   = map { $_->{sku} => $_->{quantity} } @$received;
  my @discrepancies;
  for my $sku (sort keys %expected) {
    my $want = $expected{$sku} // 0;
    my $have = $actual{$sku}   // 0;
    next if $want == $have;
    push @discrepancies, {sku => $sku, expected => $want, actual => $have, delta => $have - $want};
  }
  return {clean => (@discrepancies ? 0 : 1), discrepancies => \@discrepancies};
}
CODE

my $generation = 1;
my ($known_calls, $search_calls) = (0, 0);

get '/api/v1/code/config' => sub ($c) { $c->render(json => {k => 4, w => 8, generation => $generation}) };
post '/api/v1/code/known'        => sub ($c) { $known_calls++; $c->render(json => {}) };
post '/api/v1/code/search-batch' => sub ($c) {
  $search_calls++;
  my @results = map { {id => $_->{id}, matches => []} } @{$c->req->json->{queries}};
  $c->render(json => {results => \@results});
};

my $test = CavilCliTest->new(app);

subtest 'first run resolves the novel file over the network' => sub {
  $test->run('--all', $dir->to_string);
  is $known_calls,  1, 'recognition was asked once';
  is $search_calls, 1, 'and the residual was searched once';
};

subtest 'a rerun at the same generation makes no request at all' => sub {
  my $result = $test->run('--all', $dir->to_string);
  like $result->{stdout}, qr/1 clean/, 'the report is rebuilt from the cache';
  is $known_calls,  1, 'no further recognition request';
  is $search_calls, 1, 'no further search request';
};

subtest 'a new index generation invalidates the cached search' => sub {
  $generation = 2;
  $test->run('--all', $dir->to_string);
  is $search_calls, 2, 'the residual is searched again after a reindex';
};

done_testing;
