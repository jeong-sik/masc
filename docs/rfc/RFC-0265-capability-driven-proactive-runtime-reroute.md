---
rfc: "0265"
title: "Capability-driven proactive runtime reroute (modality-gated)"
status: Draft
created: 2026-06-19
updated: 2026-06-25
author: jeong-sik
supersedes: []
superseded_by: null
superseded_sections: []
related: ["0207", "0181", "0126", "0145", "0037", "0260", "0211", "0206", "0001"]
draft_amendments: ["RFC-keeper-vision-delegation-tool"]
implementation_prs: []
---

# RFC-0265 — Capability-driven proactive runtime reroute (modality-gated)

- Status: Draft
- Date: 2026-06-19
- Builds on: RFC-0207 (per-keeper runtime routing), RFC-0181 (capability-intent
  runtime SSOT), RFC-0126/0145 (silent-fallback discipline), RFC-0037
  (board multimedia/vision).
- Amended by (draft, 2026-06-25): `RFC-keeper-vision-delegation-tool` proposes to
  partially supersede the **image/document** modality path with vision-as-a-tool
  delegation (decouple "which model reads the image" from the conversation
  runtime). Reciprocal of that draft's `supersedes-partial` claim so the
  relationship is discoverable from both sides (avoids the one-sided-supersedes
  blind spot in RFC tooling).

## 0. Summary

When a keeper turn carries non-text input (image/audio/document) but the
keeper's assigned runtime cannot accept that input modality, the dispatcher
today **fails the whole turn loudly** at the pre-dispatch capability gate
(`Runtime_agent.validate_content_blocks_for_config`,
`lib/runtime/runtime_agent.ml`). The error is correct (fail-closed before a
provider 400 can leak back) but terminal: the operator's image-bearing message
is dropped with `Invalid config 'multimodal_input': provider … cannot accept
requested multimodal input`.

This RFC adds a **proactive, deterministic reroute**: before dispatch, if the
assigned runtime's declared input capabilities do not satisfy the turn's
*required* modalities, the turn is rerouted to the first configured runtime that
*does* satisfy them, selected by a deterministic policy, with the reroute made
visible (not silent). If no configured runtime satisfies the modality, the
existing loud rejection stands as the floor.

## 1. Problem

2026-06-19: a RunPod provider outage caused the operator to fail the fleet over
to `ollama_cloud` models. Several keepers (`analyst`, `garnet`, `rondo`,
`verifier`, fusion `judge`) were assigned `ollama_cloud.deepseek-v4-pro`, which
is text-only — verified across nine independent sources:

- live `runtime.toml` `/api/show` comment (2026-06-17): `caps=[completion,tools,thinking]`;
- the model's `[models.deepseek-v4-pro].capabilities` block is absent
  (→ `model_capabilities_default.supports_image_input = false`,
  `lib/runtime/runtime_schema.ml`);
- the OAS catalog entry (`oas/models.toml`) declares no `supports_image_input`;
- the official ollama model card (`ollama.com/library/deepseek-v4-pro`):
  capabilities `Tools, Thinking, Cloud`, Text input only, 1M ctx;
- DeepSeek V4 ships a *separate* Vision mode (Fast/Expert/Vision); `…-pro` is the
  Expert (text) mode, not the Vision model (DeepSeek-VL2 is the VL line).

An operator then sent an **image-bearing** `masc_keeper_msg` to one of those
keepers. `Keeper_turn.user_oas_blocks_of_args` (`lib/keeper/keeper_turn.ml`)
converted the attachment into an OAS image content block; at dispatch the
capability gate rejected it because `deepseek-v4-pro` declares no image support.
The turn died with no answer.

The mismatch is **structural and known before the request is built** — it is not
a transient error. The inventory *did* contain capable models at that moment
(`kimi-k2.7-code` and `minimax-m3` both report `vision` in `/api/show`), but nothing
routed the image turn to them.

## 2. Why this is not RFC-0207 Part B

RFC-0207 §6 defines Part B as **reactive ordered failover**: on a *recoverable
error* at the provider, rotate to the next runtime in a per-keeper ordered list,
implemented in the contended `keeper_error_classify.ml` `degraded_rotation`
lane.

This RFC is a different concept:

| Axis | RFC-0207 Part B (reactive) | RFC-0265 (proactive) |
|------|----------------------------|----------------------|
| Trigger | provider returned a recoverable error | input modality the assigned model structurally cannot accept |
| Timing | after a failed attempt | before the request is built |
| Determinism | depends on runtime error | deterministic from turn content + declared caps |
| Site | `keeper_error_classify.ml` (contended) | capability-gate site (`runtime_agent.ml` / keeper pre-dispatch) |

Because the reroute decision is a pure function of (required modalities, declared
runtime capabilities, config order), it does not touch the reactive lane and
carries none of that file's broken-main-history risk. The two are complementary:
0265 prevents a knowably-impossible dispatch; 0207-B retries a recoverable one.

## 3. Design

### 3.1 Reroute decision (pure)

```
decide_modality_reroute
  ~assigned_runtime_id          (* the per-keeper routed id, RFC-0207 Part A *)
  ~required_modalities          (* from required_modalities_of_content_blocks *)
  ~candidates                   (* ordered (runtime_id, model_capabilities) list *)
  : reroute_decision
```

where

```
type reroute_decision =
  | No_reroute_needed            (* assigned runtime satisfies all required modalities *)
  | Reroute of { to_runtime_id : string; reason : string }
  | No_capable_runtime of { required : string list }   (* floor: loud reject *)
```

Rules:

1. If `assigned` satisfies every required modality → `No_reroute_needed`
   (the common case; text turns and vision-capable keepers are untouched).
2. Else, scan `candidates` in order; the first whose declared capabilities
   satisfy **all** required modalities → `Reroute`.
3. Else → `No_capable_runtime` (the dispatcher keeps the current loud
   `multimodal_capability_error`, with a message that names the required
   modality and that no configured runtime declares it).

The modality predicate reuses the existing
`Runtime_agent.supports_required_modality` /
`required_modalities_of_content_blocks`. No new capability vocabulary.

### 3.2 Candidate ordering (deterministic)

`candidates` is derived, in this precedence:

1. **Explicit** `[runtime].media_failover` — an optional ordered list of runtime
   ids (operator SSOT, parsed/validated at load exactly like `[runtime].librarian`
   and `[runtime.assignments]`; an id that does not resolve to a configured
   runtime is a load error, no silent drop — RFC-0206 §2.1, RFC-0211 SSOT).
2. **Implicit fallback** when `media_failover` is unset: every configured runtime
   whose declared `model.capabilities` is non-default for any non-text modality,
   in **runtime.toml declaration order**.

Both are deterministic; selection never consults provider liveness or wall-clock,
so two identical turns reroute identically. Liveness-aware skipping (e.g. avoid a
candidate whose provider is currently down) is **out of scope** and deferred to
RFC-0260 (provider health gate); §7.

### 3.3 Visibility (non-silent — RFC-0126/0145)

A reroute is recorded, never silent. v1 (this PR) emits a structured `WARN` log
at the dispatch site (`keeper_turn_driver.run_named`):

```
<keeper>: RFC-0265 modality reroute <assigned> -> <chosen> (<reason>)
```

Deferred follow-up: a typed `Runtime_observation.runtime_fallback_event`
(`record_fallback_event`, tagged `modality_reroute`) and a keeper-chat-surfaced
note so the dashboard shows which model actually answered. The WARN log satisfies
the non-silent floor now; the richer surfaces improve operator ergonomics later.

This satisfies the silent-fallback-elimination discipline: the assignment SSOT
still says X, but the operator can see that this specific media turn ran on Y and
why.

### 3.4 Boundary & determinism

- MASC-side only. OAS (`agent_sdk`) is untouched: the modality vocabulary and
  declared caps already live in MASC's `runtime_schema` / `runtime_agent`
  (`apply_runtime_model_input_capabilities` already treats MASC `model.capabilities`
  as the media-input SSOT, overriding provider-level caps).
- persona ⊥ {model, runtime} preserved: the reroute target is chosen from config
  order + declared capabilities, never from persona JSON.
- Deterministic: pure function of turn content + config; no randomness, no I/O.

## 4. Config surface

New optional key in `runtime.toml`:

```toml
[runtime]
# When a turn's input modality exceeds the assigned runtime's declared
# capabilities, reroute the turn to the first runtime here that can accept it.
# Unset → derive capable runtimes from declared [models.*.capabilities] in
# declaration order. Each id must resolve to a configured runtime (load error
# otherwise).
media_failover = ["ollama_cloud.kimi-k2-7-code", "ollama_cloud.minimax-m3"]
```

### 4.1 Prerequisite — declare media capabilities accurately (config, not code)

The reroute can only pick a runtime whose `model.capabilities` *declares* the
modality. The vision-capable cloud models must not be under-declared:

- `[models.minimax-m3.capabilities]` declares JSON/structured-output only —
  **no `supports-image-input`** (yet `/api/show` reports `vision`).
- `[models.kimi-k2-7-code.capabilities]` must retain `supports-image-input` and
  `supports-multimodal-inputs`.

Until those declarations match `/api/show`, no candidate qualifies and the floor
(loud reject) fires. This is the same capability-declaration discipline that
governs the memory-os librarian routing — declared caps are the SSOT, and they
must match the provider's actual `/api/show`. Adding
`supports-image-input = true` (and `supports-multimodal-inputs = true` where the
provider accepts media) to those `.capabilities` blocks is the precondition. To
keep it accurate without hand-maintenance, §4.2 generates the declarations from
`/api/show` and gates drift.

### 4.2 Capability sync + drift gate (generated truth-source)

`scripts/masc-sync-ollama-caps.py` keeps the declared media caps aligned with
what Ollama actually reports, without putting a network probe on the runtime
path (the runtime stays static/deterministic per §3.4):

- `--refresh` (operator; needs network + `OLLAMA_CLOUD_API_KEY`) — `POST
  {provider.endpoint − /v1}/api/show {"model": <api-name>}` for every
  Ollama-family model in the config and (re)writes the baseline snapshot
  `scripts/ollama-caps-baseline.json`.
- `--check` (CI; no network) — compares each config-declared media flag against
  the baseline. Hard-fails on `UNDER-DECLARED` (a vision model whose config
  omits `supports-image-input` → reroute can't see it), `OVER-DECLARED`
  (config claims a modality the model lacks → provider 400 at dispatch), or
  `UNVERIFIED-DECLARED` (config declares image/audio but the model has no
  `/api/show` evidence in the baseline). The last case closes the loop: a media
  capability is valid only when backed by a baseline snapshot, so adding a vision
  model to the config without refreshing the baseline fails CI instead of passing
  on a soft warning (the gap that let a 31-model config expansion through
  unverified). A *text-only* model absent from the baseline is fail-closed safe
  and only soft-warns (`--strict` fails those too). Wired into
  `.github/workflows/ci.yml`.
- `--emit` — prints the recommended `[models.<id>.capabilities]` media lines for
  the operator to merge into the live `runtime.toml`.

Mapping (source: ollama `types/model/capability.go`, verified against live
`/api/show` 2026-06-19): `vision`|`image` → `supports-image-input`; `audio` →
`supports-audio-input`. `supports-multimodal-inputs` is intentionally **not**
derived: MASC maps it to the `document` modality (§3.1
`supports_required_modality "document" -> supports_multimodal_inputs`), and
`/api/show` reports no document/multimodal capability string — only
vision/image/audio. Deriving `multimodal` from `vision` would make the gate
*admit* a document turn to an image-only model (a fail-open the gate exists to
prevent). Document support therefore stays an explicit operator declaration that
the script neither emits nor checks; it manages only the image/audio flags
`/api/show` evidences.

Two drift levels are both covered: *config vs baseline* by `--check`
(deterministic, CI) and *baseline vs `/api/show`* by `--refresh` (surfaces as a
reviewable baseline diff). This is the "generated truth-source + drift-gate"
pattern; it deliberately does **not** derive caps at runtime.

**Rejected alternative — derive in OAS discovery.** OAS already probes
`/api/show` (`lib/llm_provider/discovery.ml`), but its derived `capabilities`
reach no runtime path: the shared discovery atomic stores only
context/endpoints, `provider_registry` reads `healthy`/`url` only, and
`capabilities_to_json` has zero callers in `lib/`/`test/`/`examples/`. Extending
that probe to parse the `capabilities` array would add code to a dead path, so
the `/api/show` → flag mapping lives in the sync script (where it is consumed)
and OAS is left untouched — preserving the MASC/OAS boundary with zero OAS
change.

## 5. As-built surface

- `Runtime_agent.reroute_decision` type + `decide_modality_reroute` (pure) +
  `decide_modality_reroute_for_runtime` (gathers candidates from the runtime
  cache, then decides) + `input_capabilities_of_runtime` /
  `media_reroute_candidates` helpers; all surfaced in `runtime_agent.mli`.
- The accept predicate `caps_admit_required_modalities` is extracted and shared by
  both `validate_content_blocks_against_capabilities` (the gate) and the reroute
  decision, so a runtime the reroute picks is exactly one the gate would admit.
- `Runtime.media_failover : unit -> string list` + `validate_media_failover`
  load-time validation in `materialize_config` / `load_list` / `init_default`
  (mirrors `librarian_runtime_id`); `media_failover : string list` added to
  `Runtime_schema.config`; parsed in `lib/runtime/runtime_toml.ml`. `load_list`
  becomes a 6-tuple.
- Keeper dispatch (`keeper_turn_driver.run_named`, the single-runtime seam): for a
  turn with content blocks, consult `decide_modality_reroute_for_runtime`; on
  `Reroute`, rebind `runtime_id`/`runtime` to the chosen runtime (the existing
  downstream candidate/config construction follows) and emit the WARN log; on
  `No_reroute_needed`/`No_capable_runtime`, keep the assigned runtime (the loud
  gate in `run_blocks` rejects when no runtime qualifies). Text turns
  (`goal_blocks = None`) are untouched.
- No OAS change. No `keeper_error_classify.ml` change.

## 6. Tests

`test/test_runtime_modality_reroute.ml` (7 cases, pure — no `Runtime.init_*`
since the decision takes the candidate list as data):

1. text-only turn (required = []) → `No_reroute_needed`;
2. image turn on a vision-capable runtime → `No_reroute_needed`;
3. image turn on a text-only runtime with capable candidates → `Reroute` to the
   first capable id, skipping the text-only candidate;
4. candidate ordering honoured (first listed capable wins — pins
   `media_failover` precedence);
5. image turn with **no** capable candidate → `No_capable_runtime` (floor);
6. determinism: identical inputs → identical decision;
7. `caps_admit_required_modalities`: all-supported multi-modality admits, a
   missing modality rejects, empty required always admits.

`load_list` 6-tuple consumers (`test_runtime_config_validity`,
`test_runtime_provider_auth_headers`) updated and green; the capability-gate suite
(`test_gate_keeper_backend.ml`, 52 cases) is unchanged by the
`caps_admit_required_modalities` extraction. Load-time `media_failover`
id-resolution validation (`validate_media_failover`) follows the existing
`librarian`/`cross_verifier` pattern (covered by the runtime-config validity
suite's pattern); `dune build lib` green.

## 7. Non-goals / deferred

- **Liveness-aware reroute** (skip a capable-but-down candidate, prefer RunPod
  when healthy): deferred to RFC-0260 (provider health gate). 0265 picks the
  first *capability*-satisfying candidate deterministically; 0260 can later
  filter the candidate list by health before 0265 selects.
- **Reactive error failover**: remains RFC-0207 Part B.
- **Output-modality** routing (image generation): out of scope; this RFC is
  input modality only.

## 8. Migration

Zero migration for the code: with `media_failover` unset and no extra capability
declarations, behaviour is identical to today (floor reject). The feature
activates only once (a) capable models declare their media caps (§4.1) and
optionally (b) `media_failover` is set. Live `runtime.toml` is operator-owned;
deployment (declarations + restart) is an operator step.
