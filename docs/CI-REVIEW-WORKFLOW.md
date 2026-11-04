# Source review and leader-selected CI

The operator's policy in `docs/constitution.xml` owns this workflow. Work proceeds
in stacked PRs: each later PR targets the preceding branch. Native Stack metadata
names the trunk and the included parents.
Review function, logic and code cleanliness independently; approve the current
head when no P0/P1/P2 issue remains and collect P3 findings for later. A reviewer
may submit GitHub APPROVE directly for the reviewed head. Record the completed
successful full run separately for Release.
Before integration check the current independent review, head, base, complete
diff and unresolved findings. A non-native branch chain lands parent first; a
native stack lands whole through its top PR.

Current-head GitHub approvals do not depend on a reviewer association or body
format. Other accounts' change requests remain visible. A later formal approval replaces an earlier
change request on the same account, but does not prove the original finding was
resolved. Before merging, the integrator reads the review and comment text and
checks the change or explanation that addresses each outstanding concern.

There is no automatic PR, push or tag CI. The operator-authorized
`main-minimal-build.yml` checks main at minutes 7 and 37: it builds the server,
TUI, browser host and deployment preflight executables in one Dune invocation.
Successful non-documentation input fingerprints skip toolchain setup and build;
the summary names the actual previously built SHA, and a skip is not compilation
evidence for a newer SHA. Existing opam caching and a shared Dune cache reduce
repeated work. Builds are serialized without cancelling the active build.
Scheduling may be delayed; this does not guarantee a build within 30 minutes.
This observation does not approve a PR or replace full Release/Tag checks.

An optional merge-compile observation can be requested: `merge-compile.yml`,
dispatched explicitly on main with the exact head SHA
(top head for stacks, PR head for singles), builds the same four
executables in one Dune invocation and settles a `merge-compile` commit
status on that SHA. The executing toolchain (`.github/actions`, the two
scripts it invokes) must be byte-identical to main's, or the dispatch fails;
toolchain PRs re-dispatch with `trust-head-toolchain=true`, which is recorded
in the settled status and receipt. Non-documentation inputs identical to an
already built SHA settle instantly by input identity (docs-only heads build
nothing — no dune rule in the four-executable closure reads `docs/`,
`docs-site/` or `changelog.d/`); anything else builds asynchronously —
dispatch fire-and-forget. The record describes the head that was built; a new
head needs a separate record. The status and freshness against the merge target
are advisory for ordinary stacks.
A dispatch from any branch other than main is a proof run: it exercises the
whole pipeline but writes no commit status, so only the workflow file on main
can mint that commit status.

For an explicitly selected
approved combination, use [the selection commands](../scripts/review/APPROVED-CI-SELECTION.md)
to prepare the candidate and receipt. Dispatch `leader-ci.yml` from main with the
exact candidate SHA, receipt and chosen scopes. Main's verifier rechecks source
approvals and reconstructs that candidate before build or test jobs begin.
Preparation and runner rechecks read current GitHub review states through
`github-reviews.py`, require an accepted approval on each selected head and
reject outstanding formal change requests. They also recheck the selected PR
identities and candidate. GitHub review records alone do not prove the reviewed
session's independence or the base and complete diff actually inspected. Review
the actual change and any outstanding comments. This read-only
review lookup does not consult the selected run's own CI pin, so a pending or
failed pin cannot prevent verification or an explicitly requested retry. It cannot
publish approval or admit a release. A pending or failed selected run remains
visible as its actual status when considering integration.
Ordinary compile builds only `lib/masc.cmxa` for the stack bottom. Ordinary behavior
verification requires explicit suites. Prefer short, lightweight checks; about
two minutes is an example of their size, not a fixed cap, job timeout or pass/fail
boundary. Existing stalled-job and runner hang guards are separate resource
safeguards. Incomplete or skipped coverage is never a successful build or test
result.

Suite selection follows the content of the change, not a path heuristic. One
standing mapping: a PR that edits anything under `config/tools/` selects
`test_tool_definition_toml` for its targeted verification — that suite runs
`Tool_definition_toml.validate_embedded` over the whole shipped tree, so it
catches a wrong key in one file before landing instead of waiting for the
nightly lane. The
2026-10-19 regression (#44011, a bad `[[tool.items]]` key that killed
`main_eio`/`masc_tui` at boot while syntax checks stayed green) is the reason:
the guard existed, but no review path ran it.

Native GitHub Stacks use REST `stack` metadata and the [stack workflow](guides/NATIVE-GITHUB-STACKS.md). Merge a native stack whole, once, through its top PR; never merge it layer by layer from the bottom. The asynchronous merge endpoint on the top PR includes every open PR below it. Inspect and approve every included head; do not treat a non-main direct base as a blocker or manually retarget a native stack. A leaf source-review PASS does not certify its downstack.

For a remote-SSH shim compatibility failure, `linux-x64-probe.yml` also accepts
the explicit manual targets `exec-shim-linux-arm64` and `exec-shim-linux-amd64`.
Pass a full `candidate_sha` and dispatch from a ref containing those targets.
Only the chosen architecture builds, using the release's static-musl builder
on a matching native Linux runner. Only the probe driver file is checked out
from the workflow ref, so its nested checkout adds no second Dune package;
the shim and compiler recipe come from the candidate checkout. The artifact
includes binary checksums, both source identities, and an actual framed payload
that loads `env_file`, alongside the version probe. This establishes candidate
shim/config execution; SSH transport, bootstrap installation, Keeper behavior,
release verification and production deployment remain separate evidence.

`pr-check.yml` offers optional explicit `workflow_dispatch` source/config syntax
and committed-credential checks. With `native-tui-source-sha`, it also offers an
exact-source macOS TUI artifact and focused behavior checks. The default native
scenario is `detail-ownership`; `workspace-files` packages its matching server
and checks Git file discovery, workspace ownership and file confidentiality.
See [native TUI proof](guides/NATIVE-TUI-PROOF.md) for the exact targets and
receipt scope. It has no PR, push or scheduled trigger. Request it deliberately
when that coverage is needed; it is separate from leader-selected candidate
verification and does not grant merge permission.

`ci.yml` and `test.yml` are reusable components. The operator explicitly approved
retaining the daily `test.yml` full behavior run on 2026-10-12: 17:43 UTC
(02:43 KST), with its existing failure issue reporting. The
[approval record](evidence/2026-10-12-nightly-ci-operator-approval.md) addresses
the missing authorization raised on #42290. This regression observation does
not grant PR approval or replace verification of a fixed release candidate.

Full type checking, release
profile, dashboard, behavioral suites and distribution/installation
verification belong to `release-candidate.yml` at Release/Tag. Release publication
uses `release.yml` with an existing version tag, `rc_run_id`, and explicit
`publish=true`. The tagged commit must match the latest successful complete candidate run.
Here complete candidate verification means full type/compile, four-platform
installation and every suite in the versioned essential behavior manifest. It
does not mean repository-wide regression. Artifact publication and production
readiness are separate claims: production-ready also requires every quantitative
fleet, continuity, performance and Agent Core gate in
[Production Readiness Gates](PRODUCTION-READINESS-GATES.md).
The publication job verifies its receipt and artifact checksums and uploads the
existing distribution; it does not rebuild or rerun tests. A publication run is
not full verification evidence for approval or merge. Development and release-profile OCaml type checks share
one toolchain job. The small `release-behavior.yml` workflow runs the explicit
[`release-essential-v2` selection](../config/release-behavior.json), not root `@runtest`.
The receipt records the profile, exact suite list and manifest SHA-256; publication
rejects a missing or different selection even when the behavior job is green.
There is no known-failure exemption list. Every selected suite must pass.
The behavior lane runs product suites. CI/review, build-checker and evidence-validator self-tests are not part of the test suite. The optional credential check runs the scanner directly against the tracked tree.
Presentation tools and the broad sandbox image are prepared only for explicitly requested full regression runs. The dashboard is
built once with the production configuration and shared by all native targets;
type checks and dashboard payload-consumer tests stay in their own job. That
job exercises Goal, schedule, turn-record, verification, portrait, lifecycle and
memory behavior directly; test selection does not scan backend source strings.
Installer script tests run once on Linux in the distribution
job and once on macOS with stock Bash and BSD utilities;
each of the four native targets still builds and verifies its shipped binaries
and installation. Native files are uploaded after installation validation;
early unverified duplicates and the separate fixture-preview bundle are omitted.
The release behavior selection uses isolated fixtures; full regression builds its own sandbox image where required.
The behavior lane prepares its sandbox image directly from the checked-in recipe
before testing; it does not build the server just to print that recipe. BuildKit
reuses the sandbox's document/media package layers through an architecture-scoped
GitHub Actions cache. Recipe or resolved base-image changes rebuild affected
layers; `pull` checks the base tag on every run. The full lane reuses its shim
Buildx builder, while targeted non-minimal runs set one up without preparing the
shim. Minimal runs prepare neither image.
Native PDF, presentation and video suites still need host tools. Those packages
are installed separately with `--no-install-recommends`; this omits optional
packages, not required dependencies. Minimal runs that explicitly select
`test_verification_authority_tools` (bare or repository-relative) install only
`poppler-utils` and `ffmpeg` for that suite's actual PDF/MP4 checks; they still
omit presentation preparation and sandbox images. All real media checks remain
enabled. The installation lane still tests the embedded recipe through the release CLI.
The dashboard build helper owns dependency installation, so its caller does not
install the same dependencies a second time.
Behavior and Linux installation share the static shim builder recipe and its
architecture-scoped GitHub Actions image cache. The image contains the compiler
and dependencies, not a previously built shim: each consumer still builds the
current source. Full behavior prepares it before the suite so a Docker transport
test does not occupy a Dune worker while bootstrapping OCaml. Cache misses build
the same recipe; cache export failure does not change the verification verdict.
Cold jobs can still prepare concurrently, and cache visibility follows GitHub's
branch rules. This is reuse of preparation, not measured RC speedup or reuse of
another commit's release artifact.
TLA model checks run explicitly through `model-check.yml` when state-machine
specifications change; they are not a prerequisite for shipping a binary.
Specialized host and packaging proofs remain manual.

### Run behavior locally before submitting a repair

```bash
opam exec -- bash scripts/run-release-behavior.sh
```

Use the candidate checkout and its pinned dependencies. The command uses the same
selected runner as RC and preserves each suite's declared environment/dependencies.
GNU `timeout` (or `gtimeout` on macOS), Python,
ripgrep and the OCaml test dependencies must be available. A local result records
its platform and candidate; it does not substitute for a different platform's RC.

For targeted executable runs, `scripts/ci/stanza_env.py` selects the named
`test`/`tests` stanza's environment and dependencies, even when its include file
also declares sibling tests or alias actions. Alias actions run only when their
alias is selected; their settings do not belong to the named executable. A
per-suite file with no named test retains its rule-action handling. Unresolvable
variables in a directly evaluated environment remain errors.
If a named test declares a custom `action`, the targeted runner selects Dune's
nonrecursive `@@DIRECTORY/runtest-NAME` alias instead of the bare executable.
Dune owns that action's arguments, wrappers, variables and dependencies; the
runner does not translate them. The selected OCaml executables are built before
starting the alias timeout. For a Python suite declared as
`(rule (alias runtest-NAME) (deps ...) (action ...))`, the runner reads that
rule's `(deps ...)` and any `%{exe:...}` its action names, and builds those
before the alias timeout starts; the alias itself still runs inside the timeout.
A suite whose body really hangs therefore still ends as `TIMEOUT`, and one whose
body only needed compiling reaches `Ran N tests` instead of spending the whole
budget on the build. If the reader fails, the run names the alias, prints the
reason and falls back to building the alias inside its budget. These per-test
aliases have existed since Dune
3.20, below this repository's 3.22 minimum. See the
[Dune test reference](https://dune.readthedocs.io/en/latest/reference/dune/test.html).
To check this runner boundary without an OCaml build, run
`python3 -m unittest discover -s scripts/ci/tests -p test_targeted_stanza_isolation.py -v`.
Its shell-runner fixture substitutes the build command; it is not a product
test result. Keep this focused CI self-check separate from product behavior suites.

Reading a run's own log needs a writable cache directory. `gh run view RUN --log`
writes under `$HOME/.cache/gh`, so on a lane whose home is read-only it fails with
`mkdir /home/opam/.cache/gh: read-only file system` before fetching anything — an
error that looks like "the log is unreadable" but is only the cache path. Set
`XDG_CACHE_HOME` to a writable directory for the read, for example
`XDG_CACHE_HOME=/tmp/ghcache gh run view RUN --log`. A review that says a log line
could not be read should name which of the two failed: the fetch or the cache.

Reading one source file needs the same care. The Contents API returns an empty
`content` with `encoding: "none"` for a file above roughly 1 MB, so
`gh api .../contents/PATH --jq .content | base64 -d | grep -c SYMBOL` answers
`0` for a file it never read. `bin/masc_tui.ml` is 2.27 MB (41,703 lines), so
that path always reports zero there. Read the raw URL or `git show REF:PATH`,
and quote the input size beside any count — `lines=41703 grep=0` means the
symbol is absent, `lines=0 grep=0` means the read failed. A count on an empty
input is not evidence of absence.

Counting a long `Counter(...)` or argument list by eye is the same mistake in a
different shape. A failure message listed 17 keys over 98 requests; reading it
by eye missed `('setup', '/api/v1/dashboard/scheduled-automation'): 5`, and two
wrong hypotheses were built on "the path is absent". Extracting the keys and
summing them showed the schedule path present and — scoped to its phase — zero
after the test cleared its list, which was the actual finding. Parse the
structure and count it; do not scan it.

Dune runs suites in parallel, so a suite's `Ran N tests` / `Test Successful` line
is not the line that follows its own invocation. Taking the next result line
attributes another suite's summary to the one being read: a `test_mcp_server_eio`
block that failed at `test_mcp_server_eio.ml:3045` was read as
`Test Successful in 0.014s. 8 tests run.` from a different suite. Pair a summary
with its suite by the sandbox path (`_build/.sandbox/<hash>/...`) or by a name
inside the result block, never by adjacency.

A Python traceback lists the outermost caller first, so the frame to cite is the
last one, not the test function's own line. A failing
`test_failed_schedule_reads_are_read_again_with_growing_waits` showed
`line 143, in test_...` (the line that calls `run_schedules`) above
`line 131, in scenario`, where the `step(...)` wait actually timed out; citing
`:143` names the caller and the same number in a sibling file can mean something
else entirely. Cite the innermost frame with its file name.

The innermost frame is often not the line that reads like the cause. A `step(...)`
wait that timed out ended at `test_tui_schedules_signal.py:128` (`step(`), then
`test_tui_chat_owed_history.py:230` (`wait_until`), then `:220` (`self.fail`).
The label string sits on the line after `step(` and is not a frame at all —
citing `:131` named an argument, not a frame. Quote the call's first line and say
which frame you mean when the traceback crosses into a helper: the test's own
line shows the wait that was asked for, the helper's line shows where it failed.

A `.ml` pattern match alone is not the contract. `masc_tui_owed_read.ml` drops
`retry_at` when a change arrives while waiting, which reads like a discarded
backoff until the `.mli` says why: "A change while waiting out a failure is read
now … the failures in a row are kept, so the next failure still waits longer."
Read the `.mli` before calling a transition a defect — a value the `.ml` discards
is often one the interface documents as intentionally dropped, and a call that
looks redundant can be the caller's mistake rather than the callee's.

The release selection covers Keeper turn interrupt, chat HTTP/delivery identity,
MCP Task lifecycle and verification submission,
durable chat storage, Goal verification,
Memory continuity and the Schedule store's upgrade-sensitive format. Native
installation, server boot and dashboard payload consumers retain their existing
release jobs. Review changes to this list against the release's public claims.
TUI screen text, layout and row order are not release behavior, so the selection
contains no PTY scenario.

DOS/Play, voice, presentation generation and the remaining broad feature/visual
regressions remain available through explicit `workflow_dispatch` on the full Test path (`suite` empty,
`minimal: false` in `test.yml`). They are not silently skipped inside a run that
claims full coverage. Reproduce a behavior failure locally, fix it and pass the
same scenario before submitting another candidate; RC is the integration check,
not the first debugging loop. Historical receipts retain their original scope.

Prefer short, focused checks: the constitution's "about two minutes"
describes their intended scale, not a timeout or a pass/fail threshold.
Only an actual successful completion is build evidence.

A combined candidate receipt names that candidate and selected coverage. It does
not become an individual PR's check, an independent source approval or merge
permission. A source review does not establish a CI result; Release admission
still requires its current-head full verification evidence.

For real browser Addon checks, dispatch `browser-stagehand-proof.yml` with a full
`candidate_sha` and `browser=chromium`, `browser=firefox` or `browser=gecko`. The workflow builds
only that browser's scenario and its launcher, process guardian and worker. It
checks out the source candidate independently of the workflow ref; the artifact
records both commits and retains the four executables with their SHA-256 list.
Chromium exercises Stagehand on isolated private and persistent profiles. Firefox
uses a fresh private test workspace and persistent profile for trusted input,
in-flight detach, confirmed cleanup, fresh reattachment and stale-client refusal.
`gecko` selects owned Firefox through geckodriver for host-granted file upload,
late page reads after host snapshot release, actual download bytes and durable
download/screenshot artifacts after confirmed Addon retirement. Its fixture
payload reader is explicit host authority, not a Keeper sandbox authorization test.
All three scenarios use controlled loopback pages, never the operator's profile or signed-in
sites. Logs, scenario receipts and screenshots show only that selected execution;
they do not prove Safari parity, installed production behavior or full regression.

```bash
gh workflow run browser-stagehand-proof.yml --ref WORKFLOW_REF \
  -f candidate_sha=EXACT_SOURCE_SHA -f browser=firefox
```

Set `-f companion_checks=true` for a candidate containing the original-session
companion implementation. This additionally builds the server and executes the
Stagehand backend, extension companion, Unix broker, allocation cleanup,
worker protocol, original Keeper invocation retention and canonical publication
queue suites. The candidate must contain all seven fixtures; the worker protocol suite initializes the actual
package, while origin retention covers immutable source ownership and refuses
duplicate dispatch. The artifact records the selected build targets and
test names, retains individual test logs and packages the matching server.
After the complete selected build succeeds, binaries and their source/checksums
are retained before runtime checks. A later fixture failure therefore preserves
the build artifact without implying runtime success. Independent fixture commands
all run and record pipeline exit codes in `companion-results.tsv`; the step fails
if any command or log pipeline fails.
These fixtures use fabricated CDP/provider edges; the separate browser probe
still exercises its selected real browser. Neither proves real 1Password
approval, website authentication or Keeper continuation. Source and workflow
commits remain separate, and no account credentials are required by this scope.

CI catches concrete functional, compilation, schema, credential or resource
failures. Bulk source-style lints, prose rules, byte inventories, historical counts
and recursive checks about other checks are not release gates. Feature work
continues while verification runs; agents do not watch, wait or repeatedly poll.
The disabled hosted workflows are not enabled by editing these source definitions.

To publish a verified candidate after creating its version tag, use the same
commit's completed full RC run:

```bash
gh workflow run release.yml --ref vX.Y.Z -f rc_run_id=RUN_ID -f publish=true
```

The current-attempt receipt and the run's assembled distribution must remain
available. A failed-job rerun can reuse installation artifacts from an earlier
successful job in the same run. The exact RC-checked release body travels with
the receipt and is not regenerated at publication. Missing or expired artifacts require another RC; rebuilding inside the
publication job would no longer publish the bytes that were verified.
