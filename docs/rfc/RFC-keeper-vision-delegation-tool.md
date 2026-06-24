---
title: "Vision-as-a-tool delegation (decouple multimodal input from conversation runtime)"
status: Draft
supersedes-partial: RFC-0265 (image/document modality path)
---

# RFC — Vision-as-a-tool delegation

- Status: Draft
- Relationship: amends/partially supersedes RFC-0265 (capability-driven proactive runtime reroute) for the **image/document** modality.
- Origin: 2026-06-25 incident — a keeper assigned a vision-capable cloud model (`minimax-m3`) still failed image follow-ups with `keeper turn completed with no textual reply` and slow responses.

## 0. Summary

When a keeper turn carries an image, RFC-0265 reroutes the **entire turn** to a different runtime that declares image capability. This RFC proposes an alternative for the image/document case: **delegate the multimodal read to a vision runtime through a keeper tool**, return a text result, and keep the main keeper on its assigned runtime. The raw image lives only inside the tool sub-call; the main conversation history stays text-only.

## 1. Problem

The reroute model couples "which model reads the image" with "which model runs the whole conversation". Observed consequences (2026-06-25 incident, root cause confirmed adversarially + by live probe):

1. **Whole-runtime swap**. A text-strong persona keeper loses its assigned model for the turn; conversely a vision turn drags persona/tooling onto whatever runtime declares image support.
2. **Sticky reroute**. The image persists in re-sent history (`keeper_turn_driver.ml` includes `initial_messages` in the modality computation — intentionally, to avoid provider-400 on the re-sent image). So **every** later text-only follow-up recomputes `required=['image']` and re-reroutes.
3. **Full base64 re-send each turn**. Because the image is never image-aware-evicted from history, the inline payload is re-serialized on every subsequent turn → latency and token cost grow per turn.
4. **Lands on whatever single runtime declares the capability**. In the live config that was the local `gemma4-26b-a4b-qat` (`max-concurrent=1`, Q4 GGUF) — slow, and it returned empty text → `keeper_tool_response.ml:12` `no textual reply`.
5. **Capability misdeclaration is silent and catastrophic**. The incident's proximate cause was a missing `supports-image-input` key (fixed in `jeong-sik/me` PR #1223), but the *architecture* amplified a one-line config gap into a full keeper outage because reroute is the only lever.

RFC-0265 §1 itself frames the goal as "the image must reach a model that can read it." Delegation satisfies that goal without conflating it with the conversation runtime.

## 2. Design

### 2.1 Boundary (deterministic vs non-deterministic)

| Concern | Kind | Owner |
|---|---|---|
| Artifact storage / handle lookup | deterministic | `lib/multimodal` artifact store (exists: `artifact.mli`, `workspace.ml`) |
| Tool dispatch + which vision runtime to call | deterministic | new tool handler |
| The extraction text (what the image "says") | non-deterministic | the vision runtime sub-call |
| Main conversation reasoning | as assigned | the keeper's own runtime |

The raw image bytes cross into the vision sub-call **only**. The main keeper conversation never holds an `Image` content block.

### 2.2 Tool: `analyze_image`

- Input: `{ artifact: <handle>, query: string }`. `query` lets the keeper ask a specific question ("what is in the top-left?", "transcribe the text", "describe the chart").
- Behavior: load the artifact, build a one-shot message `[Text query; Image artifact]`, dispatch to a configured **vision runtime** (a sub-call, not a reroute of the main turn), return the assistant text as the tool result.
- Failure is a **tool error** (typed `Result`), localized to the tool call — not a whole-turn `no textual reply`. The keeper can retry, ask differently, or proceed.

### 2.3 Ingestion interception (write-time, not read-time)

When a keeper receives an image:
1. Store it once in the artifact store → get a handle.
2. Replace the inline `Image` block in the turn/history with a typed text placeholder `[image artifact:<handle> — call analyze_image to read it]`.
3. Surface `analyze_image` in the keeper's tool set.

Doing the `Image → placeholder` transform **at ingestion (protocol boundary)** — not as a sanitize-on-read — is the typed, root form. It directly removes causes #2 and #3: no image in re-sent history → no sticky reroute, no base64 re-send.

### 2.4 Vision runtime selection

The vision sub-call targets a runtime whose model declares `supports-image-input=true` (post-PR-#1223: `minimax-m3`, `kimi-k2-6`; not the local `gemma4` unless explicitly preferred). Selection reuses `Runtime_agent.caps_admit_required_modalities` so the existing capability SSOT remains the single source of truth. An ordered preference list (analogous to RFC-0265 `media_failover`) chooses among capable vision runtimes; default prefers fast cloud runtimes over single-slot local ones.

## 3. Trade-offs

**Pros**
- Main keeper runtime unchanged → persona/tools/context preserved.
- No sticky reroute; no per-turn base64 re-send (latency/cost bounded).
- Vision failures are isolated tool errors, not turn-fatal `no textual reply`.
- A single config gap can no longer route an entire keeper to a weak model.

**Cons / limits**
- **Lossy by default**: the main model sees the extraction text, not pixels. Follow-ups needing *new* image detail require a re-query (extra tool call + latency). For pixel-precise multi-turn reasoning, a vision-native keeper (or RFC-0265 reroute) is still better — delegation does not replace that case.
- **Affordance dependence**: the keeper must decide to call the tool. Needs prompt/affordance work and possibly an auto-call on first image.
- **Two mechanisms coexist**: delegation (default for image/document on text-runtime keepers) vs RFC-0265 reroute (retained where whole-turn native-vision semantics are required). The policy boundary must be explicit to avoid ambiguity.
- Extraction quality is bounded by the vision model and the `query`; a poor query yields a poor description that the main model cannot recover from without re-query.

## 4. Migration

- **Phase 0 (done)**: config correctness — declare true `supports-image-input` (`jeong-sik/me` PR #1223). Unblocks the live incident immediately; makes reroute land on a capable cloud model rather than failing.
- **Phase 1**: add the artifact store handle + `analyze_image` tool delegating to a vision runtime (sub-call). No ingestion change yet — opt-in tool.
- **Phase 2**: ingestion interception (§2.3) — `Image → placeholder + handle`; surface the tool; main history becomes text-only.
- **Phase 3**: scope RFC-0265's image/document reroute to "explicitly vision-native keepers"; delegation is the default for text-runtime keepers.

## 5. Verification

- **Unit**: `analyze_image` returns `Ok text` on a valid artifact; `Error` (typed) on a missing artifact or vision sub-call failure. After ingestion interception, `required_modalities_of_messages (main history)` never contains `"image"`.
- **Reroute non-fire**: a text-runtime keeper given an image (post Phase 2) → `decide_modality_reroute_for_runtime` returns `No_reroute_needed` for subsequent text turns (revert-red: before Phase 2 it returns `Reroute`).
- **Integration**: text-runtime keeper, image in → tool called → text result in history; a follow-up question needing new detail triggers a second `analyze_image`.
- **TLA+ (optional, per repo bug-model pattern)**: invariant `NoRawImageInMainHistoryAfterIngestion`; a `BugAction` that leaves the image inline must violate it.

## 6. Workaround self-check (CLAUDE.md gate)

- Not telemetry-as-fix (no counter; it removes the failure path).
- Not a string/substring classifier (uses the typed capability predicate + typed artifact handle).
- Not N-of-M (a single mechanism covers all image/document turns; no per-site patching).
- The §2.3 `Image → placeholder` transform is **write-time protocol-boundary enforcement**, deliberately not sanitize-on-read — avoiding the repair/sanitize signature flagged for the read-side variant (Option C in the incident triage).

## 7. Open questions

- Auto-call on first image vs explicit keeper decision?
- Where do artifacts live for multi-turn re-query, and what is their lifetime/eviction policy?
- Should `document` (PDF) reuse the same tool or a sibling `analyze_document`?
- Does any current keeper genuinely need whole-turn native vision (and thus must stay on the RFC-0265 reroute path)?
