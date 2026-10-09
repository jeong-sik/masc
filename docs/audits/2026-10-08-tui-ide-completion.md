# TUI IDE: unfinished user journeys and usefulness review

## Scope and evidence

Source baseline: `459d68148be82c506e50657f0d4e6cc5a9cbb2d7` (fetched main).
This is a bounded audit of the operator journey from a Keeper's work to its
files, recorded changes, context and results. It is not a census of every server
route or proof that every TUI screen works. Existing unrelated branches and the
shared checkout were preserved; repairs are an isolated four-PR stack.

The installed TUI reported `132e8d8a23d7503275ff82142890586dba6e79c5`.
A real PTY with synthetic HTTP responses reproduced the history failure:
[before frame and reproduction](../evidence/tui-history-20261008/README.md).
The local reproductions used installed before-change binaries; candidate CI
evidence is recorded below. Changed-source parsing
and Python syntax checks are not type checking, passing PTY behavior, deployment,
or live Keeper evidence.

## Assessment

The useful product is an operator workbench: find what a Keeper is doing,
understand a wait/failure, inspect its exact changes, and reach the task/result
that explains them. The source already has much of that information, but exposes
it through separate entrypoints with inconsistent recovery and follow-through.
It is premature to conclude that another top-level panel or a full editor would
solve the lack of visible information.

VS Code's [file Timeline and repository history](https://code.visualstudio.com/docs/sourcecontrol/history)
provide a useful comparison: a file is an entrypoint to its history and changes.
MASC can make that journey more useful by adding the producing Keeper, Task,
execution and attempted/applied distinction. This comparison motivates the
interaction; it is not evidence of MASC runtime behavior.

| Operator question | Current source path | Assessment and disposition |
|---|---|---|
| What needs my decision? | `masc_tui_home.ml:home_decision_rows`, Approvals and Goal confirmation | Already implemented; preserve explicit unread/failure states. A second summary screen would duplicate it. Real default-screen discoverability still needs observation. |
| What are the Keepers doing now? | Activity / `masc_tui_acting.ml`, turns/actions/everything filters | Useful live cross-Keeper view exists. It is a bounded session event feed, not complete durable history. Do not label it as a permanent audit trail. |
| What code changed in this repository? | Workspace `H` → activity, `v` → context, Enter → Code | Useful path exists. The fourth source slice removes the assignment filter: all loaded roster writers are read, then exact repository addresses are filtered. Deleted/unloaded Keepers remain excluded; this is not an all-time audit trail. |
| What happened to this file? | Code `H`, `masc_tui_code_requests.ml:launch_history_load` | Confirmed defect: Git failure prevented the independent Keeper read. First repair keeps successful source rows and names the failed source. |
| Can I recover after a history read fails? | Code `r` dispatch versus `H` cache reuse | Confirmed source gap: `r` refreshed only directory entries. First repair refreshes history sources while history is open. |
| What exactly did that Keeper call change? | History had metadata and Enter-to-line; Changes had recorded text | Follow-through gap: History `d` opened today's Git diff instead of the selected recorded call. Second repair expands the call's captured text in the timeline. It distinguishes failed attempts, replace-all calls, writes without before bytes and blobs without text. |
| Why did the Keeper change this file? | History Task/Turn/Execution metadata; Workspace activity context | Attribution exists, but History Enter handles only a commit PR link or a file-line jump. `t` now follows the exact recorded Task ID to its loaded detail and transition history, with Esc returning to the same file position. Missing/unread Tasks stay explicit. Deeper verifier-artifact navigation remains separate; no ownership is inferred from names or time proximity. |
| What notes are attached to this code? | `masc_tui_memo.ml`, Code `m`, comments in the opened file | Useful source-owned annotations exist in all scopes. The guide incorrectly promised repository-only note-store CRUD and a `w` form. Correct documentation; do not recreate a second store merely to match stale prose. |
| What context did the model receive? | `/context`, `masc_tui_context_inspector.ml`, recent request records | Already richer than a token counter: stack/request/proof views. Retain measured bytes, usage and provenance distinctions. No need for another generic context panel. |
| Is memory actually usable? | Memory health → fact browser; source-bound and ordinary stores | Existing drill-down is useful. Changes here must be coordinated with active memory work; no duplicate implementation in this stack. |
| Can I navigate code? | Code search, blame, hover, definition/references, external editor | Existing capability is enough for inspection. Embedded editing/LSP expansion should wait for demonstrated workflows; absent language servers must remain explicit errors. |
| Which roadmap entries are still unfinished? | `docs/design/tui/TUI-ROADMAP.md` | Its dated tables mix source-merged, historical assignments and unmeasured runtime completion. Use this audit as a current bounded ledger; an old “main” label does not prove the installed UI. |

## Implemented slices

1. [PR #41937](https://github.com/jeong-sik/masc/pull/41937): independent file-history reads and in-place retry. Keeps exact scope/path
   request admission, newest-first ordering and line ownership. Adds partial,
   both-failed and recovered source PTY scenarios at 60/120 columns.
2. [PR #41938](https://github.com/jeong-sik/masc/pull/41938): recorded call expansion in the existing timeline, without another API read
   or new top-level screen. Adds wrapped edit/write, failed-call and record-switch
   PTY scenarios. Corrects the memo guide to match the actual source reader.

3. [PR #41956](https://github.com/jeong-sik/masc/pull/41956): follow the selected
   recorded Task into its existing detail and event history, then return to the
   same file/history position. Missing/unlinked/unreadable destinations keep the
   history visible and state the reason.
4. [PR #41959](https://github.com/jeong-sik/masc/pull/41959): include every
   writer the shared fleet record holds for the 24-hour window in repository
   Activity, including unassigned, deleted and unloaded Keepers. Exact repository-ID
   filtering and partial read failures remain explicit. Installed before-change
   omission reproduced in [this fixture PTY](../evidence/tui-writer-coverage-20261008/README.md).

## Behavior-check progress

- [Run 37784992989](https://github.com/jeong-sik/masc/actions/runs/37784992989),
  candidate `b20ca3b3916cf7d3e85a24327636ed47017561d8`, built and ran the TUI.
  Existing full-metadata/row-owner History layout suite passed. New source-read
  and recorded-diff suites failed: the readiness needle crossed a wrapped
  Keeper name, and a failed-call fixture carried completed line evidence.
  The first failure frame actually showed Git failure and preserved Keeper
  metadata; this is partial behavior evidence, not a suite PASS.
- Those fixture contracts and no-op navigation waits were repaired at
  `f8c01a88cf32453a1fc5458c5da308844e1f98f5`, with independent source review.
  [Run 37786877449](https://github.com/jeong-sik/masc/actions/runs/37786877449)
  requests only the two failed suites. Its result is not assumed here.
- [Run 37786669895](https://github.com/jeong-sik/masc/actions/runs/37786669895)
  requests the Task-follow and repository-writer PTY suites at
  `2c807b739f13d8d82e8ac4dba9776442f4bdec99`. Its result is not assumed here.
- No binary installation or live Keeper behavior claim. Independent subagent
  source verdicts do not substitute for formal current-head GitHub approval.

The PTY cases are authored regression scenarios. They are not marked passing
until executed against a binary built from these changes. Source review verdicts
are separate from formal GitHub approval and release verification.

## Next useful work and acceptance

- Repository activity coverage: the fourth source slice reads the shared fleet
  record once, so every writer recorded in the 24-hour window is included,
  whether unassigned, deleted or unloaded. The installed before-change TUI
  omission was reproduced in a real fixture PTY. History older than the window
  still needs a durable inventory API before broader coverage can be claimed.
- Task/result follow-through: the direct Task-detail and return path is now
  implemented in the third source slice. It includes task status, completion
  notes, handoff/contract evidence references and transition history. Actual
  verifier artifact content remains on Task Review, not a claim of this link.
  New-binary PTY verification remains pending.
- Discoverability: measure the actual Dashboard → Keeper → changed file →
  recorded diff → Task/result path on a narrow and wide terminal. A help entry
  or hidden palette destination alone is not proof the information is findable.
- Execute the focused history PTY suites and capture the resulting frames from
  the exact candidate binary, then separately decide installation. Existing live
  sessions retain their original executable.

Deferred: multi-Keeper simultaneous chat streams, composite execution trees and
new editor panels. These require an observed operator workflow and current
producer data; unfinished roadmap text alone is insufficient justification.
