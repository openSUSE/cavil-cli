# SPDX-FileCopyrightText: SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Mojo::Base -strict, -signatures;

use Test::More;
use Cavil::CLI::Scan;

# Mirrors Cavil::ReportUtil::is_license_filename; keep this guard so the client copy cannot silently drift.
subtest 'license documents are recognized, code is not' => sub {
  ok Cavil::CLI::Scan::_is_license_file($_), "$_ is a legal document" for qw(
    LICENSE LICENSE.txt LICENSE.md LICENCE COPYING COPYING.GPLv2 COPYRIGHT NOTICE
    EULA UNLICENSE THIRD-PARTY THIRD_PARTY.md src/vendor/COPYING
  );

  ok !Cavil::CLI::Scan::_is_license_file($_), "$_ is code, not a document" for qw(
    license.pl License.pm licensing.c copying.py notice.js main.rs README.md
    lib/License/Check.pm licensed_under.go
  );
};

subtest '--exclude-path matches directory prefixes and Text::Glob globs' => sub {
  my $c = sub ($p) { Cavil::CLI::Scan::_compile_excludes([$p]) };

  # A bare pattern (no glob characters) excludes that path and everything under it.
  ok Cavil::CLI::Scan::_excluded_path('t/fixtures/licenses/04.txt', $c->('t/fixtures')), 'directory prefix';
  ok Cavil::CLI::Scan::_excluded_path('t/fixtures',                 $c->('t/fixtures')), 'the path itself';
  ok !Cavil::CLI::Scan::_excluded_path('t/fixtures-extra/x',        $c->('t/fixtures')),
    'a sibling with a shared prefix is not under it';
  ok !Cavil::CLI::Scan::_excluded_path('src/main.rs', $c->('t/fixtures')), 'an unrelated path is kept';

  # Globs use Cavil's Text::Glob with strict_wildcard_slash off, so * crosses slashes and matches anywhere.
  ok Cavil::CLI::Scan::_excluded_path('a.pattern', $c->('*.pattern')), 'a top-level glob match';
  ok Cavil::CLI::Scan::_excluded_path('t/fixtures/licenses/a.pattern', $c->('*.pattern')),
    'and * crosses slashes (matches nested)';
  ok !Cavil::CLI::Scan::_excluded_path('a.txt',   $c->('*.pattern')), 'a non-matching extension is kept';
  ok Cavil::CLI::Scan::_excluded_path('log1.txt', $c->('log?.txt')),  '? matches one character';
};

subtest 'winnow rows dedup and span' => sub {
  my $raw = [[10, 1, 1], [20, 2, 2], [10, 3, 3], [30, 4, 6]];    # 10 repeats; last row spans two lines

  my ($fps, $span) = Cavil::CLI::Scan::_winnow_rows($raw);
  is_deeply $fps, [10, 20, 30], 'distinct fingerprints in first-seen order';
  is $span, 6, 'span covers the whole region (line 1 to 6)';
};

done_testing;
