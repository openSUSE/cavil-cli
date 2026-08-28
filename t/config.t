# SPDX-FileCopyrightText: SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Mojo::Base -strict, -signatures;

use Test::More;
use Cavil::CLI::Config;
use Mojo::File qw(tempdir);

my $dir = tempdir;
local $ENV{XDG_CONFIG_HOME} = $dir->to_string;

subtest 'settings round-trip and live under XDG_CONFIG_HOME' => sub {
  my $config = Cavil::CLI::Config->new;
  is $config->file, $dir->child('cavil-cli', 'config.json')->to_string, 'stored under XDG_CONFIG_HOME/cavil-cli';
  is_deeply $config->load, {}, 'no configuration yet reads as empty';

  $config->save({url => 'https://legaldb.suse.de', token => 'secret-token'});
  my $reloaded = Cavil::CLI::Config->new->load;
  is_deeply $reloaded, {url => 'https://legaldb.suse.de', token => 'secret-token'},
    'a fresh instance reads back what was saved';
};

subtest 'the config file is written private (holds a token)' => sub {
  my $config = Cavil::CLI::Config->new;
  $config->save({url => 'https://legaldb.suse.de', token => 'secret-token'});
  my $mode = (stat $config->file)[2] & 07777;
  is $mode, 0600, 'only the owner can read the token';
};

subtest 'a corrupt config file does not crash, it reads as empty' => sub {
  my $config = Cavil::CLI::Config->new;
  $config->file->spew('not json');
  is_deeply $config->load, {}, 'garbage is treated as no configuration';
};

done_testing;
