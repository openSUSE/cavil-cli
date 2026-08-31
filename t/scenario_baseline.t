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

# A project that legitimately carries a copy: the author reused a test file from their own other project. It is
# a permissive match below the gate, so it never fails a build - it just sits in every report forever, which is
# what a baseline is for.
my $dir = tempdir;
$dir->child('t')->make_path->child('pod.t')->spew("use Test::Pod;\nall_pod_files_ok();\n");
$dir->child('mine.pl')->spew("sub mine { return 'entirely my own work and quite verbose about it' }\n");

my $copied = Cavil::Matcher::content_hash($dir->child('t/pod.t')->to_string);

# The server recognizes the copied file; risk is swapped mid-test to prove an escalation is never suppressed.
# Raising it goes with a new index generation, which is how it happens for real: Cavil indexes more, learns the
# same content under a worse license, and bumps the generation the client caches recognitions against.
my $risk       = 2;
my $generation = 1;
get '/api/v1/code/config' => sub ($c) { $c->render(json => {k => 4, w => 8, generation => $generation}) };
post '/api/v1/code/known' => sub ($c) {
  $c->render(json =>
      {$copied => {licenses => ['Artistic-2.0'], risk => $risk, package => 'perl-Mojolicious', filename => 't/pod.t'}});
};
post '/api/v1/code/search-batch' => sub ($c) {
  $c->render(json => {results => [map { {id => $_->{id}, total => 0, matches => []} } @{$c->req->json->{queries}}]});
};

my $test     = CavilCliTest->new(app);
my $baseline = $dir->child('.cavil-baseline.json');

subtest 'before a baseline, the accepted copy is reported like any other match' => sub {
  my $result = $test->run('--all', $dir->to_string);
  like $result->{stdout}, qr{t/pod\.t},          'the copied file is listed';
  like $result->{stdout}, qr/1 with known code/, 'and counted as known code';
  ok !-f $baseline, 'no baseline file exists yet';
};

subtest 'recording a baseline writes the accepted matches' => sub {
  my $result = $test->run_command('baseline', $dir->to_string);
  is $result->{exit}, 0, 'the command succeeds';
  like $result->{stdout}, qr/Wrote 1 accepted match/, 'reporting what it recorded';
  ok -f $baseline, 'the file is written next to the project, not the working directory';

  my $data = decode_json($baseline->slurp);
  is $data->{version},                 1,         'carries a format version';
  is scalar @{$data->{accepted}},      1,         'one entry';
  is $data->{accepted}[0]{file},       't/pod.t', 'keyed by path';
  is $data->{accepted}[0]{content},    $copied,   'pinned to the local content';
  is $data->{accepted}[0]{match_hash}, $copied,   'and to what it matched';
  is $data->{accepted}[0]{risk},       2,         'recording the risk that was accepted';
  like $data->{accepted}[0]{note}, qr/identical to perl-Mojolicious t\/pod\.t/,
    'with a note that reads in review like the report line it came from';

  # Committed, so it has to be reproducible: regenerating an unchanged project must not churn the file.
  my $first = $baseline->slurp;
  $test->run_command('baseline', $dir->to_string);
  is $baseline->slurp, $first, 'regenerating an unchanged project rewrites it byte for byte';
};

subtest 'a later check reports only what is not accepted' => sub {
  my $result = $test->run('--all', $dir->to_string);
  is $result->{exit}, 0, 'still passes';
  unlike $result->{stdout}, qr{t/pod\.t}, 'the accepted copy is no longer in the checklist';
  like $result->{stdout}, qr/all clear, nothing new/,
    'and the headline says nothing new, not "no known code found" (which would be untrue)';
  like $result->{stdout}, qr/1 accepted/, 'but it is counted, so the tally still adds up';
  like $result->{stdout}, qr/1 match already accepted in .*\.cavil-baseline\.json/,
    'and the footer names the file the decision lives in';

  like $test->run('--all', $dir->to_string, '--no-baseline')->{stdout}, qr{t/pod\.t},
    '--no-baseline reports everything again';
};

subtest 'a baseline never hides an escalation' => sub {

  # Same file, same match, but Cavil now knows it under a riskier license than the one that was accepted. This
  # is the case a baseline must not swallow: the corpus grows, so what a file matches can get worse over time.
  $risk = 6;
  $generation++;
  my $result = $test->run('--all', $dir->to_string);
  like $result->{stdout}, qr{t/pod\.t}, 'the finding comes back';
  like $result->{stdout}, qr/risk 6/,   'at its new risk';
  is $result->{exit}, 1, 'and it fails the gate despite being in the baseline';

  $risk = 2;
};

subtest 'a baseline stops applying once the file changes' => sub {
  $dir->child('t/pod.t')->spew("use Test::Pod;\nall_pod_files_ok();\n# and something of my own\n");
  my $changed = Cavil::Matcher::content_hash($dir->child('t/pod.t')->to_string);
  isnt $changed, $copied, 'the local content hash changed';

  my $result = $test->run('--all', $dir->to_string);
  like $result->{stdout},   qr/0 accepted|clean/, 'the entry no longer matches the file it was recorded for';
  unlike $result->{stdout}, qr/1 accepted/,       'so nothing is suppressed on its behalf';
};

done_testing;
