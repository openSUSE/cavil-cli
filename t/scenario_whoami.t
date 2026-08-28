# SPDX-FileCopyrightText: SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Mojo::Base -strict, -signatures;

use FindBin;
use lib "$FindBin::Bin/lib";

use Test::More;
use CavilCliTest;
use Mojo::JSON qw(decode_json);
use Mojolicious::Lite;

app->log->level('error');

# A mock whoami that answers only with a valid Bearer token, so the test also proves the header is sent.
my @auth;
get '/api/v1/whoami' => sub ($c) {
  push @auth, $c->req->headers->authorization;
  return $c->render(json => {error => 'Unauthorized'}, status => 403)
    unless ($c->req->headers->authorization // '') eq 'Bearer test-token';
  $c->render(json => {id => 23, user => 'tester', roles => ['admin', 'classifier'], write_access => \0});
};

my $test = CavilCliTest->new(app);

subtest 'whoami reports the identity, roles and round-trip time' => sub {
  my $result = $test->run_command('whoami');
  is $result->{exit}, 0, 'a working login exits cleanly';
  like $result->{stdout}, qr/Authenticated as tester \(id 23\)/, 'names the user and id';
  like $result->{stdout}, qr/roles: admin, classifier/,          'lists the roles';
  like $result->{stdout}, qr/write access: no/,                  'shows write access';
  like $result->{stdout}, qr/round-trip: \d+ ms/,                'and the round-trip time';
  is $auth[0], 'Bearer test-token', 'the Bearer token was sent';
};

subtest 'whoami json is machine readable for CI' => sub {
  my $result = $test->run_command('whoami', '--format', 'json');
  my $data   = decode_json($result->{stdout});
  is $data->{user},         'tester', 'user present';
  is $data->{write_access}, 0,        'write access present';
  ok exists $data->{round_trip_ms}, 'round-trip time is included';
};

subtest 'a bad token fails clearly and non-zero' => sub {

  # Point at the mock but with a token it rejects, by overriding on the CLI's own args.
  my $result = $test->run_command('whoami', '--token', 'wrong');
  isnt $result->{exit}, 0, 'a rejected login is non-zero';
  like $result->{stderr}, qr/Not authenticated/, 'says authentication failed';
  like $result->{stderr}, qr/CAVIL_API_KEY/,     'and points at what to check';
};

subtest 'config saves credentials and later commands use them without any flags' => sub {

  # --url is fine on the command line; the token is read from stdin (never a flag), here by piping it in.
  my $save = $test->run_bare(['config', '--url', $test->url], "test-token\n");
  is $save->{exit}, 0, 'saving succeeds';
  like $save->{stdout},   qr/Saved configuration/, 'it confirms the save';
  unlike $save->{stdout}, qr/test-token/,          'and never echoes the token';

  # --show reveals the URL but masks the token.
  my $show = $test->run_bare(['config', '--show']);
  like $show->{stdout},   qr{url:\s+\Q@{[$test->url]}\E}, 'show lists the url';
  like $show->{stdout},   qr/token:\s+\*+ \(set\)/,       'show masks the token';
  unlike $show->{stdout}, qr/test-token/,                 'the real token is never printed';

  # whoami with no flags and nothing in the environment now works, from the saved config alone.
  local $ENV{CAVIL_URL}     = undef;
  local $ENV{CAVIL_API_KEY} = undef;
  my $who = $test->run_bare(['whoami']);
  is $who->{exit}, 0, 'the saved credentials authenticate';
  like $who->{stdout}, qr/Authenticated as tester/, 'and identify the user';
};

done_testing;
