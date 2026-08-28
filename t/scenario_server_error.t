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

# The mock's configuration endpoint returns whatever status the test asks for, so one file can exercise both
# a plain server error and the "code search disabled" case.
my $config_status = 200;
get '/api/v1/code/config' => sub ($c) {
  return $c->render(json => {error => 'nope'}, status => $config_status) if $config_status != 200;
  $c->render(json => {k => 4, w => 8});
};
post '/api/v1/code/known'        => {json => {}};
post '/api/v1/code/search-batch' => {json => {results => []}};

my $dir = tempdir;
$dir->child('file.txt')->spew("some content\n");

my $test = CavilCliTest->new(app);

subtest 'a server error exits with the server code and explains itself' => sub {
  $config_status = 500;
  my $result = $test->run('--all', $dir->to_string);
  is $result->{exit}, 3, 'server error exit code';
  like $result->{stderr}, qr/response from Cavil/, 'the error names Cavil';
};

subtest 'a disabled instance is reported clearly' => sub {
  $config_status = 404;
  my $result = $test->run('--all', $dir->to_string);
  is $result->{exit}, 2, 'usage-style exit code';
  like $result->{stderr}, qr/not enabled/, 'the message says code search is off';
};

done_testing;
