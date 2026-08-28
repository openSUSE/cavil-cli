# SPDX-FileCopyrightText: SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Mojo::Base -strict, -signatures;

use Test::More;
use Mojo::JSON       qw(from_json);
use Cavil::CLI::Util qw(parse_diff summarize gate render_text render_json);

subtest 'parse_diff extracts added regions' => sub {
  my $diff = <<'DIFF';
diff --git a/src/foo.c b/src/foo.c
--- a/src/foo.c
+++ b/src/foo.c
@@ -0,0 +1,3 @@
+int a;
+int b;
+int c;
diff --git a/README b/README
--- a/README
+++ b/README
@@ -5,0 +6,1 @@
+a new line
DIFF

  my $regions = parse_diff($diff);
  is scalar @$regions,     2,           'two regions';
  is $regions->[0]{file},  'src/foo.c', 'first region file';
  is $regions->[0]{start}, 1,           'first region start line';
  is $regions->[0]{end},   3,           'first region end line';
  like $regions->[0]{text}, qr/int a;\nint b;\nint c;/, 'first region added text';
  is $regions->[1]{file},  'README', 'second region file';
  is $regions->[1]{start}, 6,        'second region start line';
};

subtest 'parse_diff ignores deletions and new-file markers' => sub {
  my $diff = <<'DIFF';
--- a/gone.c
+++ /dev/null
@@ -1,2 +0,0 @@
-int removed;
-int also_removed;
DIFF
  is_deeply parse_diff($diff), [], 'a pure deletion yields no regions';
};

my @findings = (
  {location => 'safe.c', verdict => 'exact', licenses => ['MIT'], risk => 2},
  {
    location => 'gpl.c',
    verdict  => 'partial',
    licenses => ['GPL-3.0-only'],
    risk     => 4,
    aligned  => 20,
    total    => 24,
    match    => {name => 'somelib', filename => 'x.c'}
  },
  {location => 'sspl.c', verdict => 'exact', licenses => ['SSPL-1.0'], risk => 6},
  {
    location => 'mystery.cfg',
    verdict  => 'partial',
    licenses => [],
    aligned  => 9,
    total    => 11,
    match    => {name => 'otherlib', filename => 'y.cfg'}
  },
  {location => 'mine.c',   verdict => 'unknown', licenses => []},
  {location => 'logo.png', verdict => 'skipped', licenses => []}
);

subtest 'summarize rolls up counts, licenses and max risk' => sub {
  my $s = summarize(\@findings);
  is $s->{counts}{exact},            2, 'two exact';
  is $s->{counts}{partial},          2, 'two partial';
  is $s->{counts}{unknown},          1, 'one unknown';
  is $s->{counts}{skipped},          1, 'one skipped';
  is $s->{max_risk},                 6, 'highest risk is 6';
  is $s->{licenses}{'GPL-3.0-only'}, 1, 'license counted';
};

subtest 'gate fails on the risk threshold, not on mere matches' => sub {
  ok gate(\@findings,  {fail_on_risk => 5})->{failed}, 'the risk-6 finding trips the default gate';
  ok !gate(\@findings, {fail_on_risk => 7})->{failed}, 'raising the threshold to 7 passes';
  ok gate(\@findings,  {fail_on_risk => 3})->{failed}, 'a stricter gate also trips on the GPL note';
  ok gate(\@findings,  {fail_on_risk => 9, fail_on_unknown => 1})->{failed},
    'and fail-on-unknown trips on the clean file';
};

subtest 'render_text grades findings by the Cavil risk scale' => sub {
  my $report
    = {scope => 'tree', target => '.', instance => 'https://legaldb.suse.de', checked => 6, findings => \@findings};
  my $text = render_text($report, color => 0, fail_on_risk => 5);
  like $text,   qr/at or above risk 5/,                             'headline names the gate breach';
  like $text,   qr/1 clean/,                                        'tally counts the clean file';
  like $text,   qr/4 with known code/,                              'tally counts every match, any risk';
  like $text,   qr/1 too small/,                                    'tally counts the too-small file';
  like $text,   qr/MIT\s+risk 2 \(permissive\)/,                    'permissive match labelled safe';
  like $text,   qr/GPL-3\.0-only\s+risk 4 \(strong copyleft\)/,     'copyleft match labelled with obligations';
  like $text,   qr/SSPL-1\.0\s+risk 6 \(restrictive obligations\)/, 'reject-lean match labelled';
  like $text,   qr/license unknown/,          'a match with no detected license reads as unknown, not blank';
  like $text,   qr/modified 82% of otherlib/, 'and still shows its provenance';
  like $text,   qr{mine\.c},                  'the clean file is listed (the reassuring tick)';
  unlike $text, qr/no license detected|no known provenance/, 'no clunky jargon';
};

subtest 'a short declared license is a fallback when no per-file license was detected' => sub {
  my $render = sub ($f) {
    render_text({scope => 'tree', target => '.', checked => 1, findings => [$f]}, color => 0, fail_on_risk => 5);
  };
  my $base = {
    location => 'x.c',
    verdict  => 'partial',
    licenses => [],
    aligned  => 9,
    total    => 11,
    match    => {name => 'somelib', filename => 'y.c'}
  };

  # No per-file license, but a short declared license: use it instead of "license unknown".
  like $render->({%$base, declared_license => 'MIT OR Apache-2.0'}), qr/declared MIT OR Apache-2\.0/,
    'a short declared license is shown as the fallback';
  unlike $render->({%$base, declared_license => 'MIT OR Apache-2.0'}), qr/license unknown/,
    'and replaces the unknown text';

  # A long declared license (a catalog) is useless as a hint, so it is dropped back to "license unknown".
  my $catalog = join(' OR ', map {"Lic-$_"} 1 .. 20);
  like $render->({%$base, declared_license => $catalog}), qr/license unknown/,
    'a 20-identifier declared license is dropped';
  unlike $render->({%$base, declared_license => $catalog}), qr/declared/, 'nothing declared is shown for it';

  # A real per-file license always wins; the declared license is only a fallback.
  my $withlic = {%$base, licenses => ['GPL-2.0-only'], risk => 4, declared_license => 'MIT'};
  like $render->($withlic),   qr/GPL-2\.0-only\s+risk 4/, 'the detected license is shown';
  unlike $render->($withlic), qr/declared/,               'the declared license is not used when one was detected';
};

subtest 'skipped-by-policy hidden, license and excluded files are surfaced, never silently dropped' => sub {
  my $report = {
    scope      => 'tree',
    target     => '.',
    checked    => 1,
    hidden     => 3,
    licensedoc => 2,
    excluded   => 5,
    findings   => [$findings[4]]
  };
  my $text = render_text($report, color => 0, fail_on_risk => 5);
  like $text, qr/3 hidden files not scanned \(--hidden to include\)/, 'the hidden count is shown with the override';
  like $text, qr/2 license files not scanned/,                        'the license-file count is shown too';
  like $text, qr/5 files excluded \(--exclude-path\)/,                'the excluded-path count is shown too';

  my $one = render_text(
    {scope => 'tree', target => '.', checked => 1, licensedoc => 1, excluded => 1, findings => [$findings[4]]},
    color        => 0,
    fail_on_risk => 5
  );
  like $one, qr/1 license file not scanned/, 'and reads singular for one license file';
  like $one, qr/1 file excluded/,            'and singular for one excluded file';
};

subtest 'a wholly clean run reads as all-clear and still lists every file' => sub {
  my $clean = [
    {location => 'README.md',   verdict => 'unknown', licenses => []},
    {location => 'src/main.rs', verdict => 'unknown', licenses => []}
  ];
  my $text
    = render_text({scope => 'tree', target => '.', checked => 2, findings => $clean}, color => 0, fail_on_risk => 6);
  like $text,   qr/all clear, no known code found/, 'positive headline';
  like $text,   qr/2 clean/,                        'both files counted clean';
  like $text,   qr/README\.md/,                     'clean files are listed';
  like $text,   qr{src/main\.rs},                   'as a reassuring checklist';
  unlike $text, qr/provenance|unknown/,             'no engine jargon';
};

subtest 'a diff report frames its verdict around new known code, not a whole-tree inventory' => sub {
  my $report = {scope => 'diff', target => '.', checked => 4, findings => \@findings};

  # Nothing at or above the gate: the diff headline speaks of what the change introduced.
  my $ok = render_text($report, color => 0, fail_on_risk => 7);
  like $ok, qr/new known code introduced, nothing at or above risk 7/, 'diff headline is about what is new';

  # A breach: the unit is a changed region, not a file.
  my $bad = render_text($report, color => 0, fail_on_risk => 5);
  like $bad, qr/\x{2717} 1 region at or above risk 5/, 'a single breach reads as one region, not one file';

  my $clean
    = render_text({scope => 'diff', target => '.', checked => 0, findings => []}, color => 0, fail_on_risk => 5);
  like $clean, qr/nothing to check/, 'an empty diff still says nothing to check';
};

subtest 'an empty check says nothing to check, not all clear' => sub {
  my $text = render_text({scope => 'diff', target => '.', checked => 0, findings => []}, color => 0, fail_on_risk => 5);
  like $text, qr/nothing to check/, 'an empty diff is stated plainly';
  like $text, qr/--all/,            'and points at the whole-tree option';
};

subtest 'render_json is machine readable' => sub {
  my $report = {scope => 'diff', target => '.', checked => 4, hidden => 2, licensedoc => 1, findings => \@findings};
  my $data   = from_json(render_json($report));
  is $data->{scope},                        'diff', 'scope preserved';
  is $data->{summary}{max_risk},            6,      'summary carries max risk';
  is scalar @{$data->{findings}},           6,      'all findings present';
  is $data->{summary}{skipped}{hidden},     2,      'skipped-by-policy counts are exposed to machines';
  is $data->{summary}{skipped}{licensedoc}, 1,      'including license files';
  is $data->{summary}{skipped}{excluded},   0,      'defaulting missing counts to zero';
};

done_testing;
