# Cavil CLI Architecture

This document explains what the Cavil CLI does and, more importantly, *why* it is built the way it is. It is
meant to be read start to finish by someone new to the project, before they open the source. It talks about
concepts, not functions or line numbers.

## Why this exists

Cavil reviews the licensing of software on a server, as part of a formal legal workflow. That workflow is
thorough and deliberately slow: a package is submitted, unpacked, scanned, and eventually signed off by a
lawyer. It answers the question "is this package acceptable to ship".

The CLI answers a different, smaller, faster question: "does the code in front of me right now contain known
code, open source or commercial, that I should worry about". It is aimed at the moment *before* a formal
review, on a developer's laptop or in a CI pipeline, where the cost of asking must be near zero and the answer
must arrive in seconds. Cavil indexes more than open source, so the CLI stays license-neutral throughout: a
matched commercial or proprietary license is exactly the kind of thing it should surface, not just copyleft.

The reason this is worth building now is AI-assisted development. When an engineer writes code with an
assistant, they cannot always tell whether a suggestion was reproduced verbatim from a copyleft project. A
backported fix produced with an assistant carries the same uncertainty. And increasingly a whole project is
scaffolded by an agent, and nobody has read every line. In all three cases the useful check is the same: take
the code, and find where it already exists in what Cavil has indexed, with its license and its risk. That is a
provenance check, and it is what the CLI does.

## What it does, and what it does not

It finds known provenance for code. Point it at a change or a directory and it reports, per region of code,
whether that region is already known to Cavil, what it is a copy of, under what license, and at what risk on
Cavil's one-to-nine scale. In a CI pipeline it turns that into a pass or fail.

It does not request a formal legal review, and it does not clear anything. Whether a piece of code is
*acceptable* is a per-package decision that depends on license compatibility with everything else in that
package, and that decision does not transfer between packages, so the CLI never makes it. It reports facts
about the code's content and provenance, and leaves the acceptability judgement to the review workflow. The
ability to submit for a full review will come later, and the design leaves room for it.

## The commands

The work is one command. There is no separate step to scan, then convert, then inspect. You run the check, you
read the report, and in CI you look at the exit code. Keeping it to a single command with a built-in gate is a
deliberate reaction to the friction of multi-tool provenance pipelines, where the scan produces a raw data file
that a second and third tool must render and police before it means anything.

Two small helpers stand beside it. `whoami` asks the server who the token belongs to and times the round trip,
so a user can confirm the URL and token work and the instance is reachable before running a real check, and CI
can use it as a preflight. `config` saves the server URL and API token so they need not be passed every run;
the token is read from a hidden prompt (or piped in), never taken as a command-line flag where it would linger
in shell history and process listings, and it is stored under `~/.config/cavil-cli`, not with the disposable
cache. Credentials are resolved from flags, then the environment (for CI), then that saved config.

The scope follows the shape of the command, not any guessing about the working directory. With no path, it
checks the current repository's change set, the difference between the branch and the point it was made from,
because that is what a developer just wrote and what a merge request introduces. Given a path, it scans that
whole tree, because pointing at a directory means "look at this project." That is the whole rule; there is no
probing of whether something is a repository to decide the scope. Two flags override it when needed: `--all`
forces a whole-tree scan of the current directory, and `--staged` or `--since` force a diff. Git is still used
inside a whole-tree scan, but only to enumerate files so the repository's own ignore rules are honoured.

## How a check works

A check has three stages, arranged so that the cheapest possible answer is always tried first and the
expensive work only ever runs on what is left.

### Choosing what to check

The unit of work is a region of code. For a change set, the regions are the added parts of the diff, merged
where they are adjacent. For a whole directory, every file is a region, or a series of regions. Regions too
small to be distinctive are dropped, because a handful of lines matches everything and means nothing; the same
floor that the server's code search uses applies here.

### Recognizing what is already known

Most files, in most real trees, are byte-for-byte identical to something Cavil has already seen. The kernel
sources are the extreme case: nearly every file is already indexed. So before doing any matching, the CLI
computes a content hash for each file and asks the server, in one batched question, which of those hashes it
knows and what licenses and risk they carry. The same answer names one package and path that carry the content,
so a recognized file reads as a copy of something concrete rather than "a known source"; and when the content
is a package's own, non-vendored source, it also carries the license declared in that package's metadata (the
main license shown at the top of its report), a curated hint that is more useful than the per-file patterns when
those come back empty.

This stage is cheap for a reason that is worth stating plainly: the licenses and risk of a piece of content
are a fixed property of its bytes. They never change once known. That means the answer can be cached on the
client forever, keyed by the hash, and a second run over an overlapping tree asks the server almost nothing.
It also means a hash, which is a handful of bytes, stands in for a whole file, so the question is tiny to ask
and trivial for the server to answer from an index. Sending hashes instead of file contents is not about
privacy here; it is simply the least work for the most answer.

The cache is deliberately aggressive, because a user will interrupt a scan of a few hundred files and re-run
it a minute later, and that should cost the server nothing for the work already done. Two things are cached,
both keyed by content hash. Recognition (a hash's licenses and risk) is immutable and kept indefinitely. The
provenance of a residual file, described next, is not immutable: what the server can match depends on what it
has indexed, so those results are tagged with the server's index generation and dropped when it changes, so a
reindex never leaves a stale "no match" hiding a real one. Both are written incrementally, as each batch
completes, so an interrupted scan resumes exactly where it stopped: a re-run asks the server only about the
content it has not resolved yet, and a wholly unchanged tree asks nothing at all.

### Finding provenance for the rest

Whatever is not recognized exactly is either a modified copy of known code or genuinely new. To tell these
apart, the CLI fingerprints the leftover regions and asks the server's code search where else those
fingerprints occur. This is the same winnowing-based matching that powers Cavil's interactive code search: it
survives reformatting and small edits, and it reports how much of the region lines up as one contiguous copy,
which distinguishes a faithful copy from a coincidental scattering of common lines.

The fingerprinting is done on the client. The server only performs an indexed lookup. This split matters for
the whole design: the heavy, parallel, per-file work happens on the machine running the check, and the server
does the one thing only it can do, which is to search its index.

### The three verdicts

Every region ends up as one of three things:

- **Exact**, when its content hash is known. The license and risk are known precisely, and the answer came
  from the cheap first stage.
- **Partial**, when it is not identical but its fingerprints line up strongly with a known content. The report
  names what it is a modified copy of and how much of it aligned, with that content's detected licenses and the
  highest risk any of them carries, so a small high-risk copy embedded in a mostly-permissive file cannot hide
  the risk from the gate. Where the content is a package's own source and no per-file license was detected, the
  package's short declared license is shown as a hint. For a backported fix this is the common and reassuring
  case: the code lines up with the project's own upstream.
- **Unknown**, when little or nothing lines up. This is the reassuring result, not an alarm: it is code Cavil
  does not recognize, most often the author's own, and the report shows it as a clean tick rather than a
  warning. Turning an unknown region into a real license determination needs the full analysis pipeline, which
  is the server's job and the future review feature, not something the CLI attempts on its own.

## What fingerprinting can and cannot see

The provenance check is honest about its limits, and the report is worded to reflect them. Fingerprinting
samples the code rather than reading every token, so a small edit that happens to miss every sampled point is
invisible: renaming a single function, for instance, can leave a copy indistinguishable from its original.
This is a property of the matching, not a defect to be worked around at the client.

The practical consequence is a rule the report keeps: the tool never claims code is original. It can tell you
where code came from when it recognizes it; it cannot prove that code came from nowhere. So an unknown region
is presented as unrecognized, shown as a clean tick meaning "no known code here, your own as far as Cavil can
see", rather than as a guarantee of originality. That distinction matters most in exactly the situation that
will become common, when someone scans an entirely AI-written project and wants to be told it is clean: the
honest answer is "nothing known here", which is what the tick means.

## Where the work happens, and why

The guiding constraint is that the production Cavil instance must not feel this, no matter how many engineers
point the CLI at how many large trees. Every design choice about work placement follows from that.

The client walks the tree, hashes files, fingerprints regions, deduplicates identical regions before asking
about them, caches every immutable answer, and renders the report. The server answers two kinds of indexed,
read-only question and nothing more. Neither question touches the analysis or review pipeline that does the
real day-to-day work.

Two situations need more care than the rest. A freshly scaffolded project prefilters poorly, because its files
are new, so most regions reach the fingerprint stage; and a tree that is a near-copy of something indexed at
the wrong version misses the exact prefilter on every changed file. Both are handled by batching and pacing the
requests and caching every immutable answer, so even a poorly-prefiltering tree asks in bounded chunks rather
than one request per file. Two heavier measures are designed for but not yet built, to be added when real load
calls for them: matching whole files before regions so a version delta reports as one line ("these thousands of
files are modified copies of that version") instead of thousands of findings, and moving the whole-tree check
to a low-priority background job the CLI submits once and polls, which is also the shape the future review
submission will take.

## The report

The report is a per-file (or per-region) checklist, deliberately in human terms rather than the engine's
exact/partial/unknown vocabulary. Each file is graded by risk into a state: a clean tick for code with no known
provenance, a plain mark for known code that is permissive or carries only ordinary obligations, a red cross
for anything at or above the gate, and a dim mark for what was not scanned. It opens with a headline tied to
the gate and a one-line tally, then lists the files with problems first so a cap can never hide them; a very
large tree is capped with a note pointing at the JSON form for the rest. Files skipped by policy are reported
as counts in a footer, so "all clear" never quietly narrows its own coverage. A change-set check frames the
same thing as what the change *introduced* ("new known code"), because that is the question a diff answers.

By default the report is written for a person: aligned columns, colour and status marks on a terminal, plain
text when the output is not a terminal or colour is turned off. For machines there is a flat structured form,
one record per finding, carrying the fields a pipeline needs and none of the bookkeeping a human does not.
Human-first output is the default precisely because the common complaint about provenance tools is that their
default output is an unreadable data dump.

## The gate

In CI the report is a gate. The check fails when a finding crosses a risk threshold, and passes otherwise. It
gates on risk rather than on the mere presence of a match, because a match is often benign: a backported fix
that lines up with its own compatible upstream is expected, and failing on it would be noise. Gating on risk
keeps the failures meaningful. The exit code is conventional: zero when clean, one when the gate fails, and a
distinct code for a usage or server problem, so any non-zero code is the simple signal CI acts on while the
highest risk is shown in the report itself. A stricter project can also choose to fail on unrecognized code.

The threshold follows Cavil's own risk scale rather than an invented one: only risk 1 and 2 (public domain,
permissive) are truly obligation-free, 3 and 4 are copyleft that is acceptable but carries obligations,
escalation begins at 5, and 6 and 7 are reject-lean. The default gate is 5, so a build fails exactly when a
finding is something a human would need to review or refuse; the report colours a finding red only once it
meets the gate, shows the acceptable-but-notable band in between, and leaves the truly safe uncoloured. A
project with a stricter posture (say, a proprietary codebase that cannot take in any copyleft) lowers the
threshold; the number shown next to each finding carries its plain-language meaning so the choice is informed.

## What is and is not scanned

The scan honours the repository's own ignore rules silently, because those exclusions are the user's explicit
intent. On top of that it skips hidden files (dotfiles and dot-directories) by default, since they are
usually configuration and editor state rather than shipped source. That skip is a policy the tool chose, not
the user, so unlike the ignore rules it is never silent: the report states how many hidden files were passed
over and how to include them, because a hidden file could still be real copied source and a legal check must
not quietly narrow its own coverage. Binary and oversized files are left out too, as there is nothing to
fingerprint in them.

Legal documents are skipped the same visible way. A repository's own LICENSE, COPYING or NOTICE matching some
other project's copy of the same licence text is noise, not a finding, so those files are recognised by name
(using the server's own definition of a legal document) and passed over with a footer count. Two explicit
filters let a user cut more. `--exclude-path` drops whole subtrees, most often test fixtures that deliberately
contain other projects' code, using the same glob rules as Cavil's ignore globs; it is a pure client-side
scope choice and never changes what the server would answer for a given file. `--exclude-package` is different:
it tells the server to ignore matches carried only by named packages, so an engineer scanning a checkout of
their own open source project does not see it match its own indexed package. Because that filter is applied
where every carrier of a content is known, a file that is *also* shipped by another package still surfaces,
attributed to that other package, rather than vanishing.

## The service contract

The CLI depends on a small, stable contract with the Cavil server, deliberately narrow so it can be reasoned
about and mocked. It is a handful of read-only questions, all answered from an index. A configuration endpoint
returns the winnowing parameters the client must fingerprint with and the index generation, so the client
computes matching fingerprints and knows when to drop cached results. A recognition endpoint takes a batch of
content hashes and returns, for those it knows, their licenses and risk, one package and path that carry each,
and the declared license where the content is a package's own source. A batch fingerprint search takes
fingerprint sets and returns, for each, where that code is found, with the same containment and alignment
information the interactive code search reports. Both the recognition and the search accept a list of packages
to exclude, applied at the carrier level as described above. A small identity endpoint backs `whoami`.

Keeping the contract this small is what lets the server stay unaffected and lets the CLI be tested without a
server at all. It also means the CLI needs no knowledge of Cavil's internals, only of these two questions and
their answers.

## Running the matcher on the client

The client hashes and fingerprints with the same released matcher library the server uses. This is not an
optimization but a correctness requirement: a file must hash to the same value on the laptop as it did when
Cavil indexed it, or the recognition stage would never match, and fingerprints must be computed the same way
on both sides for the code search to find anything. Reusing the one implementation removes any chance of the
two drifting apart.

## Testing

The CLI is tested against a mock of the Cavil server, not a real one. Each scenario stands up a small
in-process web service that answers those endpoints with canned data and records exactly what the CLI asked
it. The requests to the server go through the real HTTP machinery, so the tests exercise the true wire
behaviour, but there is no database, no network, and no port to bind.

This choice is deliberate and it pays off in two ways. The recorded requests let a test assert the behaviours
that are the whole point of the design, that hashes were deduplicated, that questions were batched rather than
asked one file at a time, that a second run asked only about what the cache had missed. And because the
exchange is plain captured HTTP, a real problem seen in the field becomes a test with almost no translation:
the responses that triggered it become the mock's answers, and the requests that led to it become the
assertions. A field bug turns into a reproducer without needing a Cavil instance to recreate it.

Two layers sit on top of the mock. The parts of the CLI that never talk to the server, the report renderer,
the risk gate, the exit codes, and the logic that decides which regions to check, are written as plain
functions of their inputs and tested directly, by feeding them a fixed result and checking what they produce.
And small throwaway directories and git repositories serve as fixtures for the end-to-end scenarios, with
hashing being deterministic so the mock's canned answers stay stable.

The one real weakness of testing against a mock is that the mock can drift from the real server. The planned
guard is to share a single example exchange between the two projects, so the server's own suite proves it
produces that exchange and the CLI's mock serves it, and neither side can quietly change the contract without
the other noticing; until that is in place the two suites are kept aligned by hand, and the server's own tests
cover the endpoints it exposes.

## Design choices and their reasons

A few decisions are worth stating on their own, because they are the ones a reader is most likely to question.

- **One command with a gate, not a pipeline of tools.** Provenance tools commonly separate scanning,
  format conversion, and policy checking into distinct steps, which leaves the default experience as a raw
  data file that means nothing until two more tools have run. Folding all of it into one command with a
  human-readable default and a built-in gate is the main thing that makes the CLI pleasant to reach for.
- **Risk over a copyleft flag.** A simple copyleft yes-or-no is a coarse gate. Cavil already computes a
  one-to-nine risk that captures more than copyleft, so the CLI uses it, which lets a project set a threshold
  that matches its own tolerance instead of an all-or-nothing rule.
- **Recognition before matching.** The exact-hash prefilter exists because it is the cheapest possible answer
  and it resolves the large majority of files in any real tree. Doing it first is what makes scanning
  something as large as the kernel sources fast and gentle on the server, and what makes repeat runs in CI
  nearly free.
- **Honesty as a feature.** Never claiming code is original (an unrecognized file reads as "nothing known
  here", a clean tick, not a guarantee), keeping the gate on the per-file licenses so a declared-license hint
  can never lower it, and showing a declared license as a hint rather than a determination, are deliberate. The
  tool is most valuable when it is trusted, and it earns that by never claiming more than the matching supports.
