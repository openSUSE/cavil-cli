# SPDX-FileCopyrightText: SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package Cavil::CLI::Baseline;
use Mojo::Base -base, -signatures;

use Cavil::CLI::Util qw(provenance);
use Cpanel::JSON::XS ();
use Mojo::File       qw(path);
use Mojo::JSON       qw(decode_json);

# Committed next to the code it describes, so the accepted matches are a reviewable part of the project rather
# than a setting on one developer's machine or in CI.
use constant FILE => '.cavil-baseline.json';

# Only bumped if the entry shape changes incompatibly. An unrecognized version is refused rather than guessed
# at, which fails safe: every finding surfaces instead of being silently suppressed by a file we misread.
use constant FORMAT => 1;

has 'file';
has entries => sub { {} };

# A match is accepted by its content, never by its path alone: the local bytes AND what they matched both have
# to be what was accepted. Edit the file, or start matching something else, and the entry stops applying.
sub _key ($file, $content, $match_hash) { return join "\0", $file, $content // '', $match_hash // '' }

sub load ($self) {
  my $file = path($self->file);
  return $self unless -f $file;

  my $data = eval { decode_json($file->slurp) };
  if (!$data || ($data->{version} // 0) != FORMAT) {
    print STDERR 'Ignoring ' . $self->file . ": not a baseline this version understands\n";
    return $self;
  }

  my %entries;
  for my $e (@{$data->{accepted} // []}) {
    next unless defined $e->{file} && defined $e->{content};
    $entries{_key($e->{file}, $e->{content}, $e->{match_hash})} = $e;
  }
  $self->entries(\%entries);
  return $self;
}

# Is this finding one the project has already accepted? Only ever for a match that is no worse than the one
# recorded: the corpus keeps growing, so the same file can later match something riskier, and that is exactly
# the case a baseline must not hide.
sub accepts ($self, $f) {
  return 0 unless defined $f->{content} && $f->{match};
  return 0 unless my $e = $self->entries->{_key($f->{location}, $f->{content}, $f->{match_hash})};
  return ($f->{risk} // -1) <= ($e->{risk} // -1) ? 1 : 0;
}

# Turn this scan's matched findings into entries. The note is what a reviewer reads in the diff when an entry
# appears ("we now accept t/pod.t matching Mojolicious"), which is the point of committing the file at all.
sub from_findings ($class, $findings) {
  return [
    map {
      {
        file       => $_->{location},
        content    => $_->{content},
        match_hash => $_->{match_hash},
        risk       => $_->{risk},
        note       => provenance($_),
        (@{$_->{licenses} || []} ? (licenses => $_->{licenses}) : ())
      }
    } sort { $a->{location} cmp $b->{location} } grep { $_->{match} && defined $_->{content} } @$findings
  ];
}

# Written sorted and indented, because this file is committed and read in review: regenerating an unchanged
# project has to be a no-op in git, and a real change has to show as a few readable lines rather than a
# reshuffled blob. Perl's hash order would make a plain encode churn the whole file every time.
sub save ($self, $accepted) {
  path($self->file)
    ->spew(Cpanel::JSON::XS->new->canonical->pretty->utf8->encode({version => FORMAT, accepted => $accepted}));
  return $self;
}

1;
