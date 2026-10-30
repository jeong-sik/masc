# PR review response — 2026-10-04

Native stack #41118 contains #41104, #41106, #41107, #41108, #41109,
#41110, #41113, #41115, #41116, and #41117, in that order, targeting main.
The response addresses 21 inline review findings (one P1 and twenty P2).
Source integration head before this evidence-only commit:
`61ebf334bc852ed7a2bd569013de1ebc76938676`.

| PR | Resulting behavior |
| --- | --- |
| #41104 | Filesystem failures retain HTTP 503 classification; obsolete rollback path removed; setup exposes durability and sanitized observed lock-release warnings; clients preserve committed state and display uncertainty. |
| #41106 | Raw source remains readable on model projection errors; inline/dotted structured edits are refused explicitly; model form honors viewport height. |
| #41107 | Reviewed existing account reselection and schema boundary claims; selected existing accounts reuse their provider identity. No response code change needed. |
| #41108 | Closing login retains independent account activation receipts; reopening resumes without repeating setup. Configuration reads are single-flight with queued explicit refreshes. |
| #41109 | Complete usage snapshots persist omissions, including empty snapshots. HTTP accounts and USD scopes are reachable in dashboard rendering. |
| #41110 | Historical Context navigation does not reload the runtime catalogue on each keypress. |
| #41113 | Unreadable decision logs produce unavailable/incomplete Runtime history; enumerated files open strictly, including dangling links and denied stat paths. |
| #41115 | Pending model entry cannot edit retained rows; successful saves queue Runtime rereads; missing declarations open their raw source for repair. |
| #41116 | Viewport-aware summaries preserve listing space; account scope and connection ID are distinct. |
| #41117 | Discovery and inventory use effective account homes consistently; selectable group representatives and refreshed removal choices use current membership. |

## Validation boundaries

On the integrated source above:

- Six dashboard test files: **97/97 passed**; TypeScript `tsc --noEmit` passed.
- Installer `RuntimeSetupAdapter`: **20/20 passed**.
- OCaml syntax parsed for 49 changed `.ml` and 21 changed `.mli` files;
  Python syntax parsed for 13 changed files. Diff whitespace and tracked-secret
  checks passed.
- Native execution of unchanged production config-launcher and completion
  scheduling excerpts passed slow cadence, queued intent, workspace withdrawal,
  and failed old-read cases. This is not an integrated TUI execution.

Earlier focused executions covered model-form 7 cases, usage history 2 cases,
metrics 48 cases, history presentation 4 cases, and account login 33 cases.
Later strict decision-file reads, multi-account recovery, and lock-warning
propagation received source/parser and focused excerpt/frontend checks;
those earlier suite results do not certify the later integrated native binary.
The shared prebuilt OCaml dependency cache disappeared during response work.
No local Dune rebuild or full build was performed to replace it.

PTY regressions were authored/updated for source-read isolation, missing binding
repair, activation close/reopen, Context request counts, and short runtime
viewports. They were not executed against a newly built TUI. Browser E2E fixture
syntax was checked; browser E2E was not executed. The running server and TUI
binary were not deployed or restarted as part of this PR response.

Independent source readers reviewed the focused changes and rebase integration.
Source PASS is not a GitHub approval, CI result, merge, or deployment.
The minimum manual workflow is requested separately on the published leaf;
its actual result belongs to that run and SHA.
