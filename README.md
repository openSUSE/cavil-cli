# Cavil CLI

A command-line client for [Cavil](https://github.com/openSUSE/cavil) that checks whether the code in a git
change set or a directory already exists in what Cavil has indexed (open source and commercial), and reports
its license and risk. It is built for a developer's laptop and for CI. It does not request a formal review or
decide acceptability; it tells you what known code you are carrying and how risky it is.

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

The URL and token are resolved from `--url` / `--token`, then `CAVIL_URL` / `CAVIL_API_KEY` (convenient for
CI), then the saved config in `~/.config/cavil-cli`. `cavil-cli config --show` displays them with the token
masked.

A check prints a headline tied to the CI gate, a one-line tally, then a per-file (or per-region) checklist,
problems first:

```
$ cavil-cli check --all ./project
✗ 1 file at or above risk 5
  42 files · 30 clean · 3 with known code · 9 too small

  ✗  src/net.c        SSPL-1.0  risk 6 (restrictive obligations)  modified 74% of mongodb src/net.c
  •  src/ls.c         MIT  risk 2 (permissive)  identical to coreutils src/ls.c
  •  src/opt.c        declared BSD-3-Clause  modified 61% of util-linux lib/opt.c
  ✓  src/local.c
  ·  gen.h            too small

  2 license files not scanned (a copy of a licence is not a finding)
```

`✓` is your own or permissive code, `•` is known code worth knowing about, `✗` is at or above the risk gate,
`·` was not scanned. When no per-file license is detected but the carrier package declares a short one, it is
shown as a hint (`declared BSD-3-Clause`).

## Commands and options

Common to every command: `--url` / `--token` (or `CAVIL_URL` / `CAVIL_API_KEY`, or the saved config),
`--no-color`, and `--quiet`.

`check [DIR]` - check a git change set (no path) or a whole tree (a path, or `--all`):

```
--all                 Whole-tree scan of the current directory (a path already scans the whole tree)
--since <ref>         Diff against this ref instead of the default branch
--staged              Check staged changes only
--fail-on-risk <n>    Exit non-zero at risk n or above (default 5; only risk 1-2 is truly safe)
--fail-on-unknown     Exit non-zero if any code has no known provenance
--exclude-package <name>   Ignore matches carried only by this package, so a working copy of an open source
                           project does not match its own indexed package (repeatable; CAVIL_EXCLUDE_PACKAGES)
--exclude-path <glob>      Skip files under this path entirely, e.g. test fixtures (repeatable;
                           CAVIL_EXCLUDE_PATHS)
--format text|json    Output format (json for CI to police or store)
--hidden              Also scan hidden files (dotfiles); skipped by default
```

`whoami` - show who the token belongs to and time the round trip; `--format text|json`.

`config` - save the URL and token to `~/.config/cavil-cli` (the token is read from a hidden prompt, never the
command line); `--url <url>` to set the server, `--show` to print the saved settings with the token masked.

Exit codes: `0` clean, `1` the risk gate failed, `2` usage or configuration problem, `3` server or connection
error.

## Documentation

See the [docs](docs) directory, starting with the [architecture](docs/Architecture.md) guide for how it works
and why it is built this way.
