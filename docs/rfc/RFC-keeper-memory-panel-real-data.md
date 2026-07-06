---
rfc: "keeper-memory-panel-real-data"
title: "Keeper memory panel: real-data backing (no fabrication, no score resurrection)"
status: Draft
created: 2026-06-24
updated: 2026-06-25
author: vincent
supersedes: []
superseded_by: null
related: ["0233", "0244", "0247", "0259", "0285"]
implementation_prs: [22307]
---

# RFC (keeper-memory-panel-real-data): Keeper memory panel — real-data backing

Status: Draft · The live "Keeper 메모리" panel renders zeros from an empty-prop wiring, and the
Claude-Design prototype it ports encodes a `score · usage · pin · timeline` model the backend
deliberately deleted (RFC-0247). This RFC re-derives the panel from what the Memory OS **actually**
holds — real prompt-block composition, real `fact`/`episode` rows, real recall state — adapts the
design's visual language to those fields, and adds only the extensions legitimate against the existing
model. It **does not** revisit RFC-0247: the score-model deletion stands (operator-confirmed
2026-06-24); `salience` / `uses` / `lastUsed` are not resurrected.

**Surfaces (CLAUDE.md agent_delegation)**: dashboard memory components + bounded additions to
`lib/server/server_dashboard_http_keeper_api.ml` serialization (`facts.items`, `selection_policy`).
Not credential/operator/sandbox/hooks — outside the mandatory-RFC list, but authored as RFC because
it amends a serialized data contract and rewires a live panel.

## 1. Problem

The "Keeper 메모리" panel (`dashboard/src/components/memory-inspector.ts`, mounted via
`keeper-workspace-rail.ts:425`) renders **zeros** for pins / store / mem-tok across all 12 live
keepers (real keeper roster + real CTX% only). Single root cause: `keeper-workspace-rail.ts:428`
passes `memory=${{}}` / `compactions=${{}}`, overriding the component's bundled fixture defaults
with empty objects. No real memory data is fetched on this path.

The component is a pixel-accurate port of the Claude-Design prototype (`keeper-v2/memory.jsx`,
`memory-data.jsx`; CSS parity already complete in `memory-inspector-v2.css`). The naive fix —
"wire it so it looks like the prototype" — is **not implementable without fabrication**, because the
prototype encodes a data model the backend deliberately deleted:

- The prototype's `memComposition()` synthesizes a 5-part token breakdown from magic constants
  (`system=6200`, `store.length*900 + pinned.length*220`, `tasks*2600`, `min(total*0.42, traces*90)`,
  `if (nsDialog < total*0.1) nsDialog = total*0.2`). The numbers in the design screenshot
  (6.2k / 78.8k / 28.6k) are this formula's output, **not measured data**.
- The prototype's store rows carry `salience` (0–1), `uses`, `lastUsed`. These are exactly the fields
  RFC-0247 removed: `keeper_memory_os_types.ml:278-283` — *"The deleted fields (confidence,
  access_count, last_accessed, stale_factor, expected_lifetime_cycles) were inputs to the removed
  composite score; a fact's value is the librarian's judgment, not a number on the row."*
- The prototype's `kind` taxonomy (`fact/decision/pattern/pref/entity`) is not the backend taxonomy
  (`category`: `Code_change/Fact/Preference/Blocker/Goal/Constraint/Ephemeral/Validated_approach/
  Lesson/Unknown`, `keeper_memory_os_types.ml:40-50`).
- The prototype's recall/inject **op-timeline** with per-event `tok` deltas has no backend producer
  (recall is a render-time action, `Keeper_memory_os_recall`).
- The prototype's `pinned` facts have **no backend mechanism** at all.

Porting any of these verbatim violates the stated bar: 노 하드코딩 / 노 휴리스틱 / 노 Stub /
노 Silent Failure / 노 스트링 매치 / SSOT. So this RFC re-derives the panel from what the backend
**actually** holds, adapts the design's visual language to real fields, and adds only the extensions
that are legitimate against the existing memory model.

## 2. Non-goals (adversarial guardrails)

- **No score-model resurrection.** `salience` / `uses` (`access_count`) / `lastUsed` (`last_accessed`)
  stay deleted. RFC-0247 is upheld, not reversed. Any UI that needs a "0–1 importance bar" is rejected
  here; a fact's importance is its `category` + the librarian's inclusion judgment, not a row number.
- **No fabricated token math.** Context composition uses measured `prompt_block.bytes` and turn-level
  `usage.input_tokens` / `context_window` only. No `ctx * 200000`, no per-part magic multipliers.
- **No read-side string classifier.** `category` / `claim_kind` / `Prompt_block_id` are already closed
  sums parsed once at the producer boundary; the dashboard decodes the typed string into a TS
  discriminated union and handles it exhaustively (an `Unknown of string` / `Other of string` arm
  carries forward-compatible labels rather than dropping them).

## 3. Field-by-field legitimacy verdict

| Design section / field | Backend reality | Verdict |
|---|---|---|
| 컨텍스트 구성 — 5-part **token** breakdown | `turn_record.blocks : prompt_block list` = `{ block: Prompt_block_id.t; bytes; digest }` (real **bytes**, real closed-sum block ids, RFC-0233). Turn-level `usage.input_tokens`, `context_window`. Already served in `/turn-records` `entries[].blocks`. | **Adapt**: render real per-block **bytes** + real block taxonomy + turn `input_tokens`/`context_window`. Drop the fabricated 5-part token split. (P1, **FE-only — no backend change**.) |
| 장기 메모리 스토어 — claim text | `fact.claim` (`keeper_memory_os_types.ml:285`). `memory_os.facts` currently exposes **counts only**, no `items`. | **Extend**: add `items` to `memory_os_dashboard_json` facts section. (P1, 1 serializer change.) |
| store — kind | `fact.category` closed sum (10 arms). | **Adapt**: real `category` union, exhaustive. Not the prototype's 5. (P1.) |
| store — `src` / provenance | `fact.source : provenance_event = { trace_id; turn; tool_call_id }` (line 18-22). | **Adapt**: real provenance, not a single `T-####` tag. (P1.) |
| store — staleness / age | `reference_time = last_verified_at ∨ first_seen` (line 342-346); `valid_until`; `fact_is_current` (line 317). | **Adapt**: show age (from `reference_time`) + TTL/current state. Replaces `lastUsed`. (P1.) |
| store — `salience` | Deleted (RFC-0247). | **Drop.** |
| store — `uses` (`access_count`) | Deleted (RFC-0247). | **Drop.** |
| store — `lastUsed` (`last_accessed`) | Deleted (RFC-0247). | **Drop** (use `reference_time` age instead). |
| 핀 고정 사실 (operator pin: by/tag/at) | No mechanism. Pinning = operator judgment annotation; aligns with RFC-0247 ("value is judgment") and is **not** a score. | **New feature, P2** (write path; immutable annotation keyed by `claim_id`). |
| 회상·주입 타임라인 (op + tok delta) | No per-event log. But episodes ARE real memory-shaping events (`created_at`, `terminal_marker`, `source_turn_range`, `claim_count`); `keeper_compact_audit` holds `before/after_tokens`, `tokens_freed`. | **Adapt/extend, P3**: derive a real timeline from episodes (+ compact audit join). Not a synthetic op log. |
| 압축 유지/요약/폐기 (3-column items) | `episode.episode_summary` (summarized), `preserved_tool_refs` (kept refs), `open_items`/`constraints` (kept), `source_turn_range`; compact audit token aggregates. Item-level kept/dropped lists do not exist. | **Adapt, P3**: map to real episode fields; "dropped" derived from range − kept. No fabricated item lists. |

Summary: **2 sections fully real after a 1-field serializer add (composition, store), 1 new legitimate
write feature (pins), 2 sections adaptable from real episode/compaction data.** Zero fabricated fields.

## 4. Phase 1 — read-path: real composition + real store (ship first)

Lowest risk, highest value, no new persistence. Backend touches one function; the rest is FE.

### 4a. Backend — add `items` to the facts section

`memory_os_dashboard_json` (`server_dashboard_http_keeper_api.ml:72`) already reads
`facts = read_facts_tail ~keeper_id ~n:fact_tail_limit` (line 79) but emits only counts. Add an
`items` array mirroring the existing `memory_os_episode_json` shape, serializing **only fields that
exist on `fact`** (no new fields):

```ocaml
(* RFC-keeper-memory-panel-real-data §4a: surface the fact rows the panel renders. Serializes only
   existing [fact] structure — claim, typed category, provenance, the three
   timestamps, current-ness — NOT the deleted score fields (RFC-0247). *)
let memory_os_fact_json ~now (f : Keeper_memory_os_types.fact) =
  `Assoc
    ([ "claim", `String f.claim
     ; "category", `String (Keeper_memory_os_types.category_to_string f.category)
     ; "source", Keeper_memory_os_types.provenance_event_to_json f.source
     ; "first_seen", `Float f.first_seen
     ; "first_seen_iso", `String (Masc_domain.iso8601_of_unix_seconds f.first_seen)
     ; "reference_time", `Float (Keeper_memory_os_types.reference_time f)
     ; "valid_until", json_float_opt f.valid_until
     ; "valid_until_iso", json_time_iso_opt f.valid_until
     ; "last_verified_at", json_float_opt f.last_verified_at
     ; "current", `Bool (memory_os_fact_is_current ~now f)
     ]
     @ (match f.claim_kind with
        | Some k -> [ "claim_kind", `String (Keeper_memory_os_types.claim_kind_to_string k) ]
        | None -> []))
```

and add `; "items", \`List (List.map (memory_os_fact_json ~now) facts)` to the `facts` `\`Assoc`
(line 116-122). `category_to_string` is the existing SSOT producer; the FE re-parses it with the
mirror of `category_of_string`, so the closed sum stays the boundary, not a free string.

Bytes-identical safety: this only **adds** a key to an object; existing consumers
(`server_dashboard_http_keeper_memory_health.ml`, the FE counts decode) ignore unknown keys. No
removal, no reordering of the fact JSON on disk (the on-disk `fact_to_json` is untouched).

### 4a.1 Backend — expose selection_policy lineage without hiding shared recall

`selection_policy` is a dashboard contract field, not a classifier. It must describe what the
panel is showing and what the prompt recall path can inject. The shape is serialized from an OCaml
record (`memory_os_selection_policy`) so the JSON object is not an untyped inline literal:

```json
{
  "keeper_scope": "masc-improver",
  "shared_scope": "_shared",
  "facts_source": "Keeper_memory_os_io.read_facts_tail_with_errors",
  "shared_facts_source": "Keeper_memory_os_io.read_facts_all_with_errors",
  "episodes_source": "Keeper_memory_os_io.read_episodes_tail",
  "dashboard_fact_tail_limit": 384,
  "dashboard_episode_tail_limit": 12,
  "recall_private_fact_limit": 8,
  "recall_shared_fact_limit": 4,
  "recall_episode_limit": 2,
  "category_source": "Keeper_memory_os_types.category_to_string",
  "claim_kind_source": "Keeper_memory_os_types.claim_kind_to_string",
  "recall_block": "Keeper_memory_os_recall.render_if_enabled",
  "prompt_record": "Keeper_run_tools_hooks.record_block Prompt_block_id.Memory_os_recall"
}
```

The `dashboard_*` bounds describe read-panel payload bounds. The `recall_*` bounds describe prompt
injection defaults from `Keeper_memory_os_recall` and are intentionally separate: the dashboard scans
more rows than the prompt injects. `persona_weighting` is not emitted because no such runtime feature
exists. For non-`_shared` keepers, the policy must include the shared tier: actual recall reads the
keeper-local bounded store and then appends private-precedence facts from `_shared`.

### 4b. Frontend — typed category + composition view model

Replace the fixture-bound model in `memory-inspector.ts` with decoders over the **already-served**
`/api/v1/keepers/:name/turn-records` bundle (`memory_os.facts.items`, `entries[latest].blocks`,
`user_model`). Concretely:

- **Category** as a discriminated union mirroring the OCaml closed sum, decoded once:
  ```ts
  type FactCategory =
    | 'code_change' | 'fact' | 'preference' | 'blocker' | 'goal'
    | 'constraint' | 'ephemeral' | 'validated_approach' | 'lesson'
    | { unknown: string }                       // mirrors `Unknown of string`
  ```
  A `categoryMeta(c): {lbl; glyph; cls}` is **exhaustive** (TS `never` check on the closed arms);
  the `{unknown}` arm renders the raw label, never drops it. This is the no-string-match property.
- **Composition** from real blocks: take the latest `entries` row for the keeper, group its
  `blocks` by `block` id, sum `bytes`. Parts are the real `Prompt_block_id` arms (Persona,
  Dynamic_context, Memory_os_recall, User_model, Connected_surface, …), each labeled and colored;
  the "memory" portion is the real `Memory_os_recall` + `User_model` blocks. Total/secondary line:
  real `usage.input_tokens` and `context_window`. Units are **bytes** for the bar, **tokens** for the
  header — both labeled honestly. No `* 200000`.
- **Store rows**: real `category` + `claim` + provenance + age (`now − reference_time`) + TTL/current
  badge. The salience bar / "N회 사용" / "최근 X" meta are removed from the row template.
- **Empty / error states are loud**: the bundle's `memory_os.read_errors` (already produced,
  `server_dashboard_http_keeper_api.ml:101-106`) is surfaced as a visible error chip — a read failure
  is shown, not rendered as "0 facts" (no Silent Failure). A stopped keeper with no turn record shows
  "활성 컨텍스트 없음", distinct from "fetch failed".
- **Wiring**: `keeper-workspace-rail.ts:428` stops passing `memory=${{}}`; the inspector fetches by
  keeper name (reusing the existing `decodeMemoryOsSnapshot` path, extended for `items`). The
  "전체" aggregate view fetches per-keeper snapshots (bounded, with per-keeper error isolation) or a
  follow-up bulk endpoint; the "이 keeper" view (the primary, design-screenshot view) needs one fetch.

### 4c. Immutability

View models are `readonly`/frozen records built once per fetch; no in-place mutation of decoded rows.
Matches the existing component's `Readonly<...>` typing and the OCaml `fact` immutability.

## 5. Phase 2 — operator pins (new write feature)

Legitimate: a pin is an **operator judgment annotation**, not a row score — consistent with RFC-0247's
"value is the librarian's/operator's judgment." To preserve fact immutability, a pin is **not** a
mutable field on `fact`; it is a separate operator-owned, append-only annotation set keyed by the
fact's identity:

- Key by `claim_identity` (`keeper_memory_os_types.ml:528`) — the existing dedup SSOT (`claim_id`
  slug or normalized claim), so a pin survives a reworded re-extraction and never keys on a separate
  classifier.
- Store: a per-keeper `pins.jsonl` (append-only, same IO substrate as facts), entries
  `{ claim_key; by: operator|auto; tag; at }` as a closed-sum-typed record. Last-write-wins per key
  (pin/unpin) resolved deterministically on read.
- Write path: an operator action endpoint (auth-gated, mirrors existing operator control handlers).
  Out of P1 scope; specified here so the panel's pin section is built once with a real producer.
- Effect (optional, separate decision): a pinned claim may be exempted from TTL expiry / always
  recalled. That changes retention semantics and would need its own justification + RFC-0247 review;
  **default P2 is annotation-only (display + operator intent), no retention change.**

## 6. Phase 3 — real memory-shaping timeline

Replace the fabricated op-timeline with a timeline derived from real events:

- **Episodes** (already served, `memory_os.episodes.items`): each is a compaction/summary boundary —
  `created_at`, `terminal_marker`, `source_turn_range`, `claim_count`, `summary`. Rendered as
  `compact`/`summarize` events.
- **Compact audit** (`keeper_compact_audit`: `before_tokens`, `after_tokens`, `tokens_freed`): joined
  to give the real token delta per compaction (the design's `tok` column, now measured not invented).
  Requires exposing compact-audit rows in the bundle (currently absent) — a serializer add like §4a.
- **TTL expiry** (`partition_expired` / GC): expired-fact counts already in `facts.expired`; an
  `evict` event is the real GC sweep, not a synthetic per-fact line.

The 압축 유지/요약/폐기 columns map to `preserved_tool_refs` (kept), `episode_summary` (summarized),
and range−kept (dropped). No item list is fabricated; if a field is empty the column is honestly empty.

## 7. OCaml 5.4 / constraints compliance

- **Closed sums + exhaustive match**: `category`, `claim_kind`, `Prompt_block_id`, `external_ref_kind`
  are existing closed sums parsed once at producer boundaries; new code adds no `_ ->` catch-all and no
  read-time string match (RFC-0247 §2.5, project workaround-signature #2). `category_to_string` /
  `category_of_string` remain the only boundary.
- **No `Obj.magic`, total functions, `Result`/`option` over exceptions** in new decoders; reuse the
  existing `json_*_field` total accessors and `Result.bind` patterns already in `turn_record.ml`.
- **Immutability**: facts/episodes/blocks are immutable records; pins are append-only. No in-place
  mutation introduced.
- **No Silent Failure**: read errors propagate to `read_errors` and to a visible FE chip; a serializer
  that can't read a store reports it (existing pattern at `server_dashboard_http_keeper_api.ml:45-55`,
  which re-raises `Cancelled` and captures other exns as a scoped error string).
- **SSOT**: composition reuses `Prompt_block_id`; staleness reuses `reference_time`; identity reuses
  `claim_identity`. No parallel definitions.

## 8. Verification

- **Backend (OCaml)**: a codec round-trip test for `memory_os_fact_json` asserting every `fact` field
  is present/absent per the optional rules, and that the deleted score keys are **never** emitted
  (drift guard). Exhaustiveness test that every `category` arm has a `category_to_string` mapping
  (already covered by `category` tests; extend if a panel-specific mapping is added).
- **Frontend**: decoder unit tests over a captured real `/turn-records` payload (fixture from a live
  keeper, not hand-authored) — composition sums match block bytes; category decode covers all 10 arms
  incl. `{unknown}`; a `read_errors`-bearing payload renders the error chip (not zeros). Revert-guard:
  removing the `items` decode must turn a populated-store test red (non-vacuous).
- **Visual**: the "이 keeper" view against a live keeper with real facts; pixel parity holds because
  the `.mem-*` CSS is unchanged — only the data source and the (now real) row meta change.

## 9. Risks / rollback

- **Risk**: the latest `entries` row may lag the live context (turn records are written post-turn). Mitigation:
  label the composition with its `latest_ts_iso` / `latest_age_s` (already in the bundle) so staleness
  is visible, not hidden.
- **Risk**: `Dynamic_context` is one undifferentiated block (RFC-0233 note) — composition is coarser
  than the design's 5 parts. This is honest, not a defect; a finer split is a future RFC-0233 producer
  change, not a dashboard fabrication.
- **Rollback**: P1 backend is one additive JSON key (drop the key to revert); FE is a single component
  + the rail wiring line. P2/P3 are independent and unshipped until their own validation passes.
