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

# max_fingerprints is deliberately small here so a normal code file trips the "too large by fingerprints" rule
# without a multi-megabyte fixture; the byte rule is exercised separately with an actual oversized blob.
my $MAX = 12;

my $dir = tempdir;

# Too short: fewer than MIN_FINGERPRINTS.
$dir->child('tiny.txt')->spew("hi there\n");

# Too large by fingerprints: a real code file that winnows to more than $MAX.
$dir->child('big.pl')->spew(<<'CODE');
sub parse_widget_config {
  my ($self, $path, $options) = @_;
  my $raw = Mojo::File->new($path)->slurp;
  my %config;
  for my $line (split /\n/, $raw) {
    next if $line =~ /^\s*#/;
    next unless $line =~ /^(\w+)\s*=\s*(.+)$/;
    $config{$1} = $2;
  }
  $config{timeout}  //= $options->{timeout}  // 30;
  $config{retries}  //= $options->{retries}  // 3;
  $config{encoding} //= $options->{encoding} // 'utf-8';
  return \%config;
}

sub render_widget_table {
  my ($self, $rows, $columns) = @_;
  my @lines;
  for my $row (@$rows) {
    push @lines, join "\t", map { $row->{$_} // '' } @$columns;
  }
  return join "\n", @lines;
}
CODE

# Too large by bytes: over MAX_FILE_BYTES (2 MiB).
$dir->child('blob.txt')->spew('lorem ipsum dolor ' x 150_000);    # ~2.7 MB

# Fixture sanity: big.pl really does exceed the cap, so the test asserts the rule rather than an accident.
my $big_fps = do {
  my %seen;
  scalar grep { !$seen{$_}++ }
    map { $_->[0] } @{Cavil::Matcher::fingerprint_file($dir->child('big.pl')->to_string, 4, 8)};
};
cmp_ok $big_fps, '>', $MAX, 'the big file winnows to more than the cap (fixture sanity)';

get '/api/v1/code/config' => {json => {k => 4, w => 8, max_fingerprints => $MAX}};

# Nothing is recognized; record every id the client actually asks the server to search.
post '/api/v1/code/known' => {json => {}};
my @searched_ids;
post '/api/v1/code/search-batch' => sub ($c) {
  push @searched_ids, map { $_->{id} } @{$c->req->json->{queries}};
  $c->render(json => {results => []});
};

my $test = CavilCliTest->new(app);

subtest 'too-large files are skipped with a reason, never sent to the server' => sub {
  my $result = $test->run('--all', $dir->to_string);

  like $result->{stdout}, qr/3 files/,   'all three files are accounted for';
  like $result->{stdout}, qr/3 skipped/, 'and all three are skipped, none searched';

  like $result->{stdout}, qr/big\.pl\s+too large/,   'a file winnowing past the cap is reported too large';
  like $result->{stdout}, qr/blob\.txt\s+too large/, 'an oversized blob is reported too large (byte rule)';
  like $result->{stdout}, qr/tiny\.txt\s+too short/, 'a tiny file is reported too short';

  is scalar @searched_ids, 0, 'no skipped file is ever sent as a query';
};

done_testing;
