# Curator live-contract resolution on the owner fiber

The captured-prompt renderer repair is necessary but did not finish the real
Curator pipeline. These are observations of source
`cb2eeb1d271a0a436e34133e58ceda0c9a7b6efd`, before the follow-up eligibility
repair in this PR. No new fixture result is promoted into a passing host run.

## Actual execution results

- [Selected run 39721673539](https://github.com/jeong-sik/masc/actions/runs/39721673539)
  completed with 30/38 cases passing across five suites. The production-owner
  suite passed 7/15; cases 0/1/2/3/6/7/11/12 timed out with
  `Eio_guard.Non_eio_mutex_context(0)`. Its original timeout and assertions were
  preserved. Both idle-subscription cases and all nine prompt-registry cases
  passed. `selected-failure-excerpt.txt` preserves original selected log lines.
- [Native run 39721677397](https://github.com/jeong-sik/masc/actions/runs/39721677397)
  built the matching macOS server, TUI and key generator and passed the two
  selected application/TUI suites, 29 cases. The workflow source is
  `22528b6437bc2ba877255c61bc294736222a37fc`; the feature source is cb2 above.
  `native-receipt.json` and `actual-health.json` retain their distinct identities.
  Those suites do not execute the production Curator owner.

## Same-workspace provider observation

Only the task-owned private host was stopped normally and replaced with the
downloaded cb2 server and TUI. The original workspace, Keeper candidate,
Librarian commit, current Memory bytes, package and state volume were retained.
The Dashboard was built from a clean detached cb2 checkout; its real emitted
build identity matches the server. Operator processes and installations were
not replaced.

Normal Dashboard On activation admitted the original existing fact. The actual
configured GLM route answered classification and briefing; neither answer was
injected. The source-matched worker program/protocol is unchanged from the
previous 1196 qualification and uses the same task-owned immutable image.

- Classification original `01a161e3-eff3-7000-a4b8-aa8ef80fe89c` reached
  `commit_observed` and `observer_completion_recorded`. The actual ledger has
  one classified fact and one shared claim. Its completion ACK digest is
  `1666010e8237d36bf292ed0e53ac3b81667dc6da4ac140fa742a78ae82bb366b`.
- Briefing original `01a161e4-2a50-7000-965e-934e89c4a2cb` retained the real
  provider answer and `commit_intended`, but its domain state remains building
  with no published briefing. The actual host logged the same guarded mutex
  exception. `originals-after-model-results.json` retains the original captures,
  answers, before/after intentions and observer events.
- Normal Dashboard Off then removed the owned running container. The original
  classification and pending briefing journals remain in
  `originals-after-Off.json`; the current Memory hash is still
  `619fa8737bed6d1b38e0d7e903a9fd1562f4ef6aedcae5b9fc60e19207151c85`.
  The empty `owned-docker-Off.txt` is the actual task-image-filtered `docker ps`
  output, and `off-inventory.json` retains the API observation. Off is worker
  cleanup, not a completed briefing.

The PNG is an actual server-backed Dashboard view. `native-package-Off.txt`
contains actual native PTY cells from the matching TUI, not a desktop screenshot
or a screen-layout assertion. Visible worker state is separate from original
domain completion. File hashes and bounded claims are in `receipt.json`.

## Follow-up source change and remaining work

`Server_workspace_memory_addon.eligible` previously ran a live
`briefing_contract` callback inside its disk worker. That callback calls
`Prompt_registry.resolve_prompt`, which owns an Eio mutex. Both domain settlement
and successor-frontier observation reached it. Pure captured rendering did not
remove this separate live-resolution edge.

The follow-up resolves the current contract on the caller Eio fiber at each
required eligibility check and sends only its immutable value to disk work.
Classification does not resolve an unrelated briefing prompt. An already applied
after-state still confirms its original commit without borrowing today's prompt.
Recovery and frontier regressions use the actual registry and original domain
state; the production-owner fixture keeps guards enabled.

The follow-up source has not yet been executed in these receipts. Confirming the
retained briefing while Off without another model request, subsequent On/new
work, immutable original receipts, both UIs and final integration/installation
remain required. This is partial progress on the unchanged A01–H06 worklist,
not completion of E02 or the 54-task goal.
