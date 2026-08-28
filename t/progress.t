# SPDX-FileCopyrightText: SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Mojo::Base -strict, -signatures;

use Test::More;
use Cavil::CLI::Progress;

sub capture ($enabled, $code) {
  my $buffer = '';
  open my $fh, '>', \$buffer;
  local *STDERR = $fh;
  $code->(Cavil::CLI::Progress->new(enabled => $enabled));
  return $buffer;
}

subtest 'disabled progress is silent' => sub {
  my $out = capture(0, sub ($p) { $p->start('Hashing', 10); $p->tick($_) for 1 .. 10; $p->finish });
  is $out, '', 'nothing is written when disabled';
};

subtest 'enabled progress writes a self-erasing status line' => sub {
  my $out = capture(1, sub ($p) { $p->start('Hashing', 128); $p->tick($_) for 1 .. 128; $p->finish });
  like $out, qr/Hashing/,  'shows the phase label';
  like $out, qr/128\/128/, 'reaches the total';
  like $out, qr/\r\e\[K/,  'redraws in place with an erase';
};

subtest 'a phase without a total is just a label' => sub {
  my $out = capture(1, sub ($p) { $p->start('Recognizing') });
  like $out,   qr/Recognizing/, 'shows the label';
  unlike $out, qr{\d+/\d+},     'no counter without a total';
};

subtest 'spin animates the current label and is silent when disabled' => sub {
  my $on = capture(1, sub ($p) { $p->start('Searching 3 regions'); $p->spin for 1 .. 3 });
  like $on, qr/Searching 3 regions/, 'keeps the label while spinning';
  like $on, qr/\r\e\[K/,             'redraws in place';
  is capture(0, sub ($p) { $p->start('x'); $p->spin }), '', 'nothing when disabled';
};

subtest 'a spinning count update keeps the spinner, so the line does not flicker or jump' => sub {
  my $out = capture(
    1,
    sub ($p) {
      $p->start('Searching, 20 left');
      $p->spin;
      $p->start('Searching, 10 left');    # the count ticks down while requests are in flight
      $p->spin;
    }
  );

  # Before the fix, updating the count redrew a bare label (no spinner prefix), so the spinner blinked out and
  # the text jumped left by the prefix width until the next spin tick shoved it back. Every redraw of a spinning
  # phase must now lead with the spinner, so no frame is a bare label straight after the erase.
  unlike $out, qr/\r\e\[KSearching/,   'no frame redraws the label without the spinner in front of it';
  like $out,   qr/Searching, 10 left/, 'the updated count is shown';
};

subtest 'a labelled tick names the current item without resetting the counter, and always draws' => sub {
  my $out = capture(
    1,
    sub ($p) {
      $p->start('Fingerprinting', 100);
      $p->tick(1, 'Fingerprinting - src/a.c');    # not a multiple of REDRAW_EVERY, but a label forces a draw
      $p->tick(2, 'Fingerprinting - src/b.c');
    }
  );
  like $out, qr{Fingerprinting - src/a\.c 1/100}, 'the first item is drawn with its file and the running count';
  like $out, qr{Fingerprinting - src/b\.c 2/100}, 'and the next, so a pause shows the item it is pausing on';
};

done_testing;
