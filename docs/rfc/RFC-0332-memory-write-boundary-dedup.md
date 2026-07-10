# RFC-0332 — Memory-bank write-boundary dedup with a typed outcome (`Persisted | Merged_into`)

- Status: Draft
- Decision driver: Ilya-30-papers adversarial transfer census (2026-07-08), axis A1's surviving core after the zstd-NCD refutation: "기존 jaccard 0.85가 recall/후보 선택에만 배선 — write 경계에 배선 + `Persisted | Merged_into` closed sum. 새 이론 0." The MDL framing survived only as a lens; the mechanism is in-tree reuse.
- Area: `lib/keeper/keeper_memory_bank_selection.ml:106-130` (`jaccard_similarity`, `semantic_dedup_similarity_threshold = 0.85`, `dedup_memory_candidates`), `:284` (its sole call site — intra-snapshot), `lib/keeper/keeper_memory_bank.ml:779` (`append_memory_notes_from_reply`, the write boundary), `:632` (compaction `dedup_by_key` — exact key only).
- Explicitly rejected upstream (do not resurrect): zstd-NCD content dedup (measured NCD 0.57–0.77 on real paraphrases vs. the 0.2 threshold the proposal assumed — the domain-blind compressor is the *weakest* model, inverting the MDL argument); embedding/read-side dedup re-litigation (already rejected in RFC-0247 §3).

## Problem (audited)

"표현이 어떻든 한 번만 저장" is currently only one-third true:

1. **Intra-snapshot only**: `dedup_memory_candidates` (jaccard ≥ 0.85 against `kept`) runs inside `memory_candidates_from_snapshot` (`keeper_memory_bank_selection.ml:284`) — it dedups the goal/progress/next/decision candidates of a *single turn's snapshot* against each other.
2. **Cross-turn unwired**: `append_memory_notes_from_reply` (`keeper_memory_bank.ml:779`) appends selected candidates to the JSONL bank without comparing them to what the bank already holds. The same stable fact re-stated across turns (goal restated every wake, a constraint repeated each session) accumulates as near-duplicate rows.
3. **Compaction is exact-key**: the retention pass dedups by `memory_row_key` only (`keeper_memory_bank.ml:632`) — paraphrases survive compaction and consume the kind-caps budget that should hold distinct facts.

Downstream, recall re-dedups every read (`dedup` in the selection pipeline) — paying the O(n²) similarity cost on the read path forever instead of once at write.

## Decision

1. **Wire the existing lexical dedup at the write boundary.** Before appending, compare each candidate against the recent persisted rows of the same kind (window: the rows compaction would consider, not the full history) using the same `Text_similarity.jaccard_similarity` and the same in-code `0.85` threshold (step-14(b) precedent: hyperparameters live in code, not env).
2. **The outcome is a closed sum, not a silent drop:**
   ```ocaml
   type write_outcome =
     | Persisted                       (* new row appended *)
     | Merged_into of { existing_key : string }  (* near-duplicate: no new row; existing row's recency refreshed *)
   ```
   Callers receive and can log/count the outcome; a candidate never disappears without a typed trace (no-silent-failure). `Merged_into` refreshes the existing row's recency/generation so compaction priority still reflects that the fact was re-asserted.
3. **This is a lexical floor, not semantic judgment** (3-layer discipline). Jaccard-0.85 here is a near-duplicate *guard* — the same role it already plays intra-snapshot — not a relevance ranker (axis A3's lexical re-ranker was KILLED as an RFC-0247 revert; this is not that). Anything below the threshold persists (fail-open to storage, fail-closed to data loss). True semantic consolidation stays in the learned-model lane (memory-OS consolidator), unchanged.
4. **Compaction alignment**: the retention pass may reuse the same comparison for its dedup step, replacing exact-key-only with exact-key + lexical-floor, under the same typed outcome. This is W2 and separable.

## Waves

| Wave | Scope | Exit criterion |
|---|---|---|
| W1 | `write_outcome` type + write-boundary comparison in `append_memory_notes_from_reply` (+ the tool-results/voice append paths if they share the row writer) | exact re-statement of a persisted row → `Merged_into`, bank row count unchanged, recency refreshed |
| W2 | Compaction retention uses the same floor (exact-key + jaccard) | paraphrase pairs do not both survive a compaction pass |
| W3 | Dashboard memory-bank surface: verify the census claim of a mislabeled dedup indicator (**확인 필요** — not reproduced by grep in this pass; if the label does not exist, close this wave as no-op) | label matches the mechanism actually wired |

## Verification

- Property pins: identical text → `Merged_into`; paraphrase below 0.85 → `Persisted`; different kind, similar text → `Persisted` (kind-scoped comparison); `Merged_into` refreshes recency (compaction priority pin).
- Budget pin: a synthetic 3-turn repetition of one fact yields 1 bank row (today: 3).
- Workaround-gate self-check: the typed outcome IS the fix; a counter alone (rows-dropped telemetry without `Merged_into` in the caller's hands) would be counter-as-fix and is rejected.

## Boundaries (untouched)

- Recall-side selection dedup — unchanged (it still protects reads from legacy duplicates).
- Threshold value and its in-code residence — unchanged (`0.85`).
- Memory-OS consolidator's learned/semantic lane — unchanged; this RFC does not attempt semantic equivalence.
- No zstd-NCD, no embeddings, no new similarity theory.

## Evidence record

- Evidence: `lib/keeper/keeper_memory_bank_selection.ml:106-130,284`, `lib/keeper/keeper_memory_bank.ml:632,779`, census artifact e1d4ba86 (axis A1, WEAKENED→surviving core), fresh-read re-verified 2026-07-09 at `63b5a69975` — including the refinement that the existing 0.85 wiring is intra-snapshot, narrower than the census's "recall 선택" phrasing.
- Confidence: High for the wiring gap; Medium for W3 (dashboard label claim unreproduced — recorded as 확인 필요, not asserted).
- Delta: converts the A1 storage-gate proposal into pure in-tree reuse with a typed outcome; the MDL/zstd theory is dropped entirely.
