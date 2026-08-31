# Cavil CLI

[![CI](https://github.com/openSUSE/cavil-cli/actions/workflows/ci.yml/badge.svg)](https://github.com/openSUSE/cavil-cli/actions/workflows/ci.yml)

Your AI assistant can reproduce a licensed function verbatim in your code, as if it were your own. Cavil CLI
checks a git change or a whole tree against what [Cavil](https://github.com/openSUSE/cavil) has indexed, open
source and commercial, and reports the license and risk of any copied code before it ships.

## Usage

```
# Save the server and token once (prompts for the token without echoing it)
cavil-cli config --url https://legaldb.suse.de

# Confirm it works (and time the round trip)
cavil-cli whoami

# Check the current git change set (what your branch introduces), against the default branch
cavil-cli check

# Scan a whole tree instead (a path, or --all for the current directory)
cavil-cli check ./project
cavil-cli check --all
```

Credentials come from the saved config in `~/.config/cavil-cli`, or from `CAVIL_URL` and `CAVIL_API_KEY` in CI
- always as a pair, from one source. There is no `--token`, because an argument is world-readable in `ps` and
stays in your shell history, and no `--url` outside `config`, because pointing at another server would send it
a token saved for this one. `cavil-cli config --show` displays what is saved, with the token masked.

A check prints a headline tied to the CI gate, a one-line tally, then a per-file (or per-region) checklist,
problems first:

```
$ cavil-cli check --all ./project
✗ 2 files at or above risk 4
  42 files · 29 clean · 4 with known code · 9 skipped

  ✗  src/net.c        SSPL-1.0  risk 6 (restrictive obligations)  modified 74% of mongodb src/net.c
  ✗  src/hash.c       GPL-3.0-only  risk 4 (strong copyleft)  modified 68% of coreutils lib/hash.c
  •  src/ls.c         MIT  risk 2 (permissive)  identical to coreutils src/ls.c
  •  src/opt.c        declared BSD-3-Clause  modified 61% of util-linux lib/opt.c
  ✓  src/local.c
  ·  gen.h            too short
  ·  bundle.min.js    too large

  2 license files not scanned (a copy of a licence is not a finding)
```

`✓` is your own code (nothing known was found), `•` is known code - permissive with no real obligations, or
worth a closer look, `✗` is at or above the risk gate, `·` was not scanned, with the reason (`too short` to
locate, or `too large` - a data or generated file). When no per-file license is detected but the carrier
package declares a short one, it is shown as a hint (`declared BSD-3-Clause`).

## Commands

```
cavil-cli <command> [DIR] [options]
```

| Command | Purpose |
| --- | --- |
| `check [DIR]` | Check a git change set, or a whole tree, for known code |
| `baseline [DIR]` | Record a tree's current matches as already accepted |
| `whoami` | Verify the configured URL and token |
| `config` | Save the URL and token |

Common options (`--format` applies to `check` and `whoami`):

| Option | Description |
| --- | --- |
| `--format text\|json` | Output format; `json` for CI to police or store |
| `--no-color` | Never colour the output (also honours `NO_COLOR`) |
| `--quiet` | No progress output |
| `-h`, `--help` | Show usage |

### `check [DIR]`

```sh
cavil-cli check              # the current git change set
cavil-cli check ./project    # a whole tree
cavil-cli check --all        # the current directory as a tree
```

| Option | Description |
| --- | --- |
| `--all` | Scan the whole tree instead of the change set |
| `--since <ref>` | Diff against this ref instead of the default branch |
| `--staged` | Check staged changes only |
| `--fail-on-risk <n>` | Exit non-zero at risk `n` or above (default `4`) |
| `--fail-on-unknown` | Exit non-zero if any code has no known provenance |
| `--baseline <file>` | Use this baseline instead of `DIR/.cavil-baseline.json` |
| `--no-baseline` | Report every match, ignoring an existing baseline |
| `--exclude-package <name>` | Ignore matches carried only by this package, so a working copy of an open source project does not match its own indexed package (repeatable, `CAVIL_EXCLUDE_PACKAGES`) |
| `--exclude-path <glob>` | Skip files under this path entirely, e.g. test fixtures (repeatable, `CAVIL_EXCLUDE_PATHS`) |
| `--hidden` | Also scan hidden files (dotfiles); skipped by default |

The default gate of `4` is strong copyleft, where a copy makes your work a derivative. Raise it if you already
ship copyleft, lower it to `3` if you cannot take in any.

### `baseline [DIR]`

```sh
cavil-cli baseline ./project
```

Writes every current match to `DIR/.cavil-baseline.json`. Commit it, and later checks report only what is
*not* in it - so the report stays about new code instead of repeating decisions you have already made.

Entries are pinned to a file's content and to what it matched, and never hide a risk higher than the one
accepted; see the [architecture guide](docs/Architecture.md) for the full rules. Takes the same `--baseline`,
`--exclude-*` and `--hidden` options as `check`.

### `whoami`

```sh
cavil-cli whoami
```

Shows who the token belongs to, and the round-trip time to the instance.

### `config`

```sh
cavil-cli config --url https://legaldb.suse.de   # prompts for the token
cavil-cli config --show
```

| Option | Description |
| --- | --- |
| `--url <url>` | Server to save |
| `--show` | Print the saved settings, with the token masked |

Settings are stored in `~/.config/cavil-cli`. The token is read from a hidden prompt (or stdin when piped),
never from the command line, where it would linger in shell history and process listings.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Clean |
| `1` | The risk gate failed |
| `2` | Usage or configuration problem |
| `3` | Server or connection error |

## Documentation

See the [docs](docs) directory, starting with the [architecture](docs/Architecture.md) guide for how it works
and why it is built this way.
