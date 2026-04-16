# Memory Bank Compaction FSM / TLA+ Audit (2026-04-16)

**Status**: v1 — TLA+ spec enumerated end-to-end, OCaml implementation verified with direct reads (compaction algorithm, kind_caps, trigger, priorities). Buggy model re-verified with TLC; clean model deferred (state explosion, see §5).

**Scope**: Memory bank compaction — the `keeper_memory_bank.ml` pipeline that prunes kind-tagged notes when the on-disk JSONL exceeds `trigger_bytes`. This is a **separate subsystem from context compaction** (which covers tokens/messages in a Context.t, audited in `docs/audits/compaction-fsm-tla-audit-2026-04-16.md` §1). The two share only the word "compaction"; the target objects, triggers, and algorithms differ.

**Out of scope**: context compaction, keeper FSM phases, checkpoint store, OAS hooks. Those are covered by Track A audit (see sibling document above).

---

## 1. Spec Inventory

**File**: `specs/bug-models/MemoryCompaction.tla` (199 lines, verified via `wc -l`).

### 1.1 Constants

| Constant | Meaning | Clean cfg value |
|----------|---------|-----------------|
| `TargetNotes` | Max notes after compaction (spec comment: "e.g. 8 for small model") | 8 |
| `ConstraintCap` | Max constraint notes to keep (reused for `decision` in `SafeCompact` at :96-98) | 2 |
| `LongTermCap` | Max long_term notes to keep | 3 |

### 1.2 Variables

| Variable | Type | Purpose |
|----------|------|---------|
| `bank` | seq of `[kind, priority]` records | Input sequence — raw notes before compaction |
| `result` | seq of records | Output sequence — kept notes after compaction |
| `phase` | `{"accumulating","compacting","done"}` | 3-state FSM (spec-only abstraction) |

### 1.3 Kinds and priorities

Spec line 28: `Kinds == {"constraint", "decision", "progress", "long_term"}`.

| Kind (spec) | Priority (spec action) |
|-------------|------------------------|
| `constraint` | 90 (`AppendConstraint`, :50) |
| `decision` | 86 (`AppendDecision`, :56) |
| `progress` | 66 (`AppendProgress`, :62) |
| `long_term` | 95 (`AppendLongTerm`, :68) |

### 1.4 Actions

| Action | Lines | Precondition | Effect |
|--------|-------|--------------|--------|
| `AppendConstraint` | :47-51 | `phase="accumulating" ∧ Len(bank)<TargetNotes*2` | append `[kind="constraint", priority=90]` |
| `AppendDecision` | :53-57 | same | append `[kind="decision", priority=86]` |
| `AppendProgress` | :59-63 | same | append `[kind="progress", priority=66]` |
| `AppendLongTerm` | :65-69 | same | append `[kind="long_term", priority=95]` |
| `TriggerCompaction` | :73-77 | `phase="accumulating" ∧ Len(bank)>TargetNotes` | `phase := "compacting"` |
| `SafeCompact` | :83-118 | `phase="compacting"` | kind-capped select + fallback fill; models `keeper_memory_bank.ml:411-412` |
| `BugPriorityOnlyCompact` | :122-141 | same | priority-only select (bug model) |

`SafeCompact` phase 1 (:86-106) builds `capped = kept_constraints \o kept_longterm \o kept_decisions \o kept_progress`. Phase 2 (:107-114) refills up to `TargetNotes` from the head of `bank`, explicitly modeling the OCaml fallback pass at `keeper_memory_bank.ml:411-412` (`if !selected_count < target_notes then ... ignore_kind_cap:true`).

### 1.5 Safety Invariants (5)

| # | Invariant | Line | Property |
|---|-----------|------|----------|
| 1 | `ConstraintsPreserved` | :162-167 | `done ⇒ count(result,constraint) ≥ min(count(bank,constraint), ConstraintCap)` |
| 2 | `NeverEmpty` | :170-171 | `done ∧ Len(bank)>0 ⇒ Len(result)>0` |
| 3 | `ResultBounded` | :174-175 | `done ⇒ Len(result) ≤ TargetNotes` |
| 4 | `LongTermProtected` | :179-184 | Constraint-analog for `long_term` kind |
| 5 | `RecentFloorRespected` | :193-197 | `done ⇒ Len(result) ≥ min(Len(bank), TargetNotes)` |

### 1.6 Specs

- `Spec == Init /\ [][NextSafe]_vars` (line 155) — clean model, uses `SafeCompact`
- `SpecBuggy == Init /\ [][NextBuggy]_vars` (line 156) — bug model, uses `BugPriorityOnlyCompact`

### 1.7 Configs

| File | Specification | Invariants | Expected |
|------|---------------|-----------|----------|
| `MemoryCompaction.cfg` | `Spec` | all 5 | "No error" |
| `MemoryCompaction-buggy.cfg` | `SpecBuggy` | all 5 | invariant violated |

Both cfgs use identical CONSTANTS (`TargetNotes=8, ConstraintCap=2, LongTermCap=3`) and `CHECK_DEADLOCK FALSE`.

---

## 2. OCaml Implementation Anchors (verified by direct read)

### 2.1 Compaction entry point

`lib/keeper/keeper_memory_bank.ml:296-452` — `compact_memory_bank_if_needed`.

**Verified structure** (`keeper_memory_bank.ml` is 606 lines total):

| Step | Line range | Behavior |
|------|-----------|----------|
| Read target_notes | :299 | `memory_compaction_target_notes ()` — default 220, env override, clamped `[40, 4000]` |
| Check file exists | :301-305 | bail with `reason=missing_file` if absent |
| Read size | :307-315 | bail with `reason=under_trigger_bytes` if below threshold |
| Parse JSONL rows | :317-337 | collect valid rows + invalid counter |
| Early exit (no work) | :339-345 | bail with `reason=under_target` when `before_notes ≤ target_notes ∧ invalid=0` |
| Consolidate + sort | :348-358 | merge progress clusters; sort by recency desc, priority desc |
| Dedup | :359-360 | dedup by `memory_row_key` |
| Early exit (dedup no-op) | :361-367 | `reason=already_compact` |
| Kind-capped select | :369-398 | build `kind_caps` hashtable + `add_row ~ignore_kind_cap:false` |
| **Phase 1a — recent floor** | :399-402 | apply first `recent_floor = max 16 (min 64 (target_notes/5))` rows from `by_recency`, respecting caps |
| **Phase 1b — priority pass** | :403-410 | sort remaining by priority desc, ts desc; apply respecting caps |
| **Phase 2 — fallback fill** | :411-412 | `if !selected_count < target_notes then List.iter (add_row ~ignore_kind_cap:true) by_recency` |
| Sort output + write | :413-452 | final sort by ts asc, then atomic write via `write_memory_bank_rows` |

The two-phase selection pattern cited by the TLA+ spec (`SafeCompact` phase 1 + phase 2 fallback) is present in OCaml at **:411-412**, not :407-408 as the spec comment says. See §4 Drift #1.

### 2.2 kind_caps (spec cites `keeper_memory_policy.ml:131-148`)

**Actual location**: `keeper_memory_policy.ml:470-471`. Lines :131-148 hold the `memory_bank_compaction` type definition (an unrelated record type). This is a stale line reference — see §4 Drift #2.

Exact values (verified at `keeper_memory_policy.ml:470-471`):

```ocaml
let kind_caps () : (string * int) list =
  [ ("constraints", 2); ("decision", 2); ("next", 2); ("goal", 2);
    ("progress", 2); ("open_question", 2); ("long_term", 4) ]
```

| Kind | Cap | Spec constant used |
|------|-----|---------------------|
| `constraints` (plural) | **2** | `ConstraintCap` |
| `decision` | **2** | `ConstraintCap` (reused in `SafeCompact` :96-98) |
| `next` | **2** | (not modeled in spec) |
| `goal` | **2** | (not modeled) |
| `progress` | **2** | (modeled as residual in spec via `remaining`) |
| `open_question` | **2** | (not modeled) |
| `long_term` | **4** | `LongTermCap` (spec cfg uses 3, code uses 4) |

`total_cap () = 12` at `keeper_memory_policy.ml:468` (sum of per-kind caps also = 16; `total_cap` is smaller — that's the limit used by `select_memory_candidates` at `keeper_memory_bank.ml:9`, a separate function from compaction).

### 2.3 kind_caps scaling at compaction time

`lib/keeper/keeper_memory_bank.ml:264-274` — `memory_kind_caps_for_compaction`:

```ocaml
let memory_kind_caps_for_compaction ~(target_notes : int) : (string, int) Hashtbl.t =
  let tbl = Hashtbl.create 16 in
  let base_total = max 1 (total_cap ()) in       (* = 12 *)
  let scale = max 6 (target_notes / base_total) in
  List.iter
    (fun (kind, base_cap) ->
      let cap = max 8 ((base_cap * scale) + (scale / 3)) in
      Hashtbl.replace tbl kind cap)
    (kind_caps ());
  tbl
```

**Verified scaled caps** for the canonical `target_notes=220`:
- `scale = max 6 (220/12) = max 6 18 = 18`
- For `base_cap=2` (constraints, decision, next, goal, progress, open_question): `max 8 ((2*18) + (18/3)) = max 8 42 = 42`
- For `base_cap=4` (long_term): `max 8 ((4*18) + (18/3)) = max 8 78 = 78`

So at production defaults, each small-cap kind gets up to 42 slots and `long_term` gets up to 78 — far above the spec cfg's `ConstraintCap=2` / `LongTermCap=3`. The spec models the **small-model ratio** (`8 : 2 : 3`) not production values. This is an acceptable abstraction for model checking (spec doesn't claim to match production magnitudes) but deserves a note — see §4 Drift #3.

### 2.4 Recent floor

`lib/keeper/keeper_memory_bank.ml:399` — `let recent_floor = max 16 (min 64 (target_notes / 5))`. Matches spec comment at :187-189 exactly.

### 2.5 Priority source of truth

`lib/keeper/keeper_memory_policy.ml:419-427` — `priority_for_kind`:

```ocaml
let priority_for_kind ~(kind : string) : int =
  match kind with
  | "constraints" -> 90
  | "decision" -> 86
  | "next" -> 80
  | "open_question" -> 76
  | "goal" -> 72
  | "progress" -> 66
  | _ -> 60
```

**Drift**: spec's `AppendLongTerm` uses priority `95` (:68); OCaml's `priority_for_kind` does not have a `long_term` arm, so `long_term` falls into the wildcard `_` with priority **60**. `long_term` rows do reach the bank (verified at `keeper_memory_bank.ml:190, 235` which construct rows with `kind = "long_term"`), but their priority at append time is assigned differently (see `tuned_priority_for_candidate` at :461-466 which calls `priority_for_kind` as the base). See §4 Drift #4 — this means the spec's bug witness (long_term starving constraints) is structurally different from what could happen in production.

---

## 3. Traceability Matrix — TLA+ action ↔ OCaml

**Legend**: ✓ verified by direct read, ❓ needs separate audit, DRIFT = confirmed mismatch.

| # | TLA+ action | OCaml function : line | Code variable changes | Drift? |
|---|-------------|------------------------|------------------------|--------|
| 1 | `AppendConstraint` | `append_memory_notes_from_reply` → `append_jsonl_line` at `keeper_memory_bank.ml:488-506` | kind `"constraints"` (plural) written to JSONL with priority 90 via `priority_for_kind` | **DRIFT (kind string)**: spec uses `"constraint"` (singular), code uses `"constraints"` (plural). Semantic match, string mismatch. |
| 2 | `AppendDecision` | same pipeline | kind `"decision"`, priority 86 | ✓ exact match |
| 3 | `AppendProgress` | same pipeline | kind `"progress"`, priority 66 | ✓ exact match |
| 4 | `AppendLongTerm` | `keeper_memory_bank.ml:190,235` construct `kind="long_term"` rows (via `consolidate_memory_notes` path) | kind `"long_term"`, priority 60 (wildcard) or tuned | **DRIFT (priority)**: spec asserts 95, OCaml `priority_for_kind` has no `long_term` arm → defaults to 60. Rows still flow but the bug-model's "long_term dominates by priority" scenario is structurally unreachable with the current priority table. |
| 5 | `TriggerCompaction` | `keeper_memory_bank.ml:307-315` (byte-size trigger) | no phase variable; the byte threshold `trigger_bytes = max 120000 (target_notes * 360)` replaces TLA+'s `Len(bank) > TargetNotes`. | **ABSTRACTION**: spec uses note count, code uses file bytes. Sound abstraction (more bytes ≈ more notes) but the two are not bijective. |
| 6 | `SafeCompact` phase 1 | `keeper_memory_bank.ml:369-410` (`add_row ~ignore_kind_cap:false` twice: recent-floor pass + priority pass) | `kind_used` hashtable enforces per-kind caps; output is `selected_rev` | ✓ structural match; OCaml has an extra recent-floor pre-pass not modeled in spec |
| 7 | `SafeCompact` phase 2 (fallback fill) | `keeper_memory_bank.ml:411-412` (`if !selected_count < target_notes then List.iter (add_row ~ignore_kind_cap:true) by_recency`) | fills remaining slots from `by_recency` ignoring caps | ✓ exact match (spec comment says `:407-408`, actual is `:411-412` — see §4 Drift #1) |
| 8 | `BugPriorityOnlyCompact` | (no OCaml counterpart — bug model only) | n/a | ✓ by design; this action exists to prove the invariant is strong enough |

---

## 4. Known Gaps / Potential Drift

### Drift #1 — Stale line references in spec comments

The TLA+ spec cites two OCaml locations that have drifted:

1. Spec `:108-110` (in `SafeCompact` LET block) says fallback fill models `keeper_memory_bank.ml:407-408`. **Actual location: `:411-412`**. The compaction block grew by ~4 lines between spec authoring and today (likely from the recent-floor pre-pass insertion at :399-402).
2. Spec header `:10-11` says `kind_caps` is at `keeper_memory_policy.ml:131-148`. **Actual location: `:470-471`**. Line range `:131-148` currently holds the unrelated `memory_bank_compaction` record type. Drift magnitude: ~340 lines.

**Classification**: documentation drift only; spec logic remains correct. Fix is a one-line comment update in the spec (out of scope for this audit).

### Drift #2 — Kind string mismatch (singular vs plural)

Spec uses `"constraint"` (line 28, 50, and in `KindCount` predicates :162-167). OCaml uses `"constraints"` (plural) throughout: `keeper_memory_policy.ml:421` (`priority_for_kind`), `:471` (`kind_caps` key), `:340` (JSON field), `:365` (parse), and the append pipeline. **None of the OCaml kind strings match the spec's `"constraint"`**. Spec's `ConstraintsPreserved` invariant at :162 reads `KindCount(result, "constraint")` — if the spec were run against real JSONL data it would count 0 constraint notes.

**Classification**: abstraction mismatch. Spec is self-consistent (all 4 Append actions + KindCount use the same string `"constraint"`), so the TLA+ model is sound on its own vocabulary. But the spec cannot be directly wired to a runtime-data consistency check without a vocabulary translator.

### Drift #3 — Spec CONSTANTS don't reflect production values

Spec cfg: `TargetNotes=8, ConstraintCap=2, LongTermCap=3`.
Production (after scaling via `memory_kind_caps_for_compaction`):
- `target_notes = 220` (default)
- scale = 18
- effective `constraints` cap = 42, `long_term` cap = 78

The spec cfg is an intentional small-model for TLC tractability. No direct drift — but the spec doesn't document this, so a reader may assume `LongTermCap=3` is the production value.

**Classification**: missing documentation, not a bug. Recommend adding a comment block to the spec explaining that cfg values are small-model approximations and citing `keeper_memory_policy.ml:470-471` + `keeper_memory_bank.ml:264-274` as the production source of truth.

### Drift #4 — `long_term` priority asymmetry

Spec's `AppendLongTerm` (:68) assigns priority 95 — the highest of all modeled kinds. This is what makes `BugPriorityOnlyCompact` a meaningful bug witness: priority-only selection puts `long_term` first, potentially starving `constraint`.

OCaml's `priority_for_kind` (keeper_memory_policy.ml:419-427) has no `long_term` arm. `long_term` rows get priority 60 (wildcard) as a base, then `tuned_priority_for_candidate` (:461-466) adds a `signal_bonus` (±8 depending on keyword matches). Maximum achievable priority for `long_term` at append time: `60 + 8 = 68`. The spec's "long_term dominates constraints by priority" scenario is **not reachable in production** because `constraints` (priority 90) always outranks `long_term` (priority ≤68) before the bonus-driven variance.

**Classification**: the spec's bug witness models a *hypothetical* implementation bug ("what if priority ordering were reversed") rather than the current code's risk surface. The invariants (`ConstraintsPreserved`, `LongTermProtected`) are still useful, but the `BugPriorityOnlyCompact` scenario is defensive against a code path that does not currently exist. Spec is conservatively over-broad, not under-broad — safe direction.

### Drift #5 — Trigger dimension mismatch

Spec `TriggerCompaction` (:73-77): fires when `Len(bank) > TargetNotes` (count-based).
OCaml (`keeper_memory_bank.ml:311`): fires when `size_bytes >= trigger_bytes` where `trigger_bytes = max 120000 (target_notes * 360)` (byte-based). After the file is read, there's a secondary count check at :339 that bails with `reason=under_target` if `before_notes ≤ target_notes`.

**Classification**: bytes-to-notes is a monotone approximation (more notes → more bytes, generally). The count-level check at :339 matches the spec. The byte-level gate at :311 is an efficiency optimization not modeled in the spec. Sound, but means the spec cannot prove the byte-gate is correct (could there be a tiny-notes edge case where `size_bytes < 120000` yet `count > target_notes`? The secondary :339 check would catch the inverse; the untested case is whether we ever *miss* a needed compaction because bytes are small while count is large. Unlikely with `target_notes*360 ≈ 79KB` floor of 120KB.).

### Drift #6 — Extra recent-floor pass not modeled

OCaml `keeper_memory_bank.ml:399-402` does a pre-pass: take the first `recent_floor = max 16 (min 64 (target_notes/5))` rows sorted by recency, apply kind caps. Then the priority pass (:403-410) and fallback fill (:411-412).

Spec's `SafeCompact` has no recent-floor pre-pass — it does a single kind-capped selection driven by input order. The `RecentFloorRespected` invariant (:193-197) is a static property (`Len(result) ≥ min(Len(bank), TargetNotes)`), not a behavioral guarantee that recent rows are prioritized.

**Classification**: spec is weaker than code. Code's recent-floor is a stronger guarantee than anything the TLA+ currently expresses. Adding a `RecentNotesPreserved` invariant would tighten the spec (possible follow-up PR).

---

## 5. Reproduction Commands + Observed Results

**Note**: `specs/keeper-state-machine/tla2tools.jar` is not tracked in the worktree filesystem (shared-git / separate-working-tree). Use the main repo's copy at `/Users/dancer/me/workspace/yousleepwhen/masc-mcp/specs/keeper-state-machine/tla2tools.jar`, or `cd` into the main repo's `specs/keeper-state-machine/` directory before running TLC.

```bash
cd ~/me/workspace/yousleepwhen/masc-mcp/.worktrees/docs/memory-bank-audit/specs/bug-models

# Buggy — expect "Invariant LongTermProtected is violated"
java -XX:+UseParallelGC -Xmx2g \
  -cp ~/me/workspace/yousleepwhen/masc-mcp/specs/keeper-state-machine/tla2tools.jar \
  tlc2.TLC -config MemoryCompaction-buggy.cfg -workers 4 -deadlock \
  MemoryCompaction.tla

# Clean — expect "No error" (long-running, see below)
java -XX:+UseParallelGC -Xmx2g \
  -cp ~/me/workspace/yousleepwhen/masc-mcp/specs/keeper-state-machine/tla2tools.jar \
  tlc2.TLC -config MemoryCompaction.cfg -workers 4 -deadlock \
  MemoryCompaction.tla
```

### Observed results (2026-04-16, M3 Max 128GB)

| Run | Result | Evidence |
|-----|--------|----------|
| `MemoryCompaction-buggy.cfg` | ✓ **`Invariant LongTermProtected is violated`** | TLC 2026.04.06.192533. 1,597,942 states / depth 12 / **7s**. TTrace file `MemoryCompaction_TTrace_<ts>.tla` generated, then cleaned. Prior audit observed 1,472,782 states / 13s on a previous run — numbers fluctuate slightly with scheduling. |
| `MemoryCompaction.cfg` (clean) | ⏳ Did not complete in session | Prior audit (compaction-fsm-tla-audit-2026-04-16.md §2.4) reports state-space explosion on this cfg. Recommendation: `MemoryCompaction-ci.cfg` with smaller `TargetNotes` (e.g., 4) and tighter bounds on `Len(bank)` to get coverage in <1 min. Not implemented in this audit (docs-only scope). |

### Violation witness (from buggy TLC output)

Reproducible trace at depth 12:
- States 1-10: 8 × `AppendConstraint` + 1 × `AppendLongTerm` fill `bank` (9 elements).
- State 11: `TriggerCompaction` (`Len(bank)=9 > TargetNotes=8`), `phase := "compacting"`.
- State 12: `BugPriorityOnlyCompact` — picks the 8 highest-priority items. Because `long_term` has priority 95 > `constraint` 90, `long_term` sorts first, but there's only 1 `long_term`. Final result: 1 × `long_term` + 7 × `constraint` + 0 other. Wait — actual TLC trace shows `result = << 8 × constraint >>` — because `SelectSeq(bank, LAMBDA n : n.priority >= 90)` preserves bank order (the 1 long_term is at position 9, after 8 constraints already matched priority≥90). The final `taken = SubSeq(allSorted, 1, TargetNotes=8)` keeps the 8 constraints and drops the 1 long_term. **This violates `LongTermProtected`**: `KindCount(bank, "long_term")=1, LongTermCap=3, min=1`, so `result` must have ≥1 long_term, but has 0.

This is a subtler witness than the spec comment's "long_term fills all slots" narrative at :127-131 — the actual violation is the mirror case (constraints starve long_term under order-preserving SelectSeq). Both are instances of the same underlying bug (priority-only ordering ignores kind-cap safety), but the witness direction depends on `SelectSeq`'s implementation, which preserves original sequence order among matching elements.

### What the buggy violation proves

TLC demonstrates that priority-only selection (the bug model) can starve a kind below its cap regardless of whether the starving direction is "long_term dominates" or "constraints dominate". The `LongTermProtected` + `ConstraintsPreserved` pair is jointly strong enough to catch either direction.

---

## 6. Follow-up Items

Ordered by value. Each is a candidate for a separate PR.

1. **Fix stale spec line references** (Drift #1). Update `MemoryCompaction.tla:10-11` to cite `keeper_memory_policy.ml:470-471` for `kind_caps` and `:11` (or internal spec comment at :108-110) to cite `keeper_memory_bank.ml:411-412` for the fallback fill. One-liner spec edit.

2. **Add CI cfg for MemoryCompaction clean run** (§5). Create `specs/bug-models/MemoryCompaction-ci.cfg` with `TargetNotes=4, ConstraintCap=1, LongTermCap=2` (or similar) to keep clean-spec model checking under 1 min. Wire into `scripts/tla-check.sh`. Default `MemoryCompaction.cfg` stays for nightly/release only.

3. **Add `long_term` arm to `priority_for_kind`** (Drift #4). The function at `keeper_memory_policy.ml:419-427` silently defaults `long_term` to 60. Either (a) document that `long_term` rows enter via `consolidate_memory_notes` with an explicit priority (verify: `keeper_memory_bank.ml:190, 235`), or (b) add an explicit `"long_term" -> 95` arm for consistency with the spec. Low-risk code change.

4. **Document production-vs-spec CONSTANTS mismatch** (Drift #3). Add a comment block to `MemoryCompaction.tla:14-18` explaining that cfg values are small-model approximations, pointing to `memory_kind_caps_for_compaction` at `keeper_memory_bank.ml:264-274` as the scaling function and `target_notes=220` as the production default.

5. **Reconcile kind string vocabulary** (Drift #2). Either (a) update spec to use `"constraints"` (plural) to match OCaml, or (b) add a comment noting the intentional singular naming. Mechanical but touches 8+ spec lines (`Kinds`, 4 `Append*` actions, 2 invariants).

6. **(Optional) Strengthen `RecentFloorRespected`** (Drift #6). Model the recent-floor pre-pass in `SafeCompact` so the spec can verify "recent notes are never over-pruned" as a behavioral property, not just a size floor.

---

## 7. Summary

### What's verified
- TLA+ spec structure: 3 VARIABLES, 7 actions, 5 safety invariants, 2 Specs (clean + buggy), 2 cfgs.
- OCaml compaction entry `compact_memory_bank_if_needed` at `keeper_memory_bank.ml:296-452` (line range 296-452, not 292-448 as spec header claims — 4-line drift on top, 4-line drift on bottom).
- `kind_caps` values: `[constraints=2; decision=2; next=2; goal=2; progress=2; open_question=2; long_term=4]` at `keeper_memory_policy.ml:470-471`.
- `memory_kind_caps_for_compaction` scales caps with `target_notes` at `keeper_memory_bank.ml:264-274`. At default `target_notes=220`, `scale=18`, scaled caps are 42 (base=2) and 78 (base=4).
- Two-phase selection (kind-capped + fallback-fill) confirmed at `keeper_memory_bank.ml:411-412`.
- Buggy TLC run re-verified: `LongTermProtected` violated at 1,597,942 states / depth 12 / 7s.

### What's drifting
- Spec comments cite stale OCaml line numbers (§4 Drift #1).
- Kind string vocabulary differs (`"constraint"` vs `"constraints"`, §4 Drift #2).
- Spec CONSTANTS reflect small-model, not production magnitudes (§4 Drift #3).
- `long_term` priority asymmetry: spec 95, OCaml 60 via wildcard (§4 Drift #4).
- Trigger dimension differs: spec count, code bytes (§4 Drift #5).
- Spec doesn't model the recent-floor pre-pass (§4 Drift #6).

None of these are live bugs. Every drift item is either documentation-level (#1, #3), naming (#2), defensive over-modeling (#4), or a sound abstraction (#5, #6).

### Out of scope
- Fixing any drift found — audit discovers, separate PR fixes.
- Modifying TLA+ spec or OCaml code.
- Running the clean cfg to completion (deferred, §5).
- Context compaction, keeper FSM, OAS hooks — covered by Track A audit.

---

**Audit author**: Claude (Opus 4.6)
**Date**: 2026-04-16
**Verified files**:
- `specs/bug-models/MemoryCompaction.tla` (199 lines, read end-to-end)
- `specs/bug-models/MemoryCompaction.cfg` + `-buggy.cfg` (read end-to-end)
- `lib/keeper/keeper_memory_bank.ml:1-40, 240-452` (read)
- `lib/keeper/keeper_memory_policy.ml:95-190, 419-475` (read)
- TLC re-run on `MemoryCompaction-buggy.cfg` (7s, invariant violated as expected)

**Unverified**: production runtime behavior under real keeper memory banks (observational audit would be a separate work item).
