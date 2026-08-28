# SPDX-FileCopyrightText: SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package Cavil::CLI::Scan;
use Mojo::Base -base, -signatures;

use Cavil::CLI::Progress;
use Cavil::CLI::Util qw(parse_diff);
use File::Spec       ();
use Mojo::File       qw(path tempfile);
use POSIX            ();
use Text::Glob       qw(glob_to_regex);

require Cavil::Matcher;

# The client's fingerprint floor, matching the server's MIN_QUERY_FINGERPRINTS: fewer distinct fingerprints
# than this cannot be located reliably, so such a region is reported "skipped" without troubling the server.
use constant MIN_FINGERPRINTS => 8;

# Files larger than this are not source we can usefully fingerprint; skip them so a stray blob cannot dominate.
use constant MAX_FILE_BYTES => 2 * 1024 * 1024;

# Top matches (by overlap) to fetch per region, so the report can lead with the highest-risk one it carries
# rather than only the one it most resembles. A higher-risk match ranked below this by overlap is a weak signal.
use constant MATCH_CANDIDATES => 10;

has 'client';
has 'cache';
has 'log';
has progress => sub { Cavil::CLI::Progress->new };
has hidden   => 0;                                 # include hidden files (dotfiles and dot-directories); off by default
has exclude_packages => sub { [] };    # packages to treat as "my own", so a working copy does not match itself
has exclude_paths    => sub { [] };    # path globs/prefixes to skip entirely (e.g. test-fixture directories)
has k                => 4;
has w                => 8;

# Hidden = any path component starting with a dot. Skipped by default (config, CI, editor state), but surfaced
# as a count and overridable with --hidden, because a hidden file could still be real copied source.
sub _is_hidden ($rel) {
  return grep {/^\./} split m!/!, $rel;
}

# A legal document (LICENSE, COPYING, NOTICE, ...), not code. Mirrors Cavil::ReportUtil::is_license_filename,
# the server's own selector for legal documents: source extensions first, so a license.pl stays code. We filter
# here rather than server-side because the server only ever receives hashes and fingerprints, never the scanned
# file's name; a repository's own licence file matching some other project's licence file is noise, not a find.
my @SOURCE_EXTENSIONS = qw(
  asm awk bash c cc cjs cpp cs cxx dart el go gradle groovy h hh hpp java jl js jsx kt lua mjs mm
  php pl pm py rb rs scala sh sql swift tcl ts tsx vim
);
my $SOURCE_EXTENSION = do { my $alt = join '|', @SOURCE_EXTENSIONS; qr/[.](?:$alt)$/i };

sub _is_license_file ($rel) {
  my ($basename) = $rel =~ m{([^/]*)$};
  return 0 if $basename =~ $SOURCE_EXTENSION;
  return $basename =~ m{^(?:LICEN[CS]E|COPYING|COPYRIGHT|NOTICE|EULA|LEGAL|UNLICENSE|THIRD[_-]?PARTY)(?:[.\-]|$)}i
    ? 1
    : 0;
}

# Compile the user --exclude-path patterns once. A bare pattern (no glob characters) is kept as a literal path
# prefix, so it excludes that file or anything under it as a directory (t/fixtures -> t/fixtures/...). Anything
# else is a shell glob compiled with Text::Glob, the same module and non-strict setting Cavil uses for its
# ignore globs, so * crosses slashes and matches anywhere in the tree (e.g. *.pattern).
sub _compile_excludes ($patterns) {
  local $Text::Glob::strict_wildcard_slash = 0;
  return [map { /[*?[]/ ? {re => glob_to_regex($_)} : {prefix => $_} } @$patterns];
}

# Does a repo-relative path match a compiled --exclude-path set? Purely a scan-scope filter: it changes which
# files are hashed, never a per-hash answer, so it does not affect the cache.
sub _excluded_path ($rel, $compiled) {
  for my $m (@$compiled) {
    if (my $re = $m->{re}) { return 1 if $rel =~ $re }
    else                   { return 1 if $rel eq $m->{prefix} || index($rel, "$m->{prefix}/") == 0 }
  }
  return 0;
}

# Check a target and return the report structure the renderers consume. Scope follows the command shape, not
# any probing: with no path it checks the current repository's change set, given a path it scans that whole
# tree. --all forces a whole-tree scan; --staged/--since force a diff (of a given path too).
sub run ($self, $target, %opts) {

  # Animate the progress line while any request is in flight, so a slow server search still shows life.
  $self->client->on_wait(sub { $self->progress->spin }) if $self->progress->enabled;

  $self->progress->start('Connecting');
  my ($k, $w, $generation) = $self->_configure;
  $self->k($k)->w($w);

  # Drop any cached search results from an older index generation before we rely on them.
  $self->cache->for_generation($generation) if $self->cache;

  my $diff = !$opts{all} && ($opts{staged} || defined $opts{since} || !$opts{path_given});
  if ($diff) {
    my $base = $opts{staged} ? undef : ($opts{since} // $self->_default_base($target));
    return $self->_check_diff($target, $base, $opts{staged});
  }

  return $self->_check_tree($target);
}

# Fetch and adopt the instance's winnowing parameters (and index generation), so client fingerprints match its
# index and cached results are invalidated when it is rebuilt.
sub _configure ($self) {
  my $cfg = $self->client->config;
  return ($cfg->{k} // $self->k, $cfg->{w} // $self->w, $cfg->{generation});
}

# Change-set scope: fingerprint the added regions of the diff and search for their provenance.
sub _check_diff ($self, $dir, $base, $staged) {
  my @args = ('diff', '--unified=0', '--no-color');
  push @args, '--staged' if $staged;
  push @args, $base      if defined $base;
  my $diff    = _git($dir, @args) // '';
  my $regions = parse_diff($diff);

  # Drop the same classes a whole-tree scan skips, each counted by distinct file so the skip stays visible:
  # hidden files (unless asked), legal documents (a repo's own LICENSE is not code to trace), and --exclude-path.
  my $exclude = @{$self->exclude_paths} ? _compile_excludes($self->exclude_paths) : undef;
  my ($hidden, $license, $excluded);
  ($regions, $hidden)   = _drop_regions($regions, \&_is_hidden) unless $self->hidden;
  ($regions, $license)  = _drop_regions($regions, \&_is_license_file);
  ($regions, $excluded) = _drop_regions($regions, sub ($f) { _excluded_path($f, $exclude) }) if $exclude;

  my $progress = $self->progress;
  $progress->start('Fingerprinting changes', scalar @$regions);
  my (@queries, %meta, @findings, $done);
  for my $r (@$regions) {
    $progress->tick(++$done);
    my $location = "$r->{file}:$r->{start}-$r->{end}";
    my ($fps, $span) = $self->_winnow_text($r->{text});
    if (@$fps < MIN_FINGERPRINTS) {
      push @findings, {location => $location, file => $r->{file}, verdict => 'skipped', licenses => []};
      next;
    }
    push @queries, {id => $location, fingerprints => $fps, span => $span};
    $meta{$location} = {location => $location, file => $r->{file}, start => $r->{start}, end => $r->{end}};
  }

  # A diff region is a fragment, not a whole file, so it is not content-hash keyed and not cached.
  my $by_id = $self->_resolve_queries(\@queries);
  push @findings, {%{$meta{$_->{id}}}, %{$by_id->{$_->{id}}}} for @queries;

  return {
    scope      => 'diff',
    target     => $dir,
    instance   => $self->client->url,
    checked    => scalar @$regions,
    hidden     => $hidden   // 0,
    licensedoc => $license  // 0,
    excluded   => $excluded // 0,
    findings   => \@findings
  };
}

# Split diff regions on a file-path predicate: keep the ones that do not match, and return the count of distinct
# files that did (what the report shows as a skipped-by-policy count, not a region count).
sub _drop_regions ($regions, $pred) {
  my (%dropped, @kept);
  for my $r (@$regions) {
    if ($pred->($r->{file})) { $dropped{$r->{file}} = 1 }
    else                     { push @kept, $r }
  }
  return (\@kept, scalar keys %dropped);
}

# Whole-tree scope. Everything is keyed by content hash, so identical files are handled once and every answer
# (recognition, search, too-small) is cached and saved incrementally: an interrupted scan resumes where it
# left off, hitting the server only for content it has not resolved yet.
sub _check_tree ($self, $dir) {
  my $progress = $self->progress;
  my $cache    = $self->cache;

  # git only to enumerate files (so .gitignore is honoured); it plays no part in choosing the scope.
  my ($files, $hidden, $license, $excluded) = $self->_tree_files($dir, _is_git_repo($dir));

  # Hash every file; keep one representative path per distinct content so each content is winnowed once.
  $progress->start('Hashing files', scalar @$files);
  my (%hash_of, %abs_of, $hashed);
  for my $f (@$files) {
    my $h = Cavil::Matcher::content_hash($f->{abs});
    $hash_of{$f->{rel}} = $h;
    $abs_of{$h} //= $f->{abs};
    $progress->tick(++$hashed);
  }
  my @hashes = keys %abs_of;

  # Pull everything the cache already knows: immutable recognitions and generation-valid search results.
  $progress->start('Recognizing');
  my $known    = $cache ? {%{$cache->known(\@hashes)}}  : {};
  my $searched = $cache ? {%{$cache->search(\@hashes)}} : {};

  # Only ask the server about content resolved neither way. A hash already in the search cache is known to be
  # residual, so it needs no recognition request either; a rerun of an unchanged tree thus makes no request.
  my @miss = grep { !exists $known->{$_} && !exists $searched->{$_} } @hashes;
  if (@miss) {

    # Run the remaining count down as chunks complete (and cache each), so a large or slow recognition shows
    # life and progress rather than a spinner sitting on a bare "Recognizing".
    my $total = scalar @miss;
    $progress->start(sprintf('Recognizing, %d left', $total));
    my $fresh = $self->client->known(
      \@miss,
      exclude_packages => $self->exclude_packages,
      on_chunk         => sub ($done, $chunk) {
        $cache->store_known($chunk) if $cache;
        $progress->start(sprintf('Recognizing, %d left', $total - $done));
      }
    );
    %$known = (%$known, %$fresh);
  }

  # Residual = content Cavil does not recognize exactly; search only what the cache does not already have.
  my @residual  = grep { !exists $known->{$_} } @hashes;
  my @to_search = grep { !exists $searched->{$_} } @residual;

  # Winnow the residual once per content; too-small content is resolved without a request and cached too.
  $progress->start('Fingerprinting', scalar @to_search);
  my (@queries, %too_small, $done);
  for my $h (@to_search) {
    $progress->tick(++$done);
    my ($fps, $span) = $self->_winnow_file($abs_of{$h});
    if (@$fps < MIN_FINGERPRINTS) { $too_small{$h} = {verdict => 'skipped', licenses => []} }
    else                          { push @queries, {id => $h, fingerprints => $fps, span => $span} }
  }
  $cache->store_search(\%too_small) if $cache && %too_small;
  %$searched = (%$searched, %too_small);

  # Search, persisting each chunk so progress is never lost, then fold the results in.
  my $persist = $cache ? sub ($records) { $cache->store_search($records) } : undef;
  %$searched = (%$searched, %{$self->_resolve_queries(\@queries, $persist)});

  # One finding per file, built from the content-keyed answers.
  my @findings;
  for my $f (@$files) {
    my $h    = $hash_of{$f->{rel}};
    my $base = {location => $f->{rel}, file => $f->{rel}};
    if (my $info = $known->{$h}) {
      push @findings,
        {
        %$base,
        verdict  => 'exact',
        licenses => $info->{licenses} // [],
        risk     => $info->{risk},
        ($info->{package}                  ? (match => {name => $info->{package}, filename => $info->{filename}}) : ()),
        (defined $info->{declared_license} ? (declared_license => $info->{declared_license})                      : ())
        };
    }
    else { push @findings, {%$base, %{$searched->{$h}}} }
  }

  return {
    scope      => 'tree',
    target     => $dir,
    instance   => $self->client->url,
    checked    => scalar @$files,
    hidden     => $hidden,
    licensedoc => $license,
    excluded   => $excluded,
    findings   => \@findings
  };
}

# Run the batched fingerprint search and return each query's content-derived result, keyed by query id. The
# optional $persist callback is handed each chunk's records as they arrive, for incremental caching.
sub _resolve_queries ($self, $queries, $persist = undef) {
  return {} unless @$queries;

  # Run the remaining count down as chunks complete: a number that visibly drops feels like progress, where a
  # static "searching N" just looks stuck.
  my $total    = scalar @$queries;
  my $progress = $self->progress;
  $progress->start(sprintf('Searching, %d regions left', $total));

  # Ask for the top few matches (by overlap) so the report can headline the highest-risk one, not merely the
  # one the file most resembles: a region that is mostly permissive but carries a smaller high-risk copy must
  # still fail the gate. A small cap keeps the server enriching a handful of hits, not the whole match set.
  my %by_id;
  $self->client->search_batch(
    $queries,
    limit            => MATCH_CANDIDATES,
    exclude_packages => $self->exclude_packages,
    on_chunk         => sub ($done, $chunk) {
      my %records = map { $_->{id} => _record($_) } @$chunk;
      %by_id = (%by_id, %records);
      $persist->(\%records) if $persist;
      $progress->start(sprintf('Searching, %d regions left', $total - $done));
    }
  );

  return \%by_id;
}

# The content-derived part of a search result: what it is a copy of, under what license and risk, and how much
# aligned. The file's own location is added by the caller, since one content can carry several paths.
#
# Matches arrive best-overlap first, but the report leads with the highest RISK the region carries, so the gate
# cannot be slipped by a small high-risk copy hiding behind a large permissive one. Ties keep the strongest
# overlap (the first at that risk, since the list is overlap-ordered).
sub _record ($res) {
  my $matches = $res->{matches} // [];
  return {verdict => 'unknown', licenses => []} unless @$matches;
  my $pick = $matches->[0];
  for my $m (@$matches) { $pick = $m if ($m->{risk} // -1) > ($pick->{risk} // -1) }
  my $where = $pick->{files}[0];
  return {
    verdict  => 'partial',
    licenses => $pick->{licenses} // [],
    risk     => $pick->{risk},
    aligned  => $pick->{aligned},
    total    => $pick->{total},
    ($where                            ? (match => {name => $where->{name}, filename => $where->{filename}}) : ()),
    (defined $pick->{declared_license} ? (declared_license => $pick->{declared_license})                     : ())
  };
}

# Winnow a file directly into (deduped fingerprints as decimal strings, line span). Strings because a 64-bit
# fingerprint does not survive JSON transport as a number.
sub _winnow_file ($self, $abs) {
  my $raw = Cavil::Matcher::fingerprint_file($abs, $self->k, $self->w);
  return _winnow_rows($raw);
}

sub _winnow_text ($self, $text) {
  my $tmp = tempfile;
  $tmp->spew($text);
  return _winnow_file($self, $tmp->to_string);
}

sub _winnow_rows ($raw) {
  my %seen;
  my @fps = grep { !$seen{$_}++ } map {"$_->[0]"} @$raw;
  my ($lo, $hi);
  for my $r (@$raw) {
    $lo = $r->[1] if !defined $lo || $r->[1] < $lo;
    $hi = $r->[2] if !defined $hi || $r->[2] > $hi;
  }
  return (\@fps, defined $lo ? $hi - $lo + 1 : 1);
}

# The files to scan: tracked and untracked-but-not-ignored in a git repo, everything otherwise, minus the VCS
# directory, binaries, oversized blobs, and legal documents (a repo's own LICENSE matching another's is noise).
sub _tree_files ($self, $dir, $git) {
  my @rel;
  if ($git) {
    my $out = _git($dir, 'ls-files', '--cached', '--others', '--exclude-standard') // '';
    @rel = grep {length} split /\n/, $out;
  }
  else {
    # {hidden => 1} so dotfiles are enumerated; _is_hidden below decides whether to skip them (git ls-files
    # already lists tracked dotfiles). The .git directory itself is never scanned, even with --hidden.
    path($dir)->list_tree({hidden => 1})->each(
      sub ($e, $) {
        return if $e->to_rel($dir) =~ m!(?:^|/)\.git(?:/|$)!;
        push @rel, $e->to_rel($dir)->to_string;
      }
    );
  }

  my $exclude = @{$self->exclude_paths} ? _compile_excludes($self->exclude_paths) : undef;
  my ($hidden, $license, $excluded, @files) = (0, 0, 0);
  for my $rel (@rel) {
    my $abs = path($dir)->child($rel);
    next unless -f $abs;
    if ($exclude && _excluded_path($rel, $exclude)) { $excluded++; next }
    if (!$self->hidden && _is_hidden($rel))         { $hidden++;   next }
    if (_is_license_file($rel))                     { $license++;  next }
    my $size = -s $abs;
    next if !defined $size || $size == 0 || $size > MAX_FILE_BYTES;
    next unless _is_text($abs);
    push @files, {rel => $rel, abs => $abs->to_string};
  }
  return (\@files, $hidden, $license, $excluded);
}

# A NUL byte in the first block marks a binary we should not try to fingerprint.
sub _is_text ($abs) {
  open my $fh, '<:raw', $abs or return 0;
  read $fh, my $buf, 4096;
  close $fh;
  return index($buf, "\0") < 0;
}

sub _is_git_repo ($dir) {
  my $out = _git($dir, 'rev-parse', '--is-inside-work-tree');
  return defined $out && $out eq 'true';
}

# The merge-base of HEAD and the repository's default branch, the change set a merge request introduces.
sub _default_base ($self, $dir) {
  my $head_def = _git($dir, 'symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD');
  for my $ref (grep {length} ($head_def // ''), 'origin/main', 'origin/master', 'main', 'master') {
    my $base = _git($dir, 'merge-base', 'HEAD', $ref);
    return $base if defined $base && length $base;
  }
  return undef;
}

# Run git and return trimmed stdout, or undef if git is missing or the command fails. The child's stderr is
# sent to the null device so a failed lookup (a missing default branch, a non-repo target) never leaks onto
# the terminal, regardless of how the caller has redirected its own handles.
sub _git ($dir, @args) {
  my $pid = open(my $fh, '-|');
  return undef unless defined $pid;
  if ($pid == 0) {

    # Force file descriptor 2 itself to the null device: reopening the STDERR handle is not enough when the
    # caller has redirected it to an in-memory scalar, which leaves the inherited fd 2 pointing at the terminal.
    open my $devnull, '>', File::Spec->devnull;
    POSIX::dup2(fileno($devnull), 2);
    exec 'git', '-C', $dir, @args;
    exit 127;
  }
  local $/;
  my $stdout = <$fh> // '';
  close $fh;
  return undef if $? != 0;
  $stdout =~ s/\s+\z//;
  return $stdout;
}

1;
