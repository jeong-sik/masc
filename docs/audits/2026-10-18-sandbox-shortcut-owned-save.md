# Sandbox shortcut: fresh revision, owned save and visible outcome

Source baseline: `96ff2b4588d41db7a6de78add004be66a4e75912` (#43694).

## As-Is / To-Be / Before and After

| Sandbox `d/m/s` boundary | Baseline | This layer |
| --- | --- | --- |
| POST precondition | Sends only sandbox_profile; server requires expected_config_revision | Fresh config snapshot supplies the exact composite revision |
| Shortcut HTTP waits in input handling | Two | Zero |
| Logical save-chain HTTP calls, excluding final surface refresh | Two; the POST omits the required revision | Four for a change: workspace check, config read, workspace recheck, POST |
| Already matching observed profile | Still attempts POST | Three reads/checks, no POST; revision must still be valid |
| Request intent | Backend string lives in synchronous handler | Existing typed profile retained in an owned immutable request |
| Editor/shortcut overlap on one Keeper | Shortcut bypasses the new settings operation | Shares same-Keeper pending ownership; another key cannot rewrite admitted intent |
| Draft continuity | Separate shortcut has no relation to editor recovery | Shortcut preserves failed editor input; each input kind retires only its own older recovery |
| Visibility | Action after synchronous result | Profile-labelled checking/current-read/receipt/recovery notice and joined clocks |

These are source-derived contracts and counts, not measured performance. The
extra current read and workspace recheck repair missing write authority; they
are not a reduction in total network work. The final asynchronous Settings or
Sandbox surface refresh is additional in both paths and excluded from this
save-chain count. Existing HTTP authentication refresh policy may make further
physical requests. No runtime or painted speedup is claimed.

## Frozen intent and authoritative preparation

`Keeper_sandbox_config.sandbox_profile` is the existing neutral config-layer
SSOT; shortcut keys map explicitly to its three constructors. No parallel profile
list or string fallback is added. The request captures Keeper, workspace/read
identity and the absolute selected profile before suspending. It shares the
settings operation's pending, cancellation and atomic-receipt ownership. Independent
Keepers may own independent saves; one Keeper's editor and shortcut serialize.

The worker checks workspace identity, reads `/api/v1/keepers/:name/config`, prepares
the profile-only patch, then checks workspace/read identity again. The server's
snapshot is produced under its current-config-revision boundary and includes
both `sandbox_profile` and `config_revision`; the POST route requires that revision
before applying a patch. No cached pane, last saved revision or invented empty
revision substitutes for this read. Revision and observed profile must both decode,
even before reporting already-selected. Changing profiles sends only the requested
profile and that exact revision; network mode, remote endpoint and other settings
are not silently rewritten. Server validation and CAS remain authoritative.

The prepared immutable snapshot/optional patch accompanies posting and terminal
outcomes. `None` patch means a known matching observed profile, not failed parsing
or unknown write outcome. That outcome is a read observation and grants no write
receipt. Invalid/missing revision or profile stays not-sent. Refusal, conflict,
reconciliation, applied-but-runtime-sync-failed and unconfirmed outcomes retain
their existing distinction and original prepared evidence. No automatic retry or
profile cycling occurs. Only an explicit later key can create a fresh read/save.

Editor inputs remain separate from shortcut intent. A shortcut cannot erase a
failed editor draft or seed itself into `e` recovery. Same-origin pending requests
of either kind coalesce rather than race. After navigation/withdrawal, original
receipts still settle but cannot borrow new read authority. A visible refresh
requires current workspace/read identity, exact selected Keeper and the current
Settings or Sandbox tab; a late reply does not replace a different Keeper's pane.

The footer names the retained profile and current phase. Start, worker phase and
UI admission logs include typed intent identity and clocks; fast completions may
skip an intermediate UI phase while worker phase logs remain. Prepared JSON is
not logged. Existing executor cleanup, server CAS/reconciliation, HTTP timeouts,
external editor interaction and source ownership policy are retained. No new
timer, cap, environment variable, permission or live product change is introduced.

## Evidence and remaining goal

Three new feature/protocol scenarios are authored and **unexecuted**: exact
profile/revision patch with known no-write and invalid-revision refusal; shared
editor/shortcut pending ownership preserving retained editor recovery; frozen
shortcut preparation and unknown receipt surviving read withdrawal. Existing
editor scenarios are adapted to the common immutable request/preparation model.
They inspect retained state, decisions and the required API patch. No wording,
layout, row-order, snapshot-output or PTY test is added.

Only parser-only source checks, diff hygiene and changelog validation run. Types,
HTTP/feature/cancellation execution, independent current-head approval, CI,
installed binary, runtime, paint and speedup remain unverified. No live product
config, prompt, login file or runtime is read or changed. No own merge, install
or restart is performed.

The complete preparation/first-usable-input/readability/visibility/observability,
Ask-to-original-Task-to-useful-work, resource-owned ordinary/nested/dynamic/effectful
Composition, held-job/shared-backend and matched Before/After goal remains open.
Future comparisons retain failed, cancelled, interrupted and unfinished samples.
