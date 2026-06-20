---
rfc: "0268"
title: "Prompt ↔ Closed-sum Variant Sync Gate"
status: Draft
created: 2026-06-20
updated: 2026-06-20
author: vincent
supersedes: []
superseded_by: null
related: ["0153", "0266", "0088"]
implementation_prs: []
---

## 1. Problem

The 2026-06-20 adversarial prompt audit (10-dimension × audit+verify) found that
keeper-facing prompts (`keeper.unified.system.md`, `keeper.world.md`,
`keeper.capabilities.md`) contain **zero** mentions of the `turn_reason` (then 11
variants) and `skip_reason` (7 variants) closed sums defined in
`lib/keeper_contract/keeper_world_observation_turn_types.ml` and wire-serialized
via `*_to_string`. A keeper cannot reason about *why its turn ran or was skipped*
from the prompt alone (audit §2.2, §2.5).

This is the **hand-maintained mirror of code** anti-pattern: prompt markdown is a
human-edited mirror of the OCaml closed sum, with no derivation and no drift
gate. Variants were added (`Entropic_oscillation`, `Task_backlog`,
`Task_reactive_cooldown_elapsed`) without prompt updates; PR #21685 removed
`Entropic_oscillation` from code, again with no prompt involvement.

## 2. Background

masc already ships `scripts/check-variants.sh` (`make check-variants`), a
CI-gated cross-language variant sync checker (Meta-issue #9518, "VAR bug class").
It compares three representations:

- OCaml variant sets — `extract_ocaml_type` / `extract_ocaml_all_list`
- TypeScript union types — `extract_ts_union_type`
- TLA+ domain literals — `extract_tla_set_literals`

via `check_pair` (sorted `comm` diff). CI runs it
(`.github/workflows/ci.yml`, step "Check keeper variants"; wrapper
`scripts/ci/check-tla-variant-sync.sh`).

Check 1-4 cover: keeper `phase`, `turn_phase`, `runtime_state`,
`PHASE_STYLES`. **Prompt markdown is not a checked representation.**

## 3. Design

Add prompt markdown as a checked representation. Two parts.

### 3.1 Canonical prompt section (the mirror)

Add a canonical, machine-extractable section to the live keeper prompt listing
the exhaustive closed-sum wire names. Convention: a tagged fenced block so
`check-variants.sh` can extract the comma-separated wire names:

```
<!-- @variant-sync turn_reason -->
Reasons your turn may run (exhaustive set; scheduler-side, you do not choose):
mention_pending, board_event_pending, scope_message_pending,
scheduled_autonomous_turn, idle_cooldown_elapsed, cooldown_elapsed,
task_backlog, task_reactive_cooldown_elapsed, never_started, min_interval_elapsed

<!-- @variant-sync skip_reason -->
Reasons a turn may be skipped (scheduler-side gates):
keeper_paused, approval_pending, scheduled_autonomous_disabled,
provider_cooldown_pending, idle_gate_pending, cooldown_pending, no_signal
```

Placement: `keeper.unified.system.md` — the live system prompt (audit §2.3;
`keeper.world.md` is a dead/bootstrap prompt, addressed by the path-consolidation
RFC). Optional echo in `keeper.capabilities.md` for the tool-surface-relevant
subset.

### 3.2 Extraction + check (the gate)

Extend `scripts/check-variants.sh` with:

- `extract_prompt_variant_block <file> <tag>` — pull the comma-separated wire
  names between `<!-- @variant-sync <tag> -->` and the next blank line.
- `extract_ocaml_to_string <file> <fn>` — pull the `"..."` literals from a given
  `*_to_string` function (the canonical wire-name set the keeper observes in
  telemetry/decision logs).
- **Check 5**: `OCaml(turn_reason_to_string)` ↔ `prompt(turn_reason block)`.
- **Check 6**: `OCaml(skip_reason_to_string)` ↔ `prompt(skip_reason block)`.

`check_pair` reports drift (variant in code but not prompt, or vice versa). CI
already invokes `check-variants.sh`, so the gate goes live with **no new CI
wiring**.

### 3.3 Source of truth

OCaml `*_to_string` is the SSOT — it is the wire encoding keepers actually
observe. The prompt block is the derived mirror. The drift gate enforces
one-directional derivation: editing the prompt block cannot drop a variant the
code still emits, and adding a code variant without the prompt block fails CI.

## 4. Scope

**Phase 1 (this RFC):** `turn_reason`, `skip_reason`. Highest value — they answer
the audit's core question ("why did/didn't my turn run") and are the largest
drift surface (11 + 7 variants). Both have a 1:1 constructor ↔ wire-name mapping,
so extraction is unambiguous.

**Deferred (Phase 2, follow-up `Check N`):**

- `keeper_cycle_channel` (`Reactive | Scheduled_autonomous`) — only 2 variants,
  but `Reactive` wire-serializes as `"turn"` (RFC-0020). Needs a documented
  name↔wire mapping in its block, so excluded from Phase 1 to keep the extractor
  simple.
- `board_stimulus_kind`, `wake_reason`, `stimulus_payload` — same pattern;
  each is a future `Check N` once Phase 1 lands.

## 5. Alternatives

| Alt | Tradeoff |
|---|---|
| **A. Prompt canonical block + check-variants extract** (chosen) | Reuses the existing gate infrastructure; the keeper sees real wire names; minimal new code (2 extractors + 2 checks). The mirror is hand-maintained but **drift-gated**, which is the property that matters. |
| B. Generated prompt block (dune rule emits the block from `*_to_string`) | True derive-from-source; but prompt markdown is hand-curated prose *around* the block — auto-generating the whole section fights the prose. Block-with-gate (A) gets drift detection without forcing generation, and is a strict subset B can graduate to if A proves insufficient. |
| C. Runtime reflection (ppx / deriving) injected into the prompt | Over-engineered: the prompt is static text assembled at turn build time; runtime reflection does not fit the assembly boundary. |

A is chosen: prose around the block stays human-authored; only the variant
*list* is gated. If drift recurs *despite* the gate (e.g. prose describes a
removed variant while the list is correct), escalate to B.

## 6. Rollout

1. RFC merge (this document).
2. Implementation PR (post-#21679 and post-#21685 so the lists match current
   code): add the two `<!-- @variant-sync -->` blocks to
   `keeper.unified.system.md`; add the two extractors + Check 5/6 to
   `scripts/check-variants.sh`; verify `make check-variants` PASS locally.
3. CI: no change required (`check-variants.sh` is already a CI step).

## 7. Risks

- **Prose drift inside a block**: the gate checks the variant *list*, not the
  surrounding prose. A removed variant whose prose description lingers is not
  caught. Mitigation: keep prose outside the tagged block; the block is
  names-only.
- **Wire name vs constructor name**: `keeper_cycle_channel.Reactive → "turn"`
  (RFC-0020). Phase-1 types have 1:1 mapping, so safe. Deferred types must
  document the mapping in their block (Phase 2 work).
- **Over-exposure**: listing all `skip_reason`s may lead keepers to rationalize
  skips. Mitigation: the block states these are scheduler-side; keeper action is
  unaffected (diagnostic only, keepers do not produce `skip_reason`).

## 8. Non-goals

- Auto-generating full prompt prose (Alt B/C).
- Detecting *semantic* drift (variant present but described wrongly) — only
  set-membership drift.
- Syncing to `keeper.world.md` — it is a dead/bootstrap prompt per audit §2.3;
  the path-consolidation RFC addresses that separately.

## 9. Relationship to audit findings

Resolves structurally: audit §2.2 (`skip_reason` 7 closed sum, 0 prompt mentions)
and §2.5 (`Task_backlog` partial). After this RFC, a variant added or removed in
code forces a prompt block update or `make check-variants` (CI) fails — the
mirror can no longer silently drift.
