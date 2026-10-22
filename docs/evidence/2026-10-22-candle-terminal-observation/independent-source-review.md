verdict: PASS head: 8057614cc68a1901f140a5190d4b0d6d38581263 by: bidi_partial_failure_response

# G03 Candle terminal observation source review

Exact base: `3145acf9fc32ab77c25d97ab7e5710194cd270cf`.
Exact head: `8057614cc68a1901f140a5190d4b0d6d38581263`.
Complete reviewed diff: four files, 130 additions / 5 deletions:

- lib/server/server_candle_appraiser.mli
- lib/server/server_candle_appraiser.ml
- test/test_candle_appraiser_transport.ml
- test/stanzas/test_candle_appraiser_transport.inc

Local whole binary patch SHA256: `700123374c632688c3d34ae8aab5a5023103287614d1bc29dbebc76f069ebc9e` (not the canonical review-diff helper identity).

Independent read-only SOURCE verdict: **no P0–P2 found in this frozen delta.** The measured repeated-terminal elapsed overwrite is addressed in the actual Candle consumer. This is not a compiler/test/runtime/CI result or formal GitHub approval. I did not edit source, run Dune, typecheck, execute tests, query CI or mutate runtime. The author's parser/diff checks are not promoted to compilation. The real eb484+b427 provider/Paid experiment predates this code and is not a validation of this fix.

## Actual consumer and receipt decisions

I read the complete four-file diff, the full current consumer/test, existing registry ML/MLI and its durable core, original intent identity, staged payout/worker callers, and direct library declarations.

`server_candle_appraiser.ml:93–108` still retains the original tool request owner and reads the worker state first. Absent alone permits the existing idempotent submit. `:157–181` still performs Exact result validation, Candle domain decode and trace validation before calling the new receipt comparison. It does not recover a domain decision from an observation row or skip current worker authority on an earlier receipt success.

`same_receipt` at `:111–113` compares outcome, complete wrapper output through Yojson.Safe.equal, slot and optional mapped usage. It excludes elapsed_s and persistence diagnostics. JSON field order alone therefore is not intended to generate another completion; arrays remain ordered. None usage is preserved as distinct from reported usage. No substring/regex or arbitrary elapsed threshold is introduced.

At `:124–140`:

- A readable identical Completed returns Ok without mark_completed. Consequently it appends no new completion, sends no extra mutation notification and preserves first elapsed/output/slot/usage.
- An identical Completion_persistence_failed retries the same observation with recorded.elapsed_s. A second storage failure remains a typed failure through the existing registry API; no new model dispatch is introduced.
- A readable different completion still replaces the observer row. This is necessary for the registry's replay-generated Failed/server_restarted marker to yield to the actual validated worker result. The shared registry's semantics for other producers are unchanged.
- Missing run or Running uses existing write behavior; Unknown_run still surfaces if the ID was actually removed before commit.

The new .mli comment describes the behavior without changing any exported type or call signature. Existing consumer call sites require no migration.

## Payload, failure, restart and authority boundaries

The design-review hazard is handled: `:117–122,127,135` explicitly checks output_availability. Registry detail reads can return Completed with null output and Unavailable(Missing_completion / Invalid_payload / Source_unavailable / Snapshot_changed); all such cases now return Transport_unavailable rather than being treated as a different model result and overwritten. None/Not_loaded is not confused with an available JSON null. The code uses get, not summary projections that intentionally omit payloads.

The registry's Completion_persistence_failed overlay keeps its original output in memory and output_availability Available. The new branch preserves that first elapsed value while retrying only persistence. The underlying `mark_completed` still distinguishes durable success from failure overlay, and exceptions/cancellation are not swallowed by this change.

A replay-only Running marker is constructed with Failed/server_restarted, reason/detail output and no slot/usage. Its actual output/outcome differs from a worker terminal, so this implementation does not strand an original result behind a blanket Completed skip. Existing recovery fixture still reads the original ID, replaces the marker, preserves original input and asserts actual succeeded output attribution.

Outcome_unknown and other real terminal rejections use the same completion helper and retain their initial observation when identical. They still return Execution_rejected / Invalid_response as before, never a dispatch authorization. Pending, Capacity_wait, transport errors and malformed state do not become receipt-based success. A later domain-invalid response is not hidden by an earlier succeeded receipt.

Receipt preservation neither reassigns an installation nor changes export/principal authority. Runtime calls remain Operator-scoped and durable original request ownership precedes RPC. Worker replacement/unknown replay fencing is unchanged. Paid still comes from the original settlement path with its ledger/configuration revalidation, not from a completed receipt.

## Concurrency scope

The implementation is a read-compare-write caller policy, not a new atomic first-writer registry primitive. This limitation remains explicit in this review:

- The production global Candle_payout_worker is singleton and sets Goal owner.in_flight before fork.
- The same Goal is not launched again until its current owner finishes, including a changed waiting request.
- The deterministic intent includes Goal/request/proof identity plus stage/input/schema/prompt/task identity, so different Goals do not collide and stages are called serially.

I found no simultaneous same-intent production caller at this frozen head. Therefore the lack of a new global mutex is not a demonstrated P2. The helper should not be advertised as providing arbitrary parallel direct For_testing.run first-writer semantics; a later caller expansion would need conditional commit/appropriate original-intent serialization. No new lock across RPC/model waits was added.

For Completed, Snapshot_changed makes output Unavailable and is rejected. In a failed-completion overlay input availability can separately become unavailable while its retained output is still in memory; this change does not claim atomic input+output snapshots or silently erase that registry diagnostic. Its current original owner/worker decode, not the damaged observation input, is still authority.

## Regression and direct compile-boundary audit

I read all three added cases and their unchanged runner helper:

1. **Reread + restart:** first completion goes through the actual consumer and disk-backed registry. The test captures the original whole run and exact log bytes. A current reread and a replayed-registry reread must not append or change the receipt. The pre-fix unconditional completion would append again even if the clock happened to return the same float, so this is not a sleep-dependent assertion.
2. **Real append failure + recovery:** the scripted worker reply is returned only after the real log path has been replaced by a directory. Payload writing remains under the original log parent; durable append then fails. The test inspects Completion_persistence_failed.elapsed_s, restores the original registration log, re-reads only the original worker result, replays storage and demands exact first elapsed. It does not stub mark_completed or convert failure into success.
3. **Actual payload deletion + restoration:** it derives the real output digest/name using the same serialized output and deletes that retained file. Reread must return Transport_unavailable, leave log bytes unchanged and keep Missing_completion explicit. Restoring original bytes must recover the unchanged original receipt. No synthetic new request or relaxed payload integrity check is used.

These are meaningful consumer/protocol/storage checks. They do not execute a real worker/provider, maintenance timer or visible UI. Later-stage pending timing and corrupt/Snapshot_changed variants are not individually executed here; the branch handling them is read in source. Existing lost-submit/restart, repeated Unknown, immutable installation owner, full domain weights, malformed-state, capacity and missing-prompt tests remain present. Suite grows from 7 to 10 cases; no prior expectation is weakened.

Source-level compile boundary checked directly:

- Runs.get constrains run/status records before record-label use; the new patterns cover every current option/status/availability constructor explicitly.
- same_receipt/write inference is constrained by the actual Runs.mark_completed signature, including optional Runs.usage; no unconstrained payload-record helper was found.
- stored_run's return is constrained by Runs.get; tests use current run_status fields and exported run_to_yojson/payload_dirname APIs.
- New Digestif.SHA256 access has an explicit digestif stanza dependency. test/deps/dune also already re_exports digestif, so there was no missing visibility edge; the direct addition is redundant but harmless.
- Existing direct masc.server / masc_candle / mcp_protocol and masc_test_deps re_exports cover the actual namespaces used by this suite, including Masc, Fs_compat, Unix, Eio, Time_compat, Alcotest and Yojson.
- Prompt Markdown dependencies and the actual transport test stanza remain intact. No interface constructor change propagates to unrelated producers.

No concrete compile defect was found by this source inspection. That statement is not evidence that the candidate has been compiled or that the 10 tests have run. The smallest subsequent compiled target is the existing test_candle_appraiser_transport suite; broader native/provider/UI work is not implied necessary by this source verdict.
