# Type-check required rollout — 2026-11-10 record and stage-2 plan

## The gap this closes

On 2026-11-10 five merges reached `main` without a green PR-side type-check:

- #50746 merged 10:48:19Z with a red `type-check` (head `4e9758c7`, check-runs
  total=5, one failure).
- #51157 merged 16:56:24Z with no type-check context at all (check-runs total=1).
- #51161 merged 17:32:38Z with `type-check` still `in_progress`.
- #51155 merged 17:40:58Z with a red `type-check` (stale merge ref — the failure
  coordinates were the two main compile errors already closed by #51159/#51161).
- #51149 merged 17:52:39Z with a red `type-check` (head `d1db91c3`, check-runs
  total=9, one failure). It put two compile errors into `main`:
  `keeper_chat_operation_store.ml:3367-3371` (warning 4, fragile match on
  `Keeper_native_call.state`) and `keeper_owner.ml:3101` (type mismatch). `main`
  built red at 17:53:23Z and 18:39:59Z, and #51166 closed both coordinates;
  `main` built green again at 19:26:02Z (run 42883579983, head `840321a4`).

All five were possible because `main` had **no required status checks**: a red
or missing check never blocked a merge that had two approvals.

## Stage 1 (landed in #51155)

`.github/workflows/pr-type-check.yml` moved its `paths:` filter from the
workflow trigger to the job level, so every pull request gets both contexts:

- `changes` — captures the changed-file list. Fail-closed: an API failure fails
  the job rather than yielding a quiet skip. `pull-requests: read` granted;
  `changed_files >= 3000` folds to `src=true` (over-limit counts as source).
- `type-check` — skipped when `changes.outputs.src` is false, but the context
  still exists on every PR.

## Stage 2 (this document is the probe)

Order, per operator answer c1 (ask `aske1aa44782fd05693`):

1. This docs-only PR observes the contexts: `changes` success with `src=false`,
   `type-check` skipped.
2. Ruleset 26823705 ("Two approvals for main") then registers
   `changes` + `type-check` **as a pair**.
3. This PR's mergeability after that registration measures whether a skipped
   check satisfies `required` — the property stage 1 exists to provide.

## Known adjacent gap (tracked separately)

`github-actions[bot]` merges do not fire the push-triggered Main minimal build
(human-account merges fire it in 3–5 s; same-instant queue was empty). Interim
rule: any keeper observing a bot merge dispatches the build immediately
(`workflow_dispatch`, ref=main — run 42867165587 is the worked example). A
separate PR will make `approval-auto-merge` do this itself.
