---
title: "Vision-as-a-tool delegation (decouple multimodal input from conversation runtime)"
status: Draft
supersedes-partial: RFC-0265 (image/document modality path)
reciprocal-update-required: RFC-0265 front-matter (related / superseded-partial-by) must be edited in the same PR — a one-sided "supersedes" is invisible to rfc tooling (see masc RFC-collision lessons).
---

# RFC — Vision-as-a-tool delegation

- Status: Draft
- Relationship: amends/partially supersedes RFC-0265 (capability-driven proactive runtime reroute) for the **image/document** modality.
- Origin: 2026-06-25 incident — a keeper assigned a vision-capable cloud model (`minimax-m3`) still failed image follow-ups with `keeper turn completed with no textual reply` and slow responses.
- Note: this draft was revised after an adversarial design review (2026-06-25) that verified the cited infrastructure against the codebase and demoted several "exists" claims to "requires." Findings are folded in below and called out as `[review]`.

## 0. Summary

When a keeper turn carries an image, RFC-0265 reroutes the **entire turn** to a different runtime that declares image capability. This RFC proposes an alternative for the image/document case: **delegate the multimodal read to a vision runtime through a keeper tool**, return a text result, and keep the main keeper on its assigned runtime. The raw image lives only inside the tool sub-call; the main conversation history stays text-only.

This is a multi-phase infrastructure proposal, **not** glue over existing parts. The handle-based artifact store, the durable image bytes, the mid-turn provider sub-call, and the history-eviction invariant are each **new work** (§2.5–§2.6). The live 2026-06-25 incident is resolved by **Phase 0 alone** (config); Phases 1–3 target the *residual* architectural problems (sticky reroute, per-turn base64 re-send), not the incident.

## 1. Problem

The reroute model couples "which model reads the image" with "which model runs the whole conversation". Residual consequences after Phase 0 (root cause confirmed adversarially + by live probe):

1. **Whole-runtime swap**. A text-strong persona keeper loses its assigned model for the turn; conversely a vision turn drags persona/tooling onto whatever runtime declares image support.
2. **Sticky reroute**. The image persists in re-sent history (`keeper_turn_driver.ml:145-157` folds both `initial_messages` and `oas_checkpoint.messages` into the modality computation — intentionally, to avoid provider-400 on the re-sent image). So **every** later text-only follow-up recomputes `required=['image']` and re-reroutes.
3. **Full base64 re-send each turn**. The image is never image-aware-evicted from history; `image_block` carries inline base64 `data`, so the payload is re-serialized on every subsequent turn → latency and token cost grow per turn.
4. **Lands on whatever single runtime declares the capability**. In the live config that was the local `gemma4-26b-a4b-qat` (`max-concurrent=1`, Q4 GGUF) — slow, and it returned empty text → `keeper_tool_response.ml:12` `no textual reply`.
5. **A capability misdeclaration is amplified by the architecture** `[review: corrected]`. The reroute mechanism is *not* silent — RFC-0265 §3.3 mandates a visible WARN. What was silent was the **config** gap (a missing `supports-image-input` key, fixed in `jeong-sik/me` PR #1223). The architectural point is narrower but still real: because reroute is the only lever, a one-line config gap escalates to a full keeper outage instead of a degraded single turn.

RFC-0265 §1 itself frames the goal as "the image must reach a model that can read it." Delegation satisfies that goal without conflating it with the conversation runtime.

## 2. Design

### 2.1 Boundary (deterministic vs non-deterministic)

| Concern | Kind | State today `[review-verified]` |
|---|---|---|
| Artifact handle lookup | deterministic | abstraction exists (`Multimodal.Workspace.find_by_id`, `workspace.ml:38`) but is **output-side and lossy** — see §2.5 |
| Durable image bytes across turns | deterministic | **does NOT exist** — `Payload.of_json` rebuilds `Lazy_payload (fun () -> "")` (`payload.mli:35-42`); bytes are empty after any checkpoint/restart |
| Tool dispatch that makes a provider sub-call | deterministic | **new shape** — no in-process handler threads `sw/net/clock` to `complete` today (§2.6) |
| The extraction text (what the image "says") | non-deterministic | the vision runtime sub-call |
| Main conversation reasoning | as assigned | the keeper's own runtime |

The raw image bytes cross into the vision sub-call **only**. The main keeper conversation never holds an `Image` content block.

### 2.2 Tool: `analyze_image`

- Input: `{ artifact: <handle>, query: string }`. `query` lets the keeper ask a specific question ("what is in the top-left?", "transcribe the text", "describe the chart").
- Behavior: load the artifact bytes (§2.5), build a one-shot message `[Text query; Image artifact]`, dispatch to a configured **vision runtime** (a sub-call, not a reroute of the main turn), return the assistant text as the tool result.
- Failure is a **tool error** (typed `Result`), localized to the tool call — not a whole-turn `no textual reply`. The keeper can retry, ask differently, or proceed.

### 2.3 Ingestion interception (write-time, not read-time) — ALL entry sites `[review: was N-of-M]`

Images enter a keeper conversation at **two** sites, not one. The invariant "main history holds no `Image` block" must be enforced at **both**, or a reloaded keeper re-materializes inline base64 and the sticky-reroute/re-send pathology returns:

1. **Fresh input** — single chokepoint `Keeper_multimodal_input.to_oas_blocks` (`keeper_multimodal_input.ml:354`), reached only via `user_oas_blocks_of_args` (`keeper_turn.ml:218-227`). Intercept here: store bytes → handle, emit text placeholder `[image artifact:<handle> — call analyze_image to read it]`.
2. **Checkpoint / history rehydration** — `keeper_context_core_message_json.message_of_json` reconstructs `Agent_sdk.Types.Image` from persisted JSON (`:66`, `:100`). The placeholder must be written **into the persisted checkpoint** at ingestion time, so rehydration never reproduces an inline image. If the placeholder lives only in the live turn, this site re-injects the image and the design self-inflicts workaround-signature #3.

Doing the `Image → placeholder` transform **at the write boundary** (ingestion + persisted checkpoint) — not as a sanitize-on-read — is the typed, root form. Covering only site 1 is incomplete by construction.

### 2.4 Mechanism selection — an explicit persisted axis, not a derived adjective `[review: was undecidable]`

RFC-0265 §3.4 requires that "two identical turns reroute identically." "Text-runtime keeper" vs "vision-native keeper" is **not** a modeled property — capability is a property of the per-turn-resolved runtime/model, and a keeper can be reassigned (operator failover, RFC-0207), so a derived adjective makes the *same* keeper flip mechanisms across turns. That reintroduces exactly the non-determinism RFC-0265 forbids.

Therefore the reroute-vs-delegate choice must be an **explicit, persisted policy axis** — a keeper-meta field (e.g. `multimodal_policy = delegate | reroute | inherit`) or a config key — resolved deterministically and independent of the live runtime assignment. Default and migration of existing keepers are specified in Phase 3.

### 2.5 Durable artifact store on the input path — REQUIRED new infra `[review]`

The existing `Multimodal.Workspace` / `Workspace_holder` is **not reusable as-is**:
- **Output-side only**: its sole writer is the post-turn wire-in `apply_multimodal_wirein` (`keeper_post_turn.ml:338-373`), consuming artifacts the agent *emitted* via `Keeper_emitter.emit`. There is no input ingestion path.
- **Off by default**: gated behind `MASC_MULTIMODAL` (`wirein_helpers.ml:3-6`, `keeper_post_turn.ml:341`).
- **Not durable**: `Payload.of_json` is lossy by construction (`payload.mli:35-42`), so a handle that survives checkpoint/compaction/restart returns empty bytes — fatal for multi-turn re-query.

Required: a handle-keyed store on the **input** path, backing bytes with a durable `Blob_ref` (blob store / content-addressed file), surviving the checkpoint round-trip. This is a Phase-0 *design* prerequisite (resolve before Phase 1), not an Open Question.

### 2.6 Mid-turn provider sub-call — new tool-execution shape `[review]`

The librarian (`keeper_librarian_runtime.ml:20-22`, routed by `runtime_id_for_librarian`) proves the *mechanism* — pick a runtime, build one-shot messages, call `Llm_provider.Complete.complete ~sw ~net ?clock ~config`. But it runs on the **post-turn** path, not as a keeper tool. The in-process tool handler contract (`keeper_tool_in_process_runtime.mli`, RFC-0179) is `~args -> string` with **no `sw/net/clock`** threaded to the handler, and the executor variants (`keeper_tool_descriptor.ml:3-11`) are `In_process | Host_process | Sandbox_process` — none calls an LLM. `analyze_image` therefore needs either a network-capable in-process handler (thread the Eio context the dispatcher already receives at `keeper_tool_dispatch_runtime.mli:162-166`) or a new executor variant. This is real infra, not glue.

## 3. Trade-offs

**Pros**
- Main keeper runtime unchanged → persona/tools/context preserved.
- No sticky reroute; no per-turn base64 re-send (latency/cost bounded) — **conditional on §2.3 covering both entry sites**.
- Vision failures are isolated tool errors, not turn-fatal `no textual reply`.
- A single config gap can no longer route an entire keeper to a weak model.

**Cons / limits**
- **Lossy by default, and strictly more model calls for multi-turn-over-image** `[review-quantified]`. RFC-0265 reroute needs zero extra model calls to see pixels (the answering model always has them); delegation needs ≥1 sub-call on turn 1 and **another full provider round-trip per later turn that needs any uncaptured detail**, against a possibly single-slot vision runtime. The latency win holds **only** for the "one image, one question, then back to text" shape. Making delegation the Phase-3 default pushes the common multi-turn-over-image case onto the worse path; Phase 3 must justify that the one-shot shape dominates, or keep reroute as the default for image-heavy keepers.
- **Affordance dependence**: the keeper must decide to call the tool. Needs prompt/affordance work and possibly an auto-call on first image.
- **Two mechanisms coexist**: requires the persisted policy axis of §2.4. Without it the boundary is undecidable.
- Extraction quality is bounded by the vision model and the `query`; a poor query yields a poor description the main model cannot recover from without re-query.

## 4. Migration

- **Phase 0a (done)**: config correctness — declare true `supports-image-input` + `media_failover` (`jeong-sik/me` PR #1223, MERGED). Resolves the live incident; reroute lands on a capable cloud model. **Phases 1–3 are not required for the incident.**
- **Phase 0b (design prerequisite)**: durable blob-backed input-side artifact store (§2.5) and the persisted mechanism-selection axis (§2.4). Block Phase 1 until these are designed.
- **Phase 1**: `analyze_image` tool (§2.2, §2.6) delegating to a vision runtime. Opt-in; no ingestion change.
- **Phase 2**: ingestion interception (§2.3) at **both** entry sites + persisted checkpoint placeholder; main history becomes text-only.
- **Phase 3**: set `multimodal_policy` defaults; scope RFC-0265's image/document reroute to keepers whose policy selects it. Edit RFC-0265 front-matter reciprocally in the same PR.

## 5. Verification

- **Unit**: `analyze_image` returns `Ok text` on a valid artifact; `Error` on a missing artifact or vision sub-call failure. After ingestion, `required_modalities_of_messages (main history)` never contains `"image"` — asserted **after a checkpoint save+reload round-trip** (covers §2.3 site 2).
- **Durability**: store bytes, persist + reload a checkpoint, re-read the handle → bytes are non-empty and byte-identical (revert-red against the current lossy `Payload.of_json`).
- **Reroute non-fire**: a keeper with `multimodal_policy = delegate` given an image (post Phase 2) → `decide_modality_reroute_for_runtime` returns `No_reroute_needed` for subsequent text turns (revert-red: before Phase 2 it returns `Reroute`).
- **Integration**: image in → tool called → text result in history; a follow-up needing new detail triggers a second `analyze_image`.
- **TLA+ (optional, per repo bug-model pattern)**: invariant `NoRawImageInMainHistoryAfterIngestion`; `BugAction`s that leave the image inline at *either* entry site must violate it.

## 6. Workaround self-check (CLAUDE.md gate)

- Not telemetry-as-fix (no counter; it removes the failure path).
- Not a string/substring classifier (uses the typed capability predicate + typed artifact handle).
- **N-of-M risk is real and must be closed, not asserted away** `[review: prior draft falsely claimed "no per-site patching"]`. Image entry has two sites (§2.3); the design avoids signature #3 **only if** the placeholder is enforced at ingestion *and* persisted into the checkpoint so rehydration cannot reproduce it. Phase 2 acceptance = both sites covered, proven by the save+reload unit test.
- The §2.3 transform is **write-time protocol-boundary enforcement**, deliberately not sanitize-on-read.
- **Repair-signature pre-emption**: a re-query hitting an empty `Lazy_payload` would invite a regenerate/cache-repair patch (the repair signature). §2.5 forecloses this by mandating durable bytes at design time, not deferring it.

## 7. Open questions

- Auto-call on first image vs explicit keeper decision?
- Should `document` (PDF) reuse the same tool or a sibling `analyze_document`?
- Does any current keeper genuinely need whole-turn native vision (→ `multimodal_policy = reroute`)?
- Blob store backend for §2.5 (content-addressed local files vs an existing store) and its eviction policy.
