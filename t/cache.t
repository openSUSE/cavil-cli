# SPDX-FileCopyrightText: SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Mojo::Base -strict, -signatures;

use Test::More;
use Cavil::CLI::Cache;
use Mojo::File qw(tempdir);

my $dir = tempdir;

sub cache ($generation = 1, $url = 'https://legaldb.suse.de') {
  return Cavil::CLI::Cache->new(url => $url, dir => $dir)->load->for_generation($generation);
}

subtest 'recognition round-trips and persists across instances' => sub {
  my $c = cache();
  $c->store_known(
    {
      abc => {licenses => ['MIT'], risk => 2, package => 'coreutils', filename => 'src/ls.c'},
      def => {licenses => [], risk => undef}
    }
  );

  is_deeply $c->known(['abc', 'missing']),
    {abc => {licenses => ['MIT'], risk => 2, package => 'coreutils', filename => 'src/ls.c'}},
    'a stored hash comes back with its provenance, an unknown one is absent';
  is_deeply $c->known(['def'])->{def}, {licenses => [], risk => undef}, 'a known-but-unlicensed hash round-trips';

  is_deeply cache()->known(['abc'])->{abc},
    {licenses => ['MIT'], risk => 2, package => 'coreutils', filename => 'src/ls.c'},
    'and survives reopening the database';
};

subtest 'search results are generation-tagged' => sub {
  my $c = cache(1);
  $c->store_search({xyz => {verdict => 'partial', licenses => ['GPL-2.0-only'], risk => 4}});
  ok $c->search(['xyz'])->{xyz}, 'cached at the current generation';

  ok cache(1)->search(['xyz'])->{xyz},  'kept when the generation is unchanged';
  ok !cache(2)->search(['xyz'])->{xyz}, 'dropped once the index generation moves on';
};

subtest 'recognition is kept across a generation change' => sub {
  cache(1)->store_known({keep => {licenses => ['Apache-2.0'], risk => 2}});
  ok exists cache(9)->known(['keep'])->{keep}, 'immutable recognition is never invalidated';
};

subtest 'each instance host has its own database' => sub {
  cache(1, 'https://one.example')->store_known({h => {licenses => ['MIT'], risk => 2}});
  is_deeply cache(1, 'https://two.example')->known(['h']), {}, 'a different server does not see it';
};

subtest 'each self-exclude set has its own database' => sub {
  my $with = sub ($exclude) {
    Cavil::CLI::Cache->new(url => 'https://legaldb.suse.de', dir => $dir, exclude => $exclude)->load->for_generation(1);
  };

  # A result depends on which packages are excluded, so a run that excludes "foo" must not read a plain run's rows.
  $with->(['foo'])->store_known({x => {licenses => ['MIT'], risk => 2}});
  is_deeply $with->([])->known(['x']),      {}, 'the plain (no-exclude) cache does not see an excluded run';
  is_deeply $with->(['bar'])->known(['x']), {}, 'a different exclude set does not see it either';
  ok $with->(['foo'])->known(['x'])->{x},        'but the same exclude set does (order-independent)';
  ok $with->(['foo', 'foo'])->known(['x'])->{x}, 'and duplicates in the set do not change the identity';
};

subtest 'reads a hash set larger than one IN chunk' => sub {
  my $c      = cache(1);
  my @hashes = map {"h$_"} 1 .. 1200;
  $c->store_known({map { $_ => {licenses => [], risk => 1} } @hashes});
  is scalar keys %{$c->known(\@hashes)}, 1200, 'all rows return across chunked IN queries';
};

subtest 'empty writes are a no-op' => sub {
  my $c = cache();
  is $c->store_known({}),  $c, 'store_known returns self and writes nothing';
  is $c->store_search({}), $c, 'store_search returns self and writes nothing';
};

done_testing;
