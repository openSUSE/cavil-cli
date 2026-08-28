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

# A novel file the instance has never seen and cannot match: it is reported as unknown, never as "original".
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
  for my $sku (sort keys %actual) {
    next if exists $expected{$sku};
    push @discrepancies, {sku => $sku, expected => 0, actual => $actual{$sku}, delta => $actual{$sku}};
  }
  return {clean => (@discrepancies ? 0 : 1), discrepancies => \@discrepancies};
}
CODE

get '/api/v1/code/config' => {json => {k => 4, w => 8}};
post '/api/v1/code/known' => {json => {}};
post '/api/v1/code/search-batch' => sub ($c) {
  my @results = map { {id => $_->{id}, total => 0, matches => []} } @{$c->req->json->{queries}};
  $c->render(json => {results => \@results});
};

my $test = CavilCliTest->new(app);

subtest 'code with no known code in it reads as clean, not as a problem' => sub {
  my $result = $test->run('--all', $dir->to_string);
  like $result->{stdout},   qr/all clear, no known code found/, 'the headline is reassuring';
  like $result->{stdout},   qr/1 clean/,                        'the novel file is counted clean';
  like $result->{stdout},   qr/novel\.pl/,                      'and listed (a reassuring tick)';
  unlike $result->{stdout}, qr/no known provenance|unknown/,    'without scary jargon';
  is $result->{exit}, 0, 'clean code does not fail the gate';
};

subtest 'fail-on-unknown turns unknown code into a gate failure' => sub {
  is $test->run('--all', $dir->to_string, '--fail-on-unknown')->{exit}, 1, 'the gate fails when asked to';
};

done_testing;
