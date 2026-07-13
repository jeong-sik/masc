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
| Decision to read an image placeholder | non-deterministic unless policy-gated | keeper planning may choose to call or skip `analyze_image`; Phase 2 must choose explicit auto-call / completion-gate / allowed-skip policy before making delegation default (§3, §7) |
| The extraction text (what the image "says") | non-deterministic | the vision runtime sub-call |
| Main conversation reasoning | as assigned | the keeper's own runtime |

The raw image bytes cross into the vision sub-call **only**. The main keeper conversation never holds an `Image` content block.

### 2.2 Tool: `analyze_image`

- Input: `{ artifact: <handle>, query: string }`. `query` lets the keeper ask a specific question ("what is in the top-left?", "transcribe the text", "describe the chart").
- Behavior: load the artifact bytes (§2.5), build a one-shot message `[Text query; Image artifact]`, dispatch to a configured **vision runtime** (a sub-call, not a reroute of the main turn), return the assistant text as the tool result.
- Failure is a **tool error** (typed `Result`), localized to the tool call — not a whole-turn `no textual reply`. The keeper can retry, ask differently, or proceed.
- Empty or whitespace-only extraction text is **not** `Ok ""`. It must return a typed error such as `empty_extraction`, because the 2026-06-25 incident failed through an empty assistant reply; delegation must not reintroduce that silent-success class inside the tool.
- The empty-reply class has a **measured cause** `[probe 2026-06-25]`: a reasoning runtime can spend its whole token budget in the `<|think|>` phase and return `done_reason=length` with empty `content`. Local `gemma4-26b-a4b-qat` does exactly this on image input (text-only: `done_reason=stop`, answers in 53 tokens; image+text: `done_reason=length`, 64/64 tokens consumed thinking, empty content), while cloud `minimax-m3`/`kimi-k2-6` answer within the same 64-token budget. So the tool MUST (a) budget enough tokens for post-thinking text and (b) distinguish `truncated_extraction` (`done_reason=length`, empty content → retry with a larger budget or a non-thinking-starved runtime) from a genuine `empty_extraction`. The configured vision runtime should be a budget-adequate one (cloud), not a thinking-token-starved local QAT.

### 2.3 Ingestion interception (write-time, not read-time) — ALL entry sites `[review: was N-of-M]`

Images enter a keeper conversation at **two** sites, not one. The invariant "main history holds no `Image` block" must be enforced at **both**, or a reloaded keeper re-materializes inline base64 and the sticky-reroute/re-send pathology returns:

1. **Fresh input** — the user blocks are parsed by the *pure* `Keeper_multimodal_input.to_oas_blocks` (`keeper_multimodal_input.ml:354`, reached via `user_oas_blocks_of_args`, `keeper_turn.ml:218`). That function has **no Eio context and no keeper meta**, so the eager vision sub-call cannot live there. The eviction is therefore applied one level up, at the turn-execution caller (`keeper_turn.ml:433`, after `meta0` is resolved and `ctx`'s `net`/`clock` are in scope): for each `Image` block — store raw bytes → content-hash handle in the per-keeper `Vision_artifact_store`, run `analyze_image` **once** (the eager extraction, §2.3-eager below), and replace the block with a text placeholder carrying the extracted reading + handle. The live turn never holds an `Image`.
2. **Checkpoint / history rehydration** — `keeper_context_core_message_json.message_of_json` reconstructs `Agent_sdk.Types.Image` from persisted JSON. The eviction must also run at the checkpoint **write** boundary (`keeper_context_core.sanitize_checkpoint_message`, the existing per-message mutation point that already stubs oversized `ToolResult` and drops `Thinking`), so the **persisted JSON** never holds inline base64 and rehydration deserializes a `Text` placeholder it can no longer turn back into an `Image`. This write-path site is store-only (handle placeholder, **no** re-extraction — checkpoint writes have no turn-scoped vision budget and must not block the turn fiber on a provider call), which also makes it the **migration path** for images already persisted in existing keeper checkpoints (e.g. garnet's 6/19, 6/22 stuck images): they are evicted to bare-handle placeholders on the next write, stopping the reroute.

Doing the `Image → placeholder` transform **at the write boundary** (turn ingestion + persisted checkpoint) — not as a sanitize-on-read — is the typed, root form. Covering only site 1 is incomplete by construction. Both sites are idempotent: a `Text` placeholder is not an `Image`, so re-running on an already-evicted message is a no-op (no double-store, no double-extract).

#### 2.3-eager — Decision (2026-06-25): eager extraction, not lazy placeholder `[resolves §7 Q1]`

The merged draft of point 1 emitted a *bare* placeholder `[image artifact:<handle> — call analyze_image to read it]` and left the keeper to *decide* to re-read (lazy). That carries the two §3 cons below (a model call per later turn that needs detail + affordance non-determinism). After the architecture audit (`wf_8b6a1dec`, 2026-06-25) and operator decision, Phase 2 instead extracts **eagerly at ingestion**: the placeholder carries the vision model's *reading* (`[image read: <text> | artifact:<handle>]`), so the meaning is remembered as text and most follow-up turns answer without any further vision call. The bytes remain in the store, so a hard later question ("what's in the top-left?") can still re-read via `analyze_image` on the handle — i.e. eager **contains** lazy as a graceful fallback. This matches how Claude Code degrades images to text once at compaction (`stripImagesFromMessages`) rather than re-deciding per turn. The fixed extraction query is **exhaustive** ("describe all text verbatim, UI elements, layout, colors, state, errors, numbers"), trading more turn-1 tokens for fewer later re-reads.

### 2.4 Mechanism selection — an explicit persisted axis, not a derived adjective `[review: was undecidable]`

RFC-0265 §3.4 requires that "two identical turns reroute identically." "Text-runtime keeper" vs "vision-native keeper" is **not** a modeled property — capability is a property of the per-turn-resolved runtime/model, and a keeper can be reassigned (operator failover, RFC-0207), so a derived adjective makes the *same* keeper flip mechanisms across turns. That reintroduces exactly the non-determinism RFC-0265 forbids.

Therefore the reroute-vs-delegate choice must be an **explicit, persisted policy axis** — a keeper-meta field (e.g. `multimodal_policy = delegate | reroute | inherit`) or a config key — resolved deterministically and independent of the live runtime assignment. Default and migration of existing keepers are specified in Phase 3.

### 2.5 Durable artifact store on the input path — REQUIRED new infra `[review]`

The existing `Multimodal.Workspace` / `Workspace_holder` is **not reusable as-is**:
- **Output-side only**: its sole writer is the post-turn wire-in `apply_multimodal_wirein` (`keeper_post_turn.ml:338-373`), consuming artifacts the agent *emitted* via `Keeper_emitter.emit`. There is no input ingestion path.
- **Always wired**: typed multimodal artifacts flow through the normal Keeper
  runtime. Provider/model selection remains configurable and any external
  effect is independently decided at Gate.
- **Not durable**: `Payload.of_json` is lossy by construction (`payload.mli:35-42`), so a handle that survives checkpoint/compaction/restart returns empty bytes — fatal for multi-turn re-query.

Required: a handle-keyed store on the **input** path, backing bytes with a durable content-addressed file (the handle is the content hash, not inline base64), surviving the checkpoint round-trip.

**New but precedented, not greenfield** `[grounded]`. `lib/review_artifact_store.ml` already implements the exact pattern: `Digestif.SHA256` content hashing (`:3-5`), atomic file write `Fs_compat.save_file_atomic` (`:24-29`), and a JSONL index (`:31-38`). A vision-input store mirrors it — write the image bytes to a content-addressed file under the keeper's artifact/checkpoint dir, put the hash handle (a plain string, JSON-round-trip-safe) into the placeholder. Because the bytes live in a file and the checkpoint JSON carries only the handle, the lossy `Payload.of_json` path is **bypassed by construction** (the problem is relocated across the boundary, not patched). Checkpoints already persist as JSONL (`keeper_context_core.mli` §"JSONL persistence"), so the handle rides the existing persistence with no new serialization format.

This is a Phase-0b *design* prerequisite (resolve before Phase 1), not an Open Question.

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
- **Affordance dependence**: the keeper must decide to call the tool. That read/no-read choice is non-deterministic unless the workflow adds an explicit policy. For image-critical turns (for example "analyze this screenshot"), Phase 2 must either auto-call before completion or block completion until the image is read or explicitly marked intentionally skipped.
- **Two mechanisms coexist**: requires the persisted policy axis of §2.4. Without it the boundary is undecidable.
- Extraction quality is bounded by the vision model and the `query`; a poor query yields a poor description the main model cannot recover from without re-query.

## 4. Migration

- **Phase 0a (done)**: config correctness — declare true `supports-image-input` + `media_failover` (`jeong-sik/me` PR #1223, MERGED). Resolves the live incident; reroute lands on a capable cloud model. **Phases 1–3 are not required for the incident.**
- **Phase 0b (in progress)**: durable blob-backed input-side artifact store (§2.5) — **implemented**: `Multimodal.Vision_artifact_store` (content-addressed SHA-256 file store, content-verified on read, path-traversal-hardened against forged handles), PR #22257. The persisted mechanism-selection axis (§2.4) is still design-pending.
- **Phase 1 (started)**: `analyze_image` tool (§2.2, §2.6). The **pure contract is implemented** — `Multimodal.Vision_analyze.make_request`/`classify` (boundary input validation + empty/truncated failure typing that encodes the §2.2 contract and the §2.6 gemma4 measurement), PR #22257. The **impure shell remains**: the mid-turn provider sub-call (§2.6) and the tool registration/dispatch wiring. Opt-in; no ingestion change.
- **Phase 2**: ingestion interception (§2.3) at **both** entry sites + persisted checkpoint placeholder; main history becomes text-only. Eager extraction (§2.3-eager). Introduces **and consumes** the `multimodal_policy` axis (§2.4) — the transform fires only for `multimodal_policy = Delegate`; existing keepers default to `Inherit` (today's RFC-0265 reroute), so Phase 2 is a no-op until an operator opts a keeper in. Safe-by-default.
- **Phase 3**: set `multimodal_policy` defaults (flip `Inherit` toward `Delegate` where justified); scope RFC-0265's image/document reroute to keepers whose policy selects it. Edit RFC-0265 front-matter reciprocally in the same PR. The content→runtime coupling is additionally cut at the **type level** in a sibling PR: `supports_required_modality`'s `_ -> true` catch-all is replaced by a closed `modality` variant with exhaustive matches (CLAUDE.md anti-pattern §2+§4), so a future modality cannot silently default to permissive.

## 5. Verification

- **Unit**: `analyze_image` returns `Ok text` only for non-empty extraction text; `Error` on a missing artifact, vision sub-call failure, or empty/whitespace-only extraction. After ingestion, `required_modalities_of_messages (main history)` never contains `"image"` — asserted **after a checkpoint save+reload round-trip** (covers §2.3 site 2).
- **Durability**: store bytes, persist + reload a checkpoint, re-read the handle → bytes are non-empty and byte-identical (revert-red against the current lossy `Payload.of_json`).
- **Reroute non-fire**: a keeper with `multimodal_policy = delegate` given an image (post Phase 2) → `decide_modality_reroute_for_runtime` returns `No_reroute_needed` for subsequent text turns (revert-red: before Phase 2 it returns `Reroute`).
- **Integration**: image in → tool called → text result in history; a follow-up needing new detail triggers a second `analyze_image`. For image-critical prompts, a turn that never reads the placeholder must fail the configured auto-call/completion-gate policy rather than silently answering from text-only context.
- **TLA+ (optional, per repo bug-model pattern)**: invariant `NoRawImageInMainHistoryAfterIngestion`; `BugAction`s that leave the image inline at *either* entry site must violate it.

## 6. Workaround self-check (CLAUDE.md gate)

- Not telemetry-as-fix (no counter; it removes the failure path).
- **No in-tool silent success**: per §2.2, empty/whitespace extraction returns a typed `empty_extraction` error, not `Ok ""`. The tool cannot reproduce the 2026-06-25 empty-reply failure class one layer inward — the bug this RFC targets is not re-admitted by the fix.
- Not a string/substring classifier (uses the typed capability predicate + typed artifact handle).
- **N-of-M risk is real and must be closed, not asserted away** `[review: prior draft falsely claimed "no per-site patching"]`. Image entry has two sites (§2.3); the design avoids signature #3 **only if** the placeholder is enforced at ingestion *and* persisted into the checkpoint so rehydration cannot reproduce it. Phase 2 acceptance = both sites covered, proven by the save+reload unit test.
- The §2.3 transform is **write-time protocol-boundary enforcement**, deliberately not sanitize-on-read.
- **Repair-signature pre-emption**: a re-query hitting an empty `Lazy_payload` would invite a regenerate/cache-repair patch (the repair signature). §2.5 forecloses this by mandating durable bytes at design time, not deferring it.

## 7. Open questions

- ~~Auto-call on first image vs explicit keeper decision vs completion gate?~~ **Resolved (2026-06-25, §2.3-eager):** auto-call (eager extraction) at ingestion with an exhaustive query; the keeper re-reads via the handle only for uncaptured detail. No per-turn affordance gamble.
- **Retention/eviction of stored bytes (open):** the handle survives in the checkpoint independently of the bytes' file lifetime. Phase 2 ships with **no eviction** (bytes persist under the keeper's `.vision` dir); if the file is later GC'd, a re-read returns the typed `missing_artifact` error (not a silent empty) and the keeper still has the eager text. TTL/LRU is deferred.
- Should `document` (PDF) reuse the same tool or a sibling `analyze_document`?
- Does any current keeper genuinely need whole-turn native vision (→ `multimodal_policy = reroute`)?
- Blob store backend for §2.5: reuse `review_artifact_store.ml`'s helpers directly vs a sibling module; and the eviction/retention policy (when is a stored image garbage-collected — keeper end, TTL, or LRU on dir size?).
