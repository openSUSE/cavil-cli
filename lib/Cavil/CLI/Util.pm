# SPDX-FileCopyrightText: SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package Cavil::CLI::Util;
use Mojo::Base -strict, -signatures;

use Exporter        qw(import);
use Mojo::JSON      qw(to_json);
use Mojo::URL       ();
use Term::ANSIColor ();

our @EXPORT_OK = qw(parse_diff summarize gate render_text render_json);

# Cavil's authoritative risk scale (see the cavil-review-note skill): only 1-2 are truly safe, 3-4 carry
# copyleft obligations but are acceptable, escalation begins at 5, and 6-7 are reject-lean. Shown next to the
# number so a bare "risk 4" is not left to interpretation.
my %RISK_LABEL = (
  1 => 'public domain',
  2 => 'permissive',
  3 => 'weak copyleft',
  4 => 'strong copyleft',
  5 => 'managed obligations',
  6 => 'restrictive obligations',
  7 => 'non-commercial',
  9 => 'unknown license'
);

# The report is a per-file checklist in human states, not the engine's exact/partial/unknown vocabulary. "Known
# code" is any code Cavil recognizes and its license, open source or commercial:
#   clean   - no known code found; the user's own code (the reassuring green tick)
#   safe    - known code, but only permissive/public-domain (risk <= 2); no obligations to speak of
#   note    - known code with obligations (risk 3 up to the gate); acceptable, but worth knowing
#   problem - known code at or above the gate; this is what needs action (the only red)
#   skipped - not scanned (too short, or too large, to fingerprint); the per-file reason says which
# A wall of green ticks is deliberate: it shows every file was looked at. Colour tracks the risk scale above.
my %STATUS_GLYPH
  = (clean => "\x{2713}", safe => "\x{2022}", note => "\x{2022}", problem => "\x{2717}", skipped => "\x{00b7}");
my %STATUS_COLOR = (clean   => 'green', safe => undef, note => 'yellow', problem => 'red', skipped => 'bright_black');
my %STATUS_RANK  = (problem => 0,       note => 1,     safe => 2,        clean   => 3,     skipped => 4);

sub _status ($f, $threshold) {
  return 'skipped' if $f->{verdict} eq 'skipped';
  return 'clean'   if $f->{verdict} eq 'unknown';

  # A match is recognized code, so it is always shown. Only permissive/public-domain (risk <= 2) is truly safe;
  # a match whose license we could not determine is not safe either (it could be anything), so it lands in note.
  my $risk = $f->{risk};
  return 'problem' if defined $risk && $risk >= $threshold;
  return 'safe'    if defined $risk && $risk <= 2;
  return 'note';
}

# Parse a `git diff --unified=0` into the added regions: one per hunk, with the file, its first added line, and
# the added text. Removed and context lines are ignored; this is the new code a check looks at.
sub parse_diff ($diff) {
  my @regions;
  my ($file, $start, @lines);

  my $flush = sub {
    push @regions, {file => $file, start => $start, end => $start + $#lines, text => join("\n", @lines) . "\n"}
      if defined $file && @lines;
    @lines = ();
  };

  for my $line (split /\n/, $diff) {
    if ($line =~ m!^\+\+\+ (?:b/)?(.*)$!)                 { $flush->(); $file = $1 eq '/dev/null' ? undef : $1; next; }
    if ($line =~ /^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@/) { $flush->(); $start = $1;                            next; }
    if ($line =~ /^\+(.*)$/) { push @lines, $1; next; }
    $flush->();    # any other line ends the current added run
  }
  $flush->();

  return \@regions;
}

# Roll findings up into counts by verdict, a license distribution, and the highest risk seen.
sub summarize ($findings) {
  my (%counts, %licenses, $max_risk);
  for my $f (@$findings) {
    $counts{$f->{verdict}}++;
    $licenses{$_}++ for @{$f->{licenses} || []};
    $max_risk = $f->{risk} if defined $f->{risk} && (!defined $max_risk || $f->{risk} > $max_risk);
  }
  return {counts => \%counts, licenses => \%licenses, max_risk => $max_risk, total => scalar @$findings};
}

# Decide the CI gate: fail on any finding at or above the risk threshold, and (when asked) on any unknown.
sub gate ($findings, $opts) {
  my @risky   = grep { defined $_->{risk} && $_->{risk} >= $opts->{fail_on_risk} } @$findings;
  my @unknown = $opts->{fail_on_unknown} ? (grep { $_->{verdict} eq 'unknown' } @$findings) : ();
  return {failed => (@risky || @unknown) ? 1 : 0, risky => \@risky, unknown => \@unknown};
}

sub _paint ($on, $color, $text) { return $on && $color ? Term::ANSIColor::colored($text, $color) : $text }

# The packaging-declared license is only a useful hint when it is short: a single license or a simple OR/AND
# choice. Production has declared licenses with 20+ SPDX identifiers (whole license catalogs) that say nothing
# about the file, so above this many identifiers we drop it. Returns the expression if short, else undef.
use constant DECLARED_LICENSE_MAX => 3;

sub _short_declared ($expr) {
  return undef unless defined $expr && length $expr;
  my @ids = grep { length && !/\A(?:OR|AND|WITH)\z/i } split /[()\s]+/, $expr;
  return @ids >= 1 && @ids <= DECLARED_LICENSE_MAX ? $expr : undef;
}

# The machine format: a flat summary plus every finding, for a CI step to police or store.
sub render_json ($report) {
  my $s = summarize($report->{findings});
  return to_json(
    {
      scope   => $report->{scope},
      target  => $report->{target},
      summary => {
        checked  => $report->{checked},
        counts   => $s->{counts},
        licenses => $s->{licenses},
        max_risk => $s->{max_risk},

        # Skipped-by-policy counts, so a machine sees the coverage the text footer states.
        skipped => {map { $_ => $report->{$_} // 0 } qw(hidden licensedoc excluded)}
      },
      findings => $report->{findings}
    }
  ) . "\n";
}

# The human format: a gate verdict, a one-line tally, then a per-file checklist. Every file is shown (capped
# for very large trees), problems first so they are never truncated away, then the reassuring wall of green.
sub render_text ($report, %opts) {
  my $color     = $opts{color};
  my $findings  = $report->{findings};
  my $threshold = $opts{fail_on_risk} // 4;
  my $limit     = $opts{limit}        // 100;

  # Nothing was checked (an explicit diff with no changes, or an empty tree): say so plainly rather than
  # claim "all clear", which would imply we looked and found nothing.
  if (!@$findings) {
    my $hint = $report->{scope} eq 'diff' ? ' (no changes; use --all to scan the whole tree)' : '';
    return _paint($opts{color}, 'green', "\x{2713} nothing to check") . "$hint\n";
  }

  my %count;
  $count{_status($_, $threshold)}++ for @$findings;
  my $matched = ($count{safe} // 0) + ($count{note} // 0) + ($count{problem} // 0);

  # A diff answers "what known code did this change introduce"; a tree answers "what known code is in here".
  # Frame the headline for that question, staying license-neutral ("known code" covers commercial, not just OSS).
  my $diff = $report->{scope} eq 'diff';
  my $unit = $diff ? 'region' : 'file';

  # Headline verdict, tied to the gate.
  my $headline = $count{problem}
    ? _paint(
    $color, 'red',
    sprintf(
      "\x{2717} %d %s at or above risk %d",
      $count{problem}, ($count{problem} == 1 ? $unit : "${unit}s"), $threshold
    )
    )
    : $matched ? _paint(
    $color,
    'green',
    $diff
    ? "\x{2713} new known code introduced, nothing at or above risk $threshold"
    : "\x{2713} known code found, nothing at or above risk $threshold"
    )
    : _paint($color, 'green',
    $diff ? "\x{2713} all clear, no new known code introduced" : "\x{2713} all clear, no known code found");
  my $out = "$headline\n";

  # One plain-language tally.
  my $scope = $diff ? 'changed regions' : 'files';
  $out .= sprintf "  %d %s \x{b7} %d clean \x{b7} %d with known code \x{b7} %d skipped\n\n", $report->{checked},
    $scope, ($count{clean} // 0), $matched, ($count{skipped} // 0);

  # The checklist, problems first (so a cap never hides them), then clean files, then skipped; path order within.
  my @ordered = sort {
    $STATUS_RANK{_status($a, $threshold)} <=> $STATUS_RANK{_status($b, $threshold)} || $a->{location} cmp $b->{location}
  } @$findings;

  my $shown = @ordered > $limit ? $limit : scalar @ordered;
  for my $f (@ordered[0 .. $shown - 1]) {
    my $status = _status($f, $threshold);
    my @cols   = (_paint($color, $STATUS_COLOR{$status}, $STATUS_GLYPH{$status}), $f->{location});

    if ($status eq 'safe' || $status eq 'note' || $status eq 'problem') {

      # No per-file license detected: fall back to the carrier's declared license when it is short enough to be a
      # useful hint (a single license or a simple OR/AND). It carries no risk of its own, so this stays a note.
      my $declared = _short_declared($f->{declared_license});
      my $desc
        = defined $f->{risk}
        ? sprintf('%s  risk %d (%s)', join(',', @{$f->{licenses}}), $f->{risk},
        $RISK_LABEL{$f->{risk}} // 'unclassified')
        : defined $declared ? "declared $declared"
        :                     'license unknown';
      my $from = $f->{match} ? "$f->{match}{name} $f->{match}{filename}" : 'a known source';
      my $prov
        = $f->{verdict} eq 'partial' && $f->{total}
        ? sprintf('modified %d%% of %s', int(100 * $f->{aligned} / $f->{total} + 0.5), $from)
        : "identical to $from";
      push @cols, _paint($color, $STATUS_COLOR{$status}, $desc), $prov;
    }
    elsif ($status eq 'skipped') { push @cols, $f->{reason} // 'skipped' }

    $out .= '  ' . join('  ', grep {length} @cols) . "\n";
  }
  my $more = @ordered - $shown;
  $out .= "  ...and $more more ${unit}s (use --format json)\n" if $more > 0;

  # Skipped-by-policy counts, kept visible so "all clear" never hides files we chose not to look at.
  my @notes;
  push @notes,
    ($report->{hidden} == 1 ? '1 hidden file' : "$report->{hidden} hidden files")
    . ' not scanned (--hidden to include)'
    if $report->{hidden};
  push @notes,
    ($report->{licensedoc} == 1 ? '1 license file' : "$report->{licensedoc} license files")
    . ' not scanned (a copy of a licence is not a finding)'
    if $report->{licensedoc};
  push @notes, ($report->{excluded} == 1 ? '1 file' : "$report->{excluded} files") . ' excluded (--exclude-path)'
    if $report->{excluded};
  $out .= "\n" . join('', map {"  $_\n"} @notes) if @notes;

  return $out;
}

1;
