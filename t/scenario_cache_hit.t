# SPDX-FileCopyrightText: SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Mojo::Base -strict, -signatures;

use FindBin;
use lib "$FindBin::Bin/lib";

use Test::More;
use CavilCliTest;
use Cavil::Matcher;
use Mojo::File qw(tempdir);
use Mojolicious::Lite;

app->log->level('error');

# Two files Cavil knows byte-for-byte. The first run recognizes them over the network; the second should be
# answered entirely from the local cache, so the recognition endpoint is not called again.
my $dir = tempdir;
$dir->child('a.txt')->spew("the first known file\nwith some content\n");
$dir->child('b.txt')->spew("the second known file\nwith other content\n");
my %known = map { Cavil::Matcher::content_hash($dir->child($_)->to_string) => {licenses => ['MIT'], risk => 1} }
  qw(a.txt b.txt);

my $known_calls = 0;

get '/api/v1/code/config' => {json => {k => 4, w => 8}};

post '/api/v1/code/known' => sub ($c) {
  $known_calls++;
  my %answer = map { $_ => $known{$_} } grep { $known{$_} } @{$c->req->json->{hashes}};
  $c->render(json => \%answer);
};

post '/api/v1/code/search-batch' => {json => {results => []}};

my $test = CavilCliTest->new(app);

subtest 'the first run recognizes over the network' => sub {
  my $result = $test->run('--all', $dir->to_string);
  is $result->{exit}, 0, 'all known and low risk, gate passes';
  like $result->{stdout}, qr/2 with known code/, 'both files recognized';
  is $known_calls, 1, 'the recognition endpoint was called once';
};

subtest 'the second run is served from the cache' => sub {
  my $result = $test->run('--all', $dir->to_string);
  is $result->{exit}, 0, 'still clean';
  like $result->{stdout}, qr/2 with known code/, 'both files still recognized';
  is $known_calls, 1, 'the recognition endpoint was not called again';
};

done_testing;
