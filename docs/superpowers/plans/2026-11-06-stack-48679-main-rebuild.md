# Stack 48679 Current-main Rebuild Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebase the complete two-PR SSE stack onto current `main` without replaying 235 commits or losing either current-main behavior or the reviewed SSE behavior.

**Architecture:** Preserve both original heads with local backup refs. Build a squashed, non-ancestry merge of the parent tree onto `origin/main`, resolve the 85 conflicted paths once, and commit server, TUI, and retained documentation changes separately. Reset the child onto the rebuilt parent and apply only the original parent-to-child Play room patch with a three-way apply; maintain and publish the existing Native Stack with `gh stack`.

**Tech Stack:** Git/GitHub Native Stacks, OCaml 5.5 sources, existing Alcotest/Python PTY suites, targeted remote checks.

**Spec:** `docs/superpowers/plans/2026-11-04-tui-sse-lanes.md`, `docs/superpowers/plans/2026-11-04-tui-sse-remaining.md`, `docs/rfc/RFC-0480-tui-reads-when-the-server-says-something-changed.md`, and `docs/evidence/tui-play-room-sse-20261105/README.md`.

## Global Constraints

- Preserve original parent `4479aab8c1719d78ce2d4de193366d9c5887074c` and top `f949d0ceafb073f4676e199abb4c3ad5cca1dc92` under backup refs before resetting a branch.
- Use `origin/main` `ca77d69515536a582e75594c9d0fa018b7fc3acb` or a newly fetched explicit head as the new base; never merge `main` or another PR into a stack branch with merge ancestry.
- Keep the existing Native Stack #48679 and PRs #48677/#48678; publish both layers once with `gh stack push`, using its per-branch leases.
- No local Dune build, CI watch/wait loop, production installation, merge, or `~/me/.masc` modification. Use `git -c core.hooksPath=/dev/null commit` for commits.
- Do not claim Browser backend-native events, installed runtime behavior, or visible human UI verification from PTY results.

## Review Focus

- Main-side concurrent refactors must survive alongside SSE producers/consumers; inspect every three-way conflict against stages 1/2/3 and run the final source review.
- Add/add dataset and fixture files must become one coherent contract, not duplicated event names or Dune registrations; final `@check` and behavior suites cover this.
- Deleted changelog fragments already consumed by main must not reappear merely because the old branch edited them; inspect modify/delete resolutions explicitly.
- Play room changes must apply on the rebuilt parent without changing tool-vs-Observer presence ownership; rerun `test_play_room` and `test_server_play_room_events`.
- Reconnect, visibility, private Add-on delivery, and pending trailing reads must retain their contracts; rerun the existing selected regression and native PTY measurements on the new head.

---

### Task 1: Preserve and rebuild the parent on current main

**Files:**
- Modify: every conflict reported by `git merge-tree --write-tree --name-only origin/main origin/feat/lane-inventory-announce`.
- Preserve: original refs only; no production runtime files.

**Interfaces:**
- Consumes: original parent/top heads and the explicit `origin/main` head.
- Produces: a clean `feat/lane-inventory-announce` whose direct parent history starts at current `main`, with no merge commits.

- [ ] **Step 1: Record the fixed input identities and backup refs**

Run `git status --short`, `git rev-parse origin/main origin/feat/lane-inventory-announce origin/feat/play-room-sse`, and create `backup/stack-48679-lane-original` plus `backup/stack-48679-top-original`. Expected: clean tree and both backup refs exactly matching the original heads above.

- [ ] **Step 2: Start a squash merge without ancestry**

Switch to `feat/lane-inventory-announce`, reset it to `origin/main` only after the backups verify, then run `git merge --squash backup/stack-48679-lane-original`. Expected: the previously measured 84 unmerged paths; no merge commit.

- [ ] **Step 3: Resolve every conflict from the three stages**

For each path inspect `git show :1:path`, `:2:path`, and `:3:path` plus current source context. Preserve current-main interface changes and the SSE behavior from the spec. For add/add files produce one implementation; for the four consumed changelog fragments retain main's deletion. Stage only the intended resolution.

- [ ] **Step 4: Verify the complete resolved working tree**

Run `git ls-files -u`, `git diff --check`, and search for conflict markers. Expected: no unmerged entries, whitespace errors, or conflict markers. Review all automatic merges in the files touched by current main before committing.

- [ ] **Step 5: Commit server, TUI, and documentation groups**

After all conflicts are resolved, unstage the tree with a mixed reset while preserving working files. Stage `lib/` server/producer files and their non-TUI tests first, then `bin/`, `lib/tui_decode*`, dashboard clients and TUI tests, then retained docs/changelogs including this plan. Use the prescribed hook bypass. Expected: current `main` is an ancestor, no merge commits, and no uncommitted source remains.

### Task 2: Rebuild the Play room child on the new parent

**Files:**
- Modify: only paths in `git diff --name-only backup/stack-48679-lane-original..backup/stack-48679-top-original`, plus any textual conflict caused by main-side resolutions.

**Interfaces:**
- Consumes: rebuilt parent and original `git diff --binary` from original parent to original top.
- Produces: `feat/play-room-sse` containing current main, rebuilt parent, and the Play room production/evidence delta.

- [ ] **Step 1: Apply the original child delta**

Switch to `feat/play-room-sse`, reset it to the rebuilt parent after confirming the top backup, and run `set -o pipefail; git diff --binary backup/stack-48679-lane-original..backup/stack-48679-top-original | git apply --3way --index`. Expected: original Play room delta applies; resolve any contextual conflicts without reverting main or parent changes.

- [ ] **Step 2: Commit the Play production and evidence groups**

Commit Play room server/presence/TUI/tests separately from retained evidence updates. Expected: no conflict markers, no unmerged entries, `git diff --check` succeeds, and no merge commits exist above `origin/main`.

- [ ] **Step 3: Verify ancestry and conflict elimination**

Run `git merge-base --is-ancestor origin/main feat/play-room-sse`, `git merge-tree --write-tree origin/main feat/play-room-sse`, and `git merge-tree --write-tree feat/lane-inventory-announce feat/play-room-sse`. Expected: ancestor exit 0 and both merge-tree commands exit 0 with no conflicted paths. Compare the old and new parent-to-child file sets and inspect any difference caused by current-main overlap.

### Task 3: Publish and verify the rebuilt Native Stack

**Files:**
- Update: PR #48677/#48678 descriptions and retained evidence only when new-head results exist.

**Interfaces:**
- Consumes: locally rebuilt branches.
- Produces: current remote heads, stack mergeability, fresh source verdicts, and exact-head behavior evidence.

- [ ] **Step 1: Restack and push through Native Stack tooling**

From the top branch run `gh stack rebase --no-trunk`, then `gh stack push`. Re-read REST PR/stack metadata immediately. Expected: both new heads match local, direct bases remain correct, stack base is current main, and no lower-only push occurred.

- [ ] **Step 2: Dispatch exact-head checks without waiting**

Run `gh workflow run pr-type-check.yml --ref feat/play-room-sse`; run targeted `test.yml` suites for Play room, Observer, Lane, Memory, Skill, replay/privacy and spectators; run the full `test.yml` regression; and dispatch `pr-check.yml` with `native-tui-source-sha=<new-top-head>` and the applicable native scenario. Record actual run IDs and heads at a work boundary; do not poll or watch.

- [ ] **Step 3: Repeat native request measurements**

Using the new exact-source macOS artifact, run the documented `measure_suite_requests.py` command for `test_tui_play_room_push PlayRoomPushTest` and the same spectator case as the previous evidence. Expected: no periodic Play Read, trailing exactly 2, hidden 0, source-loss/reconnect revalidation, and unchanged spectator request contracts. Preserve binary SHA-256, embedded build commit, raw counts, and limits.

- [ ] **Step 4: Obtain independent current-head reviews and update the PRs**

Review the complete new parent and child diffs for function, state/failure logic, and cleanliness. Request independent reviews for both current heads; do not self-approve. Update descriptions and evidence only with actual new-head results, then re-read review `commit_id`, FAIL/HOLD, comments, Draft state, and mergeability before reporting readiness.
