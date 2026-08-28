# SPDX-FileCopyrightText: SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package Cavil::CLI::Progress;
use Mojo::Base -base, -signatures;

use Mojo::Util qw(encode);

# A single self-erasing status line on STDERR, so a long scan always shows what it is doing without touching
# STDOUT (which carries the report or a JSON pipe). Disabled unless STDERR is a terminal, so CI logs stay
# clean. Counting phases redraw every REDRAW_EVERY items (small enough that a few-hundred-file scan visibly
# counts up, large enough not to thrash a huge one); a blocking phase animates a spinner instead.
use constant REDRAW_EVERY => 16;

my @SPINNER = ("\x{2839}", "\x{2838}", "\x{283c}", "\x{2834}", "\x{2826}", "\x{2827}", "\x{2807}", "\x{280f}");

has enabled => 0;
has [qw(label total)];
has _frame => 0;
has _done  => 0;

# Begin a phase, optionally with a total to count towards. A phase without a total is a spinning phase: the line
# leads with an animated spinner and the label carries any changing count (e.g. "Searching, N left"). A phase
# with a total is a counting phase: the label plus a done/total counter, advanced by tick().
sub start ($self, $label, $total = undef) {
  $self->label($label)->total($total)->_done(0);
  $self->_draw;
  return $self;
}

sub tick ($self, $done) {
  return unless $self->enabled;
  my $total = $self->total;
  return if $done % REDRAW_EVERY && (!defined $total || $done != $total);
  $self->_done($done);
  $self->_draw;
}

# Advance the spinner one frame; called on a timer while a request is in flight so the line shows life.
sub spin ($self) {
  return unless $self->enabled;
  $self->_frame($self->_frame + 1);
  $self->_draw;
}

# Erase the status line, so it never bleeds into the report that follows.
sub finish ($self) {
  return unless $self->enabled;
  $self->_write('');
}

# One line format for every redraw path, so a count update and a spinner tick never disagree on the layout (a
# spinner that appears only on tick would blink and shove the text left and right as the count changed). A
# spinning phase always leads with the spinner glyph; a counting phase always shows the counter.
sub _draw ($self) {
  return unless $self->enabled;
  my $label = $self->label // '';
  my $total = $self->total;
  my $line  = defined $total ? "$label " . $self->_done . "/$total" : $SPINNER[$self->_frame % @SPINNER] . " $label";
  $self->_write($line);
}

sub _write ($self, $text) {
  print STDERR encode('UTF-8', "\r\e[K$text");
}

1;
