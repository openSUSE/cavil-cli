# SPDX-FileCopyrightText: SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package CavilCliTest;
use Mojo::Base -base, -signatures;

use Cavil::CLI;
use Mojo::File qw(tempdir);

# One CLI whose client user agent hosts the mock app. Hosting the mock and making the requests through the
# same user agent (and thus the same event loop) is what lets a blocking client request be served in-process,
# exactly as cavil-gitea does.
has cli => sub { Cavil::CLI->new };
has 'url';

# Each harness gets its own cache and config directories (via XDG_CACHE_HOME / XDG_CONFIG_HOME), so scenarios do
# not touch the real ones or each other, while two runs within one scenario still share them.
has cache_dir  => sub {tempdir};
has config_dir => sub {tempdir};

sub new ($class, $app) {
  my $self   = $class->SUPER::new;
  my $server = $self->cli->client->ua->server;
  $server->app($app);
  $self->url('http://127.0.0.1:' . $server->url->port);
  return $self;
}

# Run the CLI as a user would: seed @ARGV with the check command, the caller's arguments, and the mock's URL
# and a token. Capture stdout, stderr, logs and the exit code.
sub run ($self, @args) { return $self->run_command('check', @args) }

# Same, but for an arbitrary command (e.g. whoami) rather than the check default. The mock URL and a token are
# supplied by default, but a test can pass its own --url/--token to exercise a bad login.
sub run_command ($self, @argv) {
  my @extra;
  push @extra, '--url',   $self->url   unless grep { $_ eq '--url' } @argv;
  push @extra, '--token', 'test-token' unless grep { $_ eq '--token' } @argv;
  return $self->_invoke([@argv, @extra]);
}

# Run exactly the given arguments, with no default URL/token supplied, optionally feeding stdin (for the config
# command's prompts). Used to exercise credential resolution from the environment or the saved config file.
sub run_bare ($self, $argv, $stdin = undef) { return $self->_invoke($argv, $stdin) }

sub _invoke ($self, $argv, $stdin = undef) {
  my $cli      = $self->cli;
  my $messages = $cli->log->capture('trace');
  my ($out, $err, $code) = ('', '', undef);
  my $run = sub {
    local @ARGV                 = @$argv;
    local $ENV{XDG_CACHE_HOME}  = $self->cache_dir->to_string;
    local $ENV{XDG_CONFIG_HOME} = $self->config_dir->to_string;
    local $ENV{NO_COLOR}        = 1;
    $code = $cli->run;
  };
  {
    open my $o, '>', \$out;
    open my $e, '>', \$err;
    local *STDOUT = $o;
    local *STDERR = $e;
    if (defined $stdin) { open my $i, '<', \$stdin; local *STDIN = $i; $run->() }
    else                { $run->() }
  }

  return {stdout => $out, stderr => $err, logs => "$messages", exit => $code};
}

1;
