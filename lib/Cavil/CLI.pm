# SPDX-FileCopyrightText: SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package Cavil::CLI;
use Mojo::Base -base, -signatures;

use Cavil::CLI::Baseline;
use Cavil::CLI::Cache;
use Cavil::CLI::Client;
use Cavil::CLI::Config;
use Cavil::CLI::Progress;
use Cavil::CLI::Scan;
use Cavil::CLI::Util qw(gate render_json render_text);
use Mojo::File       qw(path);
use Mojo::JSON       qw(to_json);
use Mojo::Log;
use Mojo::Util  qw(encode extract_usage getopt);
use Time::HiRes ();

our $VERSION = '0.03';

has log    => sub { Mojo::Log->new };
has client => sub { Cavil::CLI::Client->new };

# Exit codes: clean, gate failed, usage/config problem, server/connection error.
use constant {EXIT_CLEAN => 0, EXIT_GATE => 1, EXIT_USAGE => 2, EXIT_SERVER => 3};

sub run ($self) {
  getopt
    'url=s'              => \my $url_opt,
    'all'                => \my $all,
    'since=s'            => \my $since,
    'staged'             => \my $staged,
    'fail-on-risk=i'     => \my $fail_on_risk,
    'fail-on-unknown'    => \my $fail_on_unknown,
    'baseline=s'         => \my $baseline,
    'no-baseline'        => \my $no_baseline,
    'exclude-package=s@' => \my $exclude_package,
    'exclude-path=s@'    => \my $exclude_path,
    'format=s'           => \my $format,
    'hidden'             => \my $hidden,
    'show'               => \my $show,
    'no-color'           => \my $no_color,
    'quiet'              => \my $quiet,
    'h|help'             => \my $help;

  return print(extract_usage) ? EXIT_CLEAN : EXIT_CLEAN if $help;

  my ($command, $path) = @ARGV;
  unless (defined $command
    && ($command eq 'check' || $command eq 'whoami' || $command eq 'config' || $command eq 'baseline'))
  {
    print STDERR extract_usage;
    return EXIT_USAGE;
  }

  my $config = Cavil::CLI::Config->new;

  # Saving settings needs no server, and is the only place a URL may be given: see below.
  return $self->_config($config, $url_opt, $show) if $command eq 'config';

  if (defined $url_opt) {
    print STDERR "--url only applies to 'cavil-cli config'; set CAVIL_URL (with CAVIL_API_KEY) to aim elsewhere\n";
    return EXIT_USAGE;
  }

  # Server and token are resolved together, from one source, and never mixed. Taking the URL from one place and
  # the token from another is how a token saved for one instance ends up being sent to a different one. For the
  # same reason there is no --token at all: an argument is world-readable in ps and stays in shell history.
  my ($url, $token)
    = defined $ENV{CAVIL_URL}
    || defined $ENV{CAVIL_API_KEY} ? ($ENV{CAVIL_URL}, $ENV{CAVIL_API_KEY}) : @{$config->load}{qw(url token)};
  unless (defined $url && defined $token) {
    print STDERR "A Cavil URL and API token are required, from the same source:\n"
      . "  run 'cavil-cli config' to save both, or set CAVIL_URL and CAVIL_API_KEY together\n";
    return EXIT_USAGE;
  }

  return $self->_whoami({url => $url, token => $token, format => $format // 'text'}) if $command eq 'whoami';

  # Packages to treat as "my own", so a working copy does not match its own indexed package. Flags and the env
  # var (comma or whitespace separated) combine, deduped; the set also namespaces the cache (see Cache).
  my %seen;
  my @exclude = grep { !$seen{$_}++ } @{$exclude_package // []}, grep {length} split /[\s,]+/,
    ($ENV{CAVIL_EXCLUDE_PACKAGES} // '');

  # Path globs/prefixes to skip entirely (test fixtures and the like); combined the same way. A trailing slash
  # is dropped so --exclude-path t/fixtures/ and t/fixtures behave alike.
  my %seen_path;
  my @exclude_paths = grep { !$seen_path{$_}++ } map {s{/\z}{}r} grep {length} @{$exclude_path // []}, split /[\s,]+/,
    ($ENV{CAVIL_EXCLUDE_PATHS} // '');

  $format //= 'text';
  my $color = $format eq 'text' && !$no_color && !$ENV{NO_COLOR} && -t STDOUT;

  # Live progress goes to STDERR, so it stays out of the report and any pipe; only shown on a real terminal.
  my $progress = !$quiet && -t STDERR ? 1 : 0;

  my %opts = (
    url              => $url,
    token            => $token,
    all              => $all,
    since            => $since,
    staged           => $staged,
    fail_on_risk     => $fail_on_risk // 4,
    fail_on_unknown  => $fail_on_unknown,
    format           => $format,
    color            => $color,
    progress         => $progress,
    hidden           => $hidden ? 1 : 0,
    exclude_packages => \@exclude,
    exclude_paths    => \@exclude_paths,
    baseline         => $baseline,
    no_baseline      => $no_baseline
  );

  # Recording a baseline is a whole-tree question ("what does this project already contain?"), so it always
  # scans the tree rather than the change set.
  return $self->_baseline($path, {%opts, all => 1}) if $command eq 'baseline';

  return $self->_check($path, \%opts);
}

# Save the Cavil URL and API token to the config file, or show what is stored. The token is read from a hidden
# prompt, or from stdin when piped; there is no option to pass it, anywhere. --show never prints it.
sub _config ($self, $config, $url, $show) {
  my $saved = $config->load;

  if ($show) {
    print STDOUT 'Configuration file: ' . $config->file . "\n";
    print STDOUT '  url:   ' . ($saved->{url} // '(not set)') . "\n";
    print STDOUT '  token: ' . ($saved->{token} ? '******** (set)' : '(not set)') . "\n";
    return EXIT_CLEAN;
  }

  # The URL is not secret, so it may come from --url; otherwise prompt, offering the current value as default.
  if (defined $url) { $saved->{url} = $url }
  else {
    my $current = $saved->{url};
    print STDERR 'Cavil URL' . (defined $current ? " [$current]" : '') . ': ';
    my $line = readline STDIN;
    chomp $line           if defined $line;
    $saved->{url} = $line if defined $line && length $line;
  }

  # The token is secret: hidden prompt on a terminal, one stdin line when piped. Empty input keeps the existing.
  my $entered = _read_secret('Cavil API token' . ($saved->{token} ? ' [keep existing]' : '') . ': ');
  $saved->{token} = $entered if defined $entered && length $entered;

  unless (length($saved->{url} // '') && length($saved->{token} // '')) {
    print STDERR "A Cavil URL and API token are both required\n";
    return EXIT_USAGE;
  }

  $config->save($saved);
  print STDOUT 'Saved configuration to ' . $config->file . " (token hidden)\n";
  return EXIT_CLEAN;
}

# Read one line without echoing it, so a typed token never appears on screen. Only toggles the terminal when
# stdin is one; piped input (tests, scripts) is read as a plain line.
sub _read_secret ($prompt) {
  print STDERR $prompt;
  my $hide = -t STDIN;
  system('stty', '-echo') if $hide;
  my $line = readline STDIN;
  if ($hide) { system('stty', 'echo'); print STDERR "\n" }
  chomp $line if defined $line;
  return $line;
}

# Confirm the url and token work by asking the instance who the token belongs to, and time the round trip so a
# user can also see the instance is reachable and responsive.
sub _whoami ($self, $opts) {
  my $client = $self->client->url($opts->{url})->token($opts->{token});
  $client->log($self->log);

  my $t0   = Time::HiRes::time;
  my $info = eval { $client->whoami };
  my $ms   = int((Time::HiRes::time - $t0) * 1000);
  if (my $err = $@) {
    chomp(my $msg = $err);
    print STDERR "Not authenticated with $opts->{url}:\n  $msg\n"
      . "Check the saved config ('cavil-cli config --show'), or CAVIL_URL / CAVIL_API_KEY.\n";
    return EXIT_SERVER;
  }

  if ($opts->{format} eq 'json') {
    print STDOUT encode('UTF-8', to_json({%$info, round_trip_ms => $ms}) . "\n");
    return EXIT_CLEAN;
  }

  my $roles = @{$info->{roles} || []} ? join(', ', @{$info->{roles}}) : 'none';
  print STDOUT encode('UTF-8',
        "Authenticated as $info->{user} (id @{[$info->{id} // '?']}) on $opts->{url}\n"
      . "  roles: $roles\n"
      . "  write access: @{[$info->{write_access} ? 'yes' : 'no']}\n"
      . "  round-trip: $ms ms\n");
  return EXIT_CLEAN;
}

# Run a scan, or report why it could not run. Returns the report, or an exit code to hand straight back.
sub _scan ($self, $path, $opts) {
  my $client = $self->client->url($opts->{url})->token($opts->{token});
  $client->log($self->log);
  my $cache    = Cavil::CLI::Cache->new(url => $opts->{url}, exclude => $opts->{exclude_packages})->load;
  my $progress = Cavil::CLI::Progress->new(enabled => $opts->{progress});
  my $scan     = Cavil::CLI::Scan->new(
    client           => $client,
    cache            => $cache,
    log              => $self->log,
    progress         => $progress,
    hidden           => $opts->{hidden},
    exclude_packages => $opts->{exclude_packages},
    exclude_paths    => $opts->{exclude_paths}
  );

  my $report = eval {
    $scan->run(
      $path // '.',
      all        => $opts->{all},
      since      => $opts->{since},
      staged     => $opts->{staged},
      path_given => defined $path
    );
  };
  $progress->finish;
  if (my $err = $@) {
    print STDERR "Code search is not enabled on this Cavil instance\n" if $err =~ /code_search_disabled/;
    print STDERR $err                                                  if $err !~ /code_search_disabled/;
    return (undef, $err =~ /code_search_disabled/ ? EXIT_USAGE : EXIT_SERVER);
  }

  return ($report, undef);
}

# Where the baseline for a scan of this path lives: it belongs to the project, not to the working directory the
# command happened to run from.
sub _baseline_file ($path, $opts) {
  return $opts->{baseline} if defined $opts->{baseline};
  return path($path // '.')->child(Cavil::CLI::Baseline::FILE)->to_string;
}

# Record the project's current matches as accepted, so later checks only report what is new.
sub _baseline ($self, $path, $opts) {
  my ($report, $exit) = $self->_scan($path, $opts);
  return $exit unless $report;

  my $file     = _baseline_file($path, $opts);
  my $accepted = Cavil::CLI::Baseline->from_findings($report->{findings});
  Cavil::CLI::Baseline->new(file => $file)->save($accepted);

  my $n = scalar @$accepted;
  print STDOUT encode('UTF-8',
    sprintf("Wrote %d accepted %s to %s\n", $n, $n == 1 ? 'match' : 'matches', $file)
      . "Commit it: later checks report only matches that are not in this file.\n");
  return EXIT_CLEAN;
}

sub _check ($self, $path, $opts) {
  my ($report, $exit) = $self->_scan($path, $opts);
  return $exit unless $report;

  # Drop what the project has already accepted. Only for a whole-tree scan: a diff already answers "what is new"
  # by construction, and its regions are fragments with no stable identity to record.
  if (!$opts->{no_baseline} && $report->{scope} eq 'tree') {
    my $file     = _baseline_file($path, $opts);
    my $baseline = Cavil::CLI::Baseline->new(file => $file)->load;
    my $before   = scalar @{$report->{findings}};
    $report->{findings}      = [grep { !$baseline->accepts($_) } @{$report->{findings}}];
    $report->{accepted}      = $before - scalar @{$report->{findings}};
    $report->{baseline_file} = $file;
  }

  my $output
    = $opts->{format} eq 'json'
    ? render_json($report)
    : render_text($report, color => $opts->{color}, fail_on_risk => $opts->{fail_on_risk});

  # Encode once here at the output boundary; the renderers return character strings (glyphs and any Unicode in
  # paths or licenses), and STDOUT is not given an encoding layer (it does not survive the test's in-memory
  # capture reliably).
  print STDOUT encode('UTF-8', $output);

  my $g
    = gate($report->{findings}, {fail_on_risk => $opts->{fail_on_risk}, fail_on_unknown => $opts->{fail_on_unknown}});
  return $g->{failed} ? EXIT_GATE : EXIT_CLEAN;
}

1;

=encoding utf8

=head1 NAME

Cavil::CLI - Check code against known open source and commercial code indexed by Cavil

=head1 SYNOPSIS

  Usage: cavil-cli <command> [DIR] [OPTIONS]

    # Save the URL and token once (prompts for the token without echoing it)
    cavil-cli config --url https://legaldb.suse.de

    # Confirm the URL and token are set up right (and time the round trip)
    cavil-cli whoami

    # With no path, check the current git change set
    cavil-cli check

    # With a path, scan that whole tree
    cavil-cli check ./project

    # Machine-readable output for CI (URL and token from the environment)
    CAVIL_URL=https://legaldb.suse.de CAVIL_API_KEY=1234 cavil-cli check --format json

    # Accept the matches this project already has, so later checks only report new ones
    cavil-cli baseline ./project

  Commands:
    check [DIR]              Check a change set or tree for known code (the default workflow)
    baseline [DIR]           Record the tree's current matches as accepted, in .cavil-baseline.json
    whoami                   Show the user the token belongs to, to verify login
    config                   Save the URL and token to ~/.config/cavil-cli (--show to display, token masked)

  Credentials come from the saved config ("cavil-cli config"), or CAVIL_URL/CAVIL_API_KEY in CI, always as a
  pair from one source. There is no --token (an argument is world-readable in ps and stays in shell history),
  and --url is only accepted by "config", since aiming elsewhere would send it a token saved for this server.

  Options:
        --url <url>          Cavil server URL, when saving settings ("config" only)
        --all                Whole-tree scan of the current directory (a path already scans the whole tree)
        --since <ref>        Check the diff against this ref instead of the default branch
        --staged             Check staged changes only
        --fail-on-risk <n>   Exit non-zero at risk n or above (default 4, strong copyleft: the point where a
                             copy makes your work a derivative. 1-2 is obligation-free, 3 is file-level
                             copyleft, 5 and up escalate)
        --fail-on-unknown    Exit non-zero if any code has no known provenance
        --baseline <file>    Use this baseline instead of DIR/.cavil-baseline.json
        --no-baseline        Report every match, ignoring an existing baseline
        --exclude-package <name>
                             Ignore matches carried only by this package, so a working copy of an
                             open source project does not match its own indexed package. Repeatable;
                             also read from CAVIL_EXCLUDE_PACKAGES (comma or space separated)
        --exclude-path <glob>
                             Skip files under this path entirely (e.g. test-fixture directories). A bare
                             path excludes it and everything under it; otherwise a shell glob (as Cavil's
                             ignore globs: * matches across /, so *.pattern matches anywhere). Repeatable;
                             also read from CAVIL_EXCLUDE_PATHS
        --format <format>    Output format, "text" (default) or "json"
        --hidden             Also scan hidden files (dotfiles and dot-directories); skipped by default
        --no-color           Disable coloured output
        --quiet              Do not show the progress line while working
    -h, --help               Show this summary of available options

=head1 DESCRIPTION

A command-line client that checks whether the code in a git change set or a directory already exists in the
open source Cavil has indexed, reporting its license and risk. It is meant for a developer's laptop and for
CI; see C<docs/Architecture.md> for the design.

=cut
