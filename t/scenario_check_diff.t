# SPDX-FileCopyrightText: SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Mojo::Base -strict, -signatures;

use FindBin;
use lib "$FindBin::Bin/lib";

use Test::More;
use CavilCliTest;
use File::Spec ();
use Mojo::File qw(tempdir);
use Mojolicious::Lite;

plan skip_all => 'git is required for this test' unless _have_git();

app->log->level('error');

# A repository with a base commit on the default branch and a feature branch that adds a file. Checked without
# --all, the CLI diffs against the branch point and looks only at the added code.
my $repo = tempdir;
my @git  = (
  'git', '-C', $repo->to_string, '-c', 'user.email=t@example.com', '-c',
  'user.name=Tester', '-c', 'commit.gpgsign=false'
);

_git('init', '-q', '-b', 'main');
$repo->child('base.pl')->spew("package Base;\n1;\n");
_git('add',      '.');
_git('commit',   '-q', '-m', 'base');
_git('checkout', '-q', '-b', 'feature');
$repo->child('added.pl')->spew(<<'CODE');
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
_git('add', '.');
_git('commit', '-q', '-m', 'feature');

my @search_requests;
get '/api/v1/code/config' => {json => {k => 4, w => 8}};
post '/api/v1/code/known' => {json => {}};
post '/api/v1/code/search-batch' => sub ($c) {
  my $queries = $c->req->json->{queries};
  push @search_requests, $queries;
  my @results = map {
    {
      id      => $_->{id},
      total   => 12,
      matches => [
        {
          hash     => 'deadbeef',
          licenses => ['Apache-2.0'],
          risk     => 3,
          aligned  => 11,
          total    => 12,
          files    => [{name => 'coolproject', filename => 'lib/util.pl', package => 7}]
        }
      ]
    }
  } @$queries;
  $c->render(json => {results => \@results});
};

my $test = CavilCliTest->new(app);

subtest 'a change set is checked against a given base (--since forces a diff)' => sub {
  my $result = $test->run('--since', 'main', $repo->to_string);

  like $result->{stdout}, qr/changed regions/, 'diff scope is reported';
  like $result->{stdout}, qr/modified/,        'the added code is a modified copy';
  like $result->{stdout}, qr/Apache-2\.0/,     'with its license';
  like $result->{stdout}, qr/coolproject/,     'and its provenance';
  is $result->{exit}, 0, 'risk 3 is below the default gate';

  # Only the added file was searched; the unchanged base file was not.
  my @ids = map { $_->{id} } map {@$_} @search_requests;
  ok + (grep {/^added\.pl:/} @ids), 'the added file region was searched';
  ok !(grep {/^base\.pl:/} @ids),   'the unchanged base file was not';
};

subtest 'a bare path scans the whole tree, not the diff' => sub {
  my $result = $test->run($repo->to_string);
  like $result->{stdout},   qr/\d+ files/,       'a path is a whole-tree scan';
  unlike $result->{stdout}, qr/changed regions/, 'not a diff';
};

subtest 'diff scope skips hidden, license and excluded files, counting each' => sub {
  $repo->child('.secret')->spew("TOKEN=1\n");
  $repo->child('LICENSE')->spew("MIT License\n" . ("permission is granted " x 20) . "\n");
  $repo->child('t/fixtures')->make_path;
  $repo->child('t/fixtures/vendored.pl')->spew("sub helper { my \$n = shift; return \$n + 1 }\n" x 4);
  _git('add', '.');
  _git('commit', '-q', '-m', 'more');

  @search_requests = ();
  my $result = $test->run('--since', 'main', '--exclude-path', 't/fixtures', $repo->to_string);
  like $result->{stdout}, qr/1 hidden file not scanned/,  'the dotfile is skipped and counted';
  like $result->{stdout}, qr/1 license file not scanned/, 'the LICENSE is skipped and counted';
  like $result->{stdout}, qr/1 file excluded/,            'the fixture path is excluded and counted';

  my @ids = map { $_->{id} } map {@$_} @search_requests;
  ok !(grep {m{^(?:\.secret|LICENSE|t/fixtures/)}} @ids), 'none of the skipped files were searched';
};

sub _have_git { return _git_quiet('--version') }

sub _git { _git_quiet(@_) or die "git @_ failed\n" }

sub _git_quiet (@args) {
  open my $so, '>&', \*STDOUT;
  open my $se, '>&', \*STDERR;
  open STDOUT, '>',  File::Spec->devnull;
  open STDERR, '>',  File::Spec->devnull;
  my $rc = @args && $args[0] eq '--version' ? system('git', '--version') : system(@git, @args);
  open STDOUT, '>&', $so;
  open STDERR, '>&', $se;
  return $rc == 0;
}

done_testing;
