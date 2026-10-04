# Account, Lane and Runtime audit — 2026-10-04

The live catalogue repair is applied. The source/UI repairs are submitted as a
reviewable stack. This is not a release or a claim that every provider and every
new TUI interaction has been executed successfully.

## Live repair

The workspace is `<workspace>/.masc` under the server's verified effective base.
The saved file contained 89 bindings, but the active registry exposed 83; all six
Codex bindings (two account homes, three models each) were absent. An unsupported
`supports-reasoning-budget = false` capability key made the current typed parser
reject the configuration. A private backup was retained, exactly that one key
was removed, and the existing authenticated preview/write API applied the file.
Readback confirmed all 89 runtimes and six Codex bindings. The later read still
has six Codex runtimes and two quota scopes. Its only subsequent TOML change was
`tui.last_chat_keeper`; the repair was not overwritten.

The original source SHA256 was
`d8667b00856f3bb830f244207406dcb5b686f1eec276679ef69693947d42f7dd`;
the repaired source immediately after save was
`24a90184d85656058745731664d0a8cb56b2bd7a35bd88a6c23ea15cb9844e79`.
No account was reauthenticated, no model inference was purchased for this check,
and no new server/TUI binary was deployed. Raw configuration, auth tokens, and
uncropped live captures remain private and are not included here.

## Findings and resulting behavior

| Requested behavior | Finding and repair | Evidence boundary |
|---|---|---|
| Subscription model registration | Provider identity included model settings, splitting one account into model-specific connections. New registration groups by typed transport/account; variants retain separate context and model settings. | Native setup contract tests; batch/server cases authored. Existing #41104 publishes saves into the live registry. |
| Existing account groups | Legacy provider IDs must remain valid for routes. Inventory now supplies account groups without renaming IDs; deletion requires choosing the actual provider connection. | Native inventory/login tests and frontend picker tests. |
| Copy and edit variants | Models index lost shared model bindings across accounts and only opened TOML. Typed one-row-per-binding projection and structured `e` edit / `c` copy support independent variants. | Native parser/render/form tests, including Ollama context synchronization and inline-table refusal. |
| Runtime/Lane account visibility | Provider connection IDs were presented as accounts. Runtime, standalone pickers and Context use the response's authoritative account scope and retain the connection ID separately. | Source review and pure helper assertions; new integrated UI not run. |
| Login activation | Save receipt alone did not complete setup/resume or refresh the live catalog. TUI now validates activation and retries only activation after failure. | Native login state tests; new activation PTY cases authored. |
| Usage and currency | Dollar credit usage lost its original amounts; silent accounts disappeared; account changes did not refresh readers. USD values/caps remain typed and catalog publication restarts declared-account readers. | Native snapshot and focused frontend tests plus producer/consumer typechecks. |
| Usage percent direction | Remaining fractions/counts are normalized at ingestion; all UI bars say Used, from 0% unused to 100% spent. Missing measurements remain unknown. | Source inspection of percent/fraction/count adapters; focused UI tests. |
| Removed rate/credit limits | Complete provider responses were merged like sparse events; empty successful reads were skipped. Full HTTP/Antigravity snapshots now replace their own windows, including empty reports; older snapshots cannot restore removed caps. | Three native lifecycle cases; final producer guard fix source reviewed, added producer regression not claimed executed. |
| Status alignment and narrow terminals | Fixed 22-cell status column clipped even at 132 columns. Rows share measured width; selected account and combined restrictions wrap in a counted summary. | Old-binary failure reproduced; new geometry/132/80 PTY cases authored, not executed on rebuilt TUI. |
| Success, cache and original specs | Keeper lifetime totals did not establish selected-runtime history. Authenticated asynchronous metrics join exact executed Runtime IDs; display last/recent successes, coverage, paired cache input share and recorded cost. Current catalog limits and declarations remain distinct; absent native-client catalog data stays unreported. | 46 producer + 3 projection tests; source review of cache/auth/identity boundaries. |
| Standalone model editing | Model-order editor opened source instead of the structured model form. Enter/d now opens the exact selected account/model form; Runtime detail e does the same. Async request identity prevents stale responses consuming a newer selection. | Exact-ID native lookup and source review; delayed-response PTY cases authored. |
| Candidate order and chat Context | Context next-request band now shows full order, account and configured context for each exact current runtime. Captured historical turns retain their own identity and evidence. Existing standalone J/K and 1 act within HTTP/CLI groups. | 26 focused Context cases; latest standalone old-binary scenario stopped on a version mismatch, not counted as a pass. |

## Evidence

- `checks.json`: scope, count, source/binary identity, executor and limitations.
- `live-readback.json`: sanitized last live census.
- `installed-tui.json`: identity of the installed TUI used for live captures.
- `live-runtime-catalog.txt`, `live-usage.txt`: text replay of the old installed
  binary's real PTY, cropped to the main pane. These are not images of the new UI.
- `log-manifest.json` and the named `.txt` files: bounded existing native test transcripts.
- `stack.json`: published branch/PR snapshot before the final evidence-only commit.
  The PR pages carry current head identities.

Focused native tests compiled only changed modules against existing cached
OCaml 5.5.1 dependencies. No Dune/full local build, CI watch, full CI or deployment
was performed. Parent and reviewer-agent results are identified separately;
source review is not an independent GitHub approval.

## Remaining integration evidence

The ordinary source stack needs independent current-head GitHub review before
integration. Concurrent companion #41114 guards raw configuration saves with
source revisions and retains drafts; when the stacks meet, the structured form
writer must pass the revision from its own fresh read and preserve its typed
conflict handling. That separate PR is not included in this stack. A rebuilt TUI/server pair still needs its new login, grouped-account,
model edit/copy, USD and 80/132-column PTY scenarios executed together. Fresh
provider invocation and reported usage from each live account are not proved by
the restored runtime count. The installed binaries remain older than this stack.
