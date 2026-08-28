# SPDX-FileCopyrightText: SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Mojo::Base -strict, -signatures;

use FindBin;
use lib "$FindBin::Bin/lib";

use Test::More;
use CavilCliTest;
use Cavil::Matcher;
use Mojo::File qw(tempdir);
use Mojo::JSON qw(decode_json);
use Mojolicious::Lite;

app->log->level('error');

# A tree with three files: one Cavil knows byte-for-byte (exact), one novel file the server matches as a
# modified copy (partial), and one too small to fingerprint (skipped).
my $dir = tempdir;
$dir->child('known.txt')->spew("a known file\nwith two lines\n");
$dir->child('tiny.txt')->spew("hi\n");
$dir->child('.env')->spew("SECRET=1\n");
$dir->child('COPYING')->spew("GNU GENERAL PUBLIC LICENSE\nVersion 2, June 1991\n" . ("boilerplate " x 40) . "\n");
$dir->child('novel.pl')->spew(<<'CODE');
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
CODE

my $known_hash = Cavil::Matcher::content_hash($dir->child('known.txt')->to_string);
my $novel_hash = Cavil::Matcher::content_hash($dir->child('novel.pl')->to_string);

# The mock instance: it records what the CLI asks, and answers from canned data keyed by the fixture.
my (@known_requests, @search_requests);

get '/api/v1/code/config' => {json => {k => 4, w => 8}};

my @known_excludes;
post '/api/v1/code/known' => sub ($c) {
  my $hashes = $c->req->json->{hashes};
  push @known_requests, $hashes;
  push @known_excludes, $c->req->json->{exclude_packages};
  $c->render(json => {$known_hash => {licenses => ['MIT'], risk => 2, package => 'coreutils', filename => 'src/ls.c'}});
};

post '/api/v1/code/search-batch' => sub ($c) {
  my $queries = $c->req->json->{queries};
  push @search_requests, $queries;
  my @results;
  for my $q (@$queries) {
    if ($q->{id} eq $novel_hash) {

      # Two matches, best-overlap first: a fuller permissive copy, then a smaller GPL one. The report must lead
      # with the higher RISK (the GPL), not the stronger overlap, or a small high-risk copy could slip the gate.
      push @results,
        {
        id      => $q->{id},
        total   => 24,
        matches => [
          {
            hash     => 'permissive1',
            licenses => ['BSD-2-Clause'],
            risk     => 2,
            aligned  => 24,
            total    => 24,
            files    => [{name => 'tidy', filename => 'lib/tidy.c', package => 2}]
          },
          {
            hash             => 'abc123',
            licenses         => ['GPL-3.0-only'],
            risk             => 6,
            aligned          => 20,
            total            => 24,
            declared_license => 'GPL-3.0-or-later',
            files            => [{name => 'curl', filename => 'lib/http.c', package => 1}]
          }
        ]
        };
    }
    else { push @results, {id => $q->{id}, total => 0, matches => []} }
  }
  $c->render(json => {results => \@results});
};

my $test = CavilCliTest->new(app);

subtest 'whole-tree scan reports clean, copied and skipped files' => sub {
  my $result = $test->run('--all', $dir->to_string);

  like $result->{stdout},   qr/3 files/,            'all three files checked';
  like $result->{stdout},   qr/2 with known code/,  'the known and novel files carry known code';
  like $result->{stdout},   qr/1 too small/,        'the tiny file is too small to fingerprint';
  like $result->{stdout},   qr/at or above risk 5/, 'headline flags the gate breach';
  like $result->{stdout},   qr/GPL-3\.0-only/,      'the higher-risk match is shown, not the fuller permissive one';
  like $result->{stdout},   qr/risk 6/,             'with its risk';
  like $result->{stdout},   qr/curl/,               'and the higher-risk match provenance, not tidy';
  unlike $result->{stdout}, qr/BSD-2-Clause|tidy/,  'the permissive decoy match is not what gets headlined';
  like $result->{stdout},   qr/identical to coreutils src\/ls\.c/, 'an exact match names the source it copies';
  is $result->{exit}, 1, 'the gate fails on the risk-6 finding';
};

subtest 'a license file is not scanned or flagged, just counted' => sub {
  my $result = $test->run('--all', $dir->to_string);
  like $result->{stdout},   qr/1 license file not scanned/, 'the COPYING file is skipped, and the skip is visible';
  unlike $result->{stdout}, qr/COPYING/,                    'it is not listed as a finding';
  like $result->{stdout},   qr/3 files/,                    'and it is not counted among the scanned files';

  # It was never hashed, so it never reached the recognition endpoint either.
  my %offered = map { $_ => 1 } map {@$_} @known_requests;
  ok !$offered{Cavil::Matcher::content_hash($dir->child('COPYING')->to_string)}, 'and never offered to the server';
};

subtest 'the CLI recognizes by hash first and only searches the residual' => sub {

  # Every file is hashed and offered to the recognition endpoint.
  my %offered = map { $_ => 1 } @{$known_requests[0]};
  ok $offered{$known_hash}, 'the known file hash was offered for recognition';
  is scalar @{$known_requests[0]}, 3, 'all three file hashes were offered in one batch';

  # Only the novel content reaches the search: the exact one is resolved by hash, the tiny one is below the
  # floor. Queries are keyed by content hash so identical files are searched once.
  my @ids = map { $_->{id} } map {@$_} @search_requests;
  is_deeply [sort @ids], [$novel_hash], 'only the residual novel content was searched';

  # Fingerprints travel as decimal strings, so the 64-bit values survive JSON.
  my ($query) = map {@$_} @search_requests;
  ok !ref $query->{fingerprints}[0], 'fingerprints are scalars';
  like $query->{fingerprints}[0], qr/^\d+$/, 'sent as decimal strings';
};

subtest 'hidden files are skipped by default but can be included' => sub {
  my $default = $test->run('--all', $dir->to_string);
  like $default->{stdout},   qr/1 hidden file not scanned/, 'the dotfile is skipped, and the skip is visible';
  unlike $default->{stdout}, qr/\.env/,                     'the dotfile itself is not listed by default';
  like $default->{stdout},   qr/3 files/,                   'and it is not counted among the scanned files';

  my $all = $test->run('--all', '--hidden', $dir->to_string);
  like $all->{stdout},   qr/\.env/,                   '--hidden brings the dotfile into the scan';
  like $all->{stdout},   qr/4 files/,                 'and counts it';
  unlike $all->{stdout}, qr/hidden file not scanned/, 'with nothing left hidden';
};

subtest 'the risk threshold controls the gate' => sub {
  is $test->run('--all', $dir->to_string, '--fail-on-risk', 8)->{exit}, 0,
    'raising the threshold above the finding passes the gate';
  is $test->run('--all', $dir->to_string, '--fail-on-risk', 6)->{exit}, 1, 'the default threshold still fails';
};

subtest 'json output is machine readable' => sub {
  my $result = $test->run('--all', $dir->to_string, '--format', 'json');
  my $data   = decode_json($result->{stdout});
  is $data->{scope},                    'tree', 'scope reported';
  is $data->{summary}{counts}{exact},   1,      'exact counted';
  is $data->{summary}{counts}{partial}, 1,      'partial counted';
  is $data->{summary}{max_risk},        6,      'max risk reported';

  # The declared license rides through to the machine output even when a per-file license is also present.
  my ($novel) = grep { $_->{verdict} eq 'partial' } @{$data->{findings}};
  is $novel->{declared_license}, 'GPL-3.0-or-later', 'the carrier declared license is carried into json';
};

subtest '--exclude-path skips a fixture directory entirely, and counts it' => sub {
  my $tree = tempdir;
  $tree->child('keep.pl')->spew("sub real_code { my \$x = shift; return \$x * 2 + 1 }\n" x 4);
  $tree->child('fixtures')->make_path;
  $tree->child('fixtures/licenses.txt')->spew("GNU GENERAL PUBLIC LICENSE\n" . ("license text " x 40) . "\n");

  my $result = $test->run('--all', '--exclude-path', 'fixtures', $tree->to_string);
  like $result->{stdout},   qr/1 file excluded \(--exclude-path\)/, 'the fixture file is excluded and counted';
  unlike $result->{stdout}, qr{fixtures/licenses\.txt},             'and never listed as a finding';
  like $result->{stdout},   qr/  1 files /,                         'only the one non-excluded file is checked';
};

# Last, since a fresh exclude set uses its own cache namespace and so issues new requests.
subtest '--exclude-package is sent to the server so a working copy can ignore its own package' => sub {
  @known_excludes = ();
  $test->run('--all', '--exclude-package', 'my-project', $dir->to_string);
  is_deeply $known_excludes[0], ['my-project'], 'the excluded package travels with the recognition request';
};

done_testing;
