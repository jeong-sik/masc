# TUI SSE Lane Inventory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the two-second Lanes and Lane Add-ons Inspect reads with server change notifications, single-flight owed reads, and reconnect revalidation.

**Architecture:** Extend the existing `workspace_dataset_changed` closed type with `Lanes` and `Lane_addons { instance_id }`. Publish after the Lane runtime's durable state convergence, then make the TUI owe only the visible inventory or matching open Inspect read. Preserve the existing generation, retry, draft, and workspace-withdrawal ownership.

**Tech Stack:** OCaml 5.5.1, existing SSE runtime, Alcotest, Python PTY fixtures, targeted remote checks.

**Spec:** `docs/rfc/RFC-0480-tui-reads-when-the-server-says-something-changed.md` §3.1–3.4 and §4.1.

## Global Constraints

- SSE carries freshness, not a replacement authority. Reads use the existing `/api/v1/lanes` and `/api/v1/lane-addons` paths.
- No polling fallback, new environment variable, screen-wording assertion, or local Dune build.
- Preserve detached history, private instance visibility, pending actions, open drafts, and workspace withdrawal.
- Do not emit a dataset for every worker commit without checking the actual Lanes/Inspect read can change.

## Review Focus

- A commit for instance A must not reread open instance B's Inspect (Task 2 scoped PTY case).
- A failure after durable publication but before notification is recovered by reconnect revalidation (Tasks 1 and 2 existing observer epoch coverage).
- A second notification while a read is in flight produces exactly one trailing reread (Task 2 single-flight case).
- Leaving an Inspect pane drops its debt; returning starts a fresh read without replaying stale actions (Task 2 visibility case).
- Workspace withdrawal clears in-flight and owed reads without discarding declarations or action receipts (Task 2 withdrawal case).

---

### Task 1: Typed Lane dataset publication

**Files:**
- Modify: `lib/workspace_dataset_event.ml`
- Modify: `lib/workspace_dataset_event.mli`
- Modify: `lib/lane_addon/lane_addon_runtime.ml`
- Test: `test/test_lane_addon_actions.ml`
- Test: `test/test_tui_observer.ml`

**Interfaces:**
- Produces: `Lanes | Lane_addons of { instance_id : string }`, wire names `lanes` and `lane_addons`, and optional `instance_id` on the latter.
- Consumes: the existing durable `persist` commit boundary and `Sse.subscribe_external` observation.

- [ ] **Step 1: Write failing producer and decoder tests**

Assert an actual Add-on attach/commit announces `lanes` and `lane_addons` with the attached instance ID. Assert observer frames decode as owed datasets and reject a missing or blank instance ID. Tests use `dataset_name` and `of_fields`, so they compile before the constructors exist and fail for missing behavior.

- [ ] **Step 2: Verify RED**

Run `test_lane_addon_actions` and `test_tui_observer` on the test-only head. Expected: no Lane dataset is announced and observer frames are undecodable.

- [ ] **Step 3: Implement typed encoding and publication**

Add both constructors, names, optional `instance_id` encoding/decoding, and exhaustive matches. Announce only after `persist` has converged mutable state and woken dependents, including after-rename uncertain durability with its typed failed state. No notification on a before-rename failure with no visible commit.

- [ ] **Step 4: Verify GREEN**

Run the same two suites. Confirm commits announce their own instance, malformed identities remain unreadable, and cancellation is not swallowed.

- [ ] **Step 5: Commit**

```bash
git add lib/workspace_dataset_event.ml lib/workspace_dataset_event.mli \
  lib/lane_addon/lane_addon_runtime.ml test/test_lane_addon_actions.ml test/test_tui_observer.ml
git -c core.hooksPath=/dev/null commit -m "feat(sse): announce Lane inventory changes"
```

### Task 2: Scoped owed reads in the TUI

**Files:**
- Modify: `bin/masc_tui_types.ml`
- Modify: `bin/masc_tui.ml`
- Test: `test/test_tui_lane_inventory_push.py`
- Modify: `test/dune`

**Interfaces:**
- Consumes: `Observer.Dataset_changed (Lanes | Lane_addons { instance_id })` from Task 1.
- Produces: single-flight Lanes and visible Add-on Inspect reads with existing retry/backoff and workspace ownership.

- [ ] **Step 1: Write failing PTY request tests**

Serve observer pushes and actual read endpoints. Assert `lanes` rereads `/api/v1/lanes` only on Lanes, and `lane_addons` rereads Inspect only when that instance is open. Include in-flight trailing debt, hidden pane, failed-read retry, and withdrawal cases; assert request paths and counts, never screen text.

- [ ] **Step 2: Verify RED**

Run the PTY fixture against the test-only native TUI. Expected: pushes cause no requested reread.

- [ ] **Step 3: Implement owed-read state and event handling**

Add `Masc_tui_owed_read.t` slots for Lanes and visible Add-on reads, map events to those slots, and launch/settle through existing generation and retry paths. Preserve current pending-action status reads and all modal/draft ownership.

- [ ] **Step 4: Verify GREEN**

Run the PTY fixture and affected Lane/observer suites. Confirm trailing, hidden, failed, and withdrawn reads retain their contracts.

- [ ] **Step 5: Commit**

```bash
git add bin/masc_tui_types.ml bin/masc_tui.ml test/test_tui_lane_inventory_push.py test/dune
git -c core.hooksPath=/dev/null commit -m "feat(tui): read Lane inventory on server changes"
```

### Task 3: Remove the remaining Lane cadence and measure

**Files:**
- Modify: `bin/masc_tui.ml`
- Modify: `docs/rfc/RFC-0480-tui-reads-when-the-server-says-something-changed.md`
- Evidence: `artifacts/tui-sse-smooth-20261104/`

- [ ] **Step 1: Replace the two-second branches**

Remove only the Lanes and Lane Add-ons periodic read branches after Tasks 1–2 pass. Keep startup, explicit `r`, reconnect revalidation, pending-action status, and non-Lane timers unchanged.

- [ ] **Step 2: Run request and lifecycle regressions**

Run `test_tui_lane_inventory_push`, `test_tui_lane_addons`, `test_lane_addon_application`, `test_tui_observer`, and `test_lane_addon_actions` on the resulting head.

- [ ] **Step 3: Measure the actual read rate**

Run the exact-source TUI against the live workspace for a fixed idle interval and a controlled Lane change. Record no periodic `/api/v1/lanes` or Inspect reads, then exactly one read per visible change, with reconnect revalidation.

- [ ] **Step 4: Commit**

```bash
git add bin/masc_tui.ml docs/rfc/RFC-0480-tui-reads-when-the-server-says-something-changed.md
git -c core.hooksPath=/dev/null commit -m "refactor(tui): remove Lane inventory polling"
```
