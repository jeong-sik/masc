# TUI Smoothness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce allocation-driven GC pauses during chat scrolling without changing any rendered content or interaction semantics.

**Architecture:** Remove per-position closure allocation in OpenGraph substring search, then reuse the chat timeline index only when both immutable source lists are unchanged. Keep all caches derived, bounded by their existing owners, and physically keyed to immutable inputs.

**Tech Stack:** OCaml 5.5.1, Alcotest, existing TUI PTY/frame/allocation profilers, GitHub targeted behavior checks.

**Spec:** `docs/research/tui-frame-cost-and-terminal-output-prior-art-20261104.md` and the 2026-11-04 live measurements under `artifacts/tui-sse-smooth-20261104/`.

## Global Constraints

- Do not change terminal text, row order, source identity, scroll ownership, or request behavior.
- Do not add dependencies, timing gates, numeric runtime control flow, or screen-wording tests.
- External coding sessions do not run local Dune builds. Use explicit targeted remote behavior checks and exact-source native artifacts.
- Performance claims require before/after measurements on the same live workspace; test or call counts alone are not performance evidence.

## Review Focus

- Empty substring and search past the end must retain their current answers (Task 1 boundary tests through `parse_og_html`).
- Metadata far into a large body must still be found while scanned-byte allocation falls (Task 1 allocation test).
- A changed visible list must rebuild the timeline index even when the committed message list is unchanged (Task 2 identity test).
- An unchanged pair of lists must return the same index without losing request-row association (Task 2 existing generated-row comparison).
- Cached values must never become a second authority for messages or preview data (Tasks 1–2 existing projection comparisons plus PTY behavior).

---

### Task 1: Allocation-free OpenGraph substring search

**Files:**
- Modify: `bin/masc_tui_link_preview.ml`
- Test: `test/test_tui_link_preview.ml`

**Interfaces:**
- Consumes: existing public `parse_og_html : url:string -> body:string -> og_preview`.
- Produces: unchanged parser result and public interface; no new test-only product API.

- [ ] **Step 1: Write the failing allocation test**

Add `test_parse_og_without_metadata_does_not_allocate_per_scanned_byte`. Parse a 100,000-byte body with no metadata, assert `has_metadata = false`, and require measured `Gc.allocated_bytes` for that call to be below 400,000 bytes. Current per-position closure creation exceeds it; the fixed search keeps only the parser's fixed allocations. Keep the existing deep-metadata and single/name-quote cases as behavior coverage.

- [ ] **Step 2: Verify RED on the test-only head**

Commit only the test and plan, push the branch, then run:

```bash
gh workflow run test.yml --repo jeong-sik/masc \
  --ref perf/tui-link-preview-allocation-20261104 \
  -f suite=test_tui_link_preview -f minimal=true
```

At the work boundary, read the actual run once. Expected: the new case FAILs on allocated bytes; existing cases pass.

- [ ] **Step 3: Implement the minimal allocation fix**

Move substring-at-a-position matching out of the per-index loop in `index_sub`, so recursive matching does not allocate a fresh local closure for every candidate byte. Do not alter empty-substring, negative-start, or no-match behavior.

- [ ] **Step 4: Verify GREEN and allocation improvement**

Run the same targeted suite on the new head. Then run the live allocation profiler with the same chat scenario and compare `bin/masc_tui_link_preview.ml:256` and total estimated words with the before capture.

- [ ] **Step 5: Commit the implementation**

```bash
git add bin/masc_tui_link_preview.ml test/test_tui_link_preview.ml
git -c core.hooksPath=/dev/null commit -m "perf(tui): stop allocating for every OpenGraph search position"
```

### Task 2: Reuse an unchanged chat timeline index

**Files:**
- Modify: `bin/masc_tui_types.ml`
- Modify: `bin/masc_tui_render_chat.ml`
- Test: `test/test_tui_chat_queue_wiring.ml`

**Interfaces:**
- Consumes: `chat_timeline_index : messages:msg_entry list -> visible:(msg_entry * float option) list -> chat_timeline_index`.
- Produces: the same index values and associations; physical reuse only when `messages` and `visible` are physically unchanged.

- [ ] **Step 1: Write the failing identity test**

Extend the existing generated-row timeline comparison. Assert repeated construction for the same two lists returns a physically identical index, then change only `visible` and assert both recomputation and the same associations as a fresh index.

- [ ] **Step 2: Verify RED**

Run `test_tui_chat_queue_wiring` on the test-only head. Expected: the physical-reuse assertion fails before memoization while generated-row value comparisons pass.

- [ ] **Step 3: Implement bounded one-entry memoization**

Cache only the latest `(messages, visible, index)` beside `chat_timeline_index`. Compare both lists physically. Do not retain across different inputs and do not use mutable contents as authority.

- [ ] **Step 4: Verify GREEN and frame improvement**

Run the targeted suite, then the exact-source native TUI artifact through `scripts/tui-frame-latency.py --scenario chat` against the same live workspace. Compare Build p50/p95/max and allocation with the before run.

- [ ] **Step 5: Commit the implementation**

```bash
git add bin/masc_tui_types.ml bin/masc_tui_render_chat.ml test/test_tui_chat_queue_wiring.ml
git -c core.hooksPath=/dev/null commit -m "perf(tui): reuse the unchanged chat timeline index"
```
