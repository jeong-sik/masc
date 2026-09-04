# RFC-0414: A text-only keeper reads its image because a vision runtime is wired

Status: Draft
Relates to: RFC-0265 (graceful media degrade), RFC-keeper-vision-delegation, #33037 (deferred-lane degrade floor), #33034 (the failing cycle)

> Revision note: earlier drafts of this RFC chased a routing fix (ingest vs
> dispatch, "read at the floor") and guessed model caps. Live measurement moved
> the root: the model caps are largely accurate, and the real gap is that **no
> vision runtime was wired for the read**. Those earlier routing sections are
> withdrawn; what follows is the corrected picture.

## Problem

A text-only keeper (`ollama_cloud.ollama-cloud-deepseek-v4-flash-0731`,
`kidsnote-pr-jira-checker`) received a pasted image and could not use it. The
first symptom was a crash (#33034): the image reached the text-only judgement
model `glm:glm-5.3` and the multimodal gate rejected it. #33037 stopped the
crash by degrading — stripping the image and running text-only — but that
**drops** the image. Either way, vision does not work for the keeper.

## Root cause (measured, 2026-09-04)

Three facts, all measured on the live instance:

1. **`keeper_analyze_image` is `Operator_only`** (`keeper_tool_descriptor.ml:2109`),
   on the assumption the model has a vision builtin. A text-only keeper has no
   builtin *and* cannot call the hidden tool, so there is no keeper-side read.
2. **The server-side eager read is the only path, and it failed** ("vision read
   실패"). `keeper_vision_tool.ml:436` fails over through **every**
   `vision_runtime_candidates ()`, so the failure means *none* of them read the
   image.
3. **No vision runtime was wired for the read.** `[runtime].media_failover`
   (the designated vision read fleet) is empty in `config/runtime.toml`, and no
   local vision provider is configured — yet the operator's machine is serving
   two vision models on Ollama (`:11434`): `Qwen3.8-27B` and `Gemma-4-31B`, both
   natively multimodal. The candidates the read *did* try were cloud runtimes
   that this deployment does not actually read an image on.

The model caps in config are **largely accurate** — an earlier draft's
"over-declared pool" was wrong. Verified against vendor docs (2026-09-04): Gemma 4
(all sizes), Kimi K3, MiniMax M3, Mistral Large 3 (675B), Qwen3.5-397B, and
**GLM-5.3-Flash** are all natively multimodal. The only genuinely text-only entry
touched here is `glm-5.3` (non-Flash), which is what the judgement lane
dispatched to and what the gate correctly reported as `supported=text`.

## Fix

**Primary — prioritize a fast cloud vision runtime for the read.** Wire the
ollama_cloud vision models as the `media_failover` fleet so analyze_image's eager
read walks a known-fast vision model first:

```toml
[runtime]
media_failover = [
  "ollama_cloud.ollama-cloud-gemma4-31b",
  "ollama_cloud.ollama-cloud-glm-5-3-flash",
]
```

Both already declare image input. The eager read then resolves a runtime that
actually reads the image, carries its meaning as text (`[image read: … |
artifact:…]`), and the text-only keeper proceeds with the content instead of a
dropped-image notice.

**Why not local.** The operator's machine does serve vision GGUFs (Qwen3.8-27B,
Gemma-4-31B) on Ollama with the projector present — but a single read measured
**5+ minutes** under a machine load average of ~190 (the full keeper fleet plus
containers and microvms). Too slow to be usable, so local vision is not wired.

**Operational note.** The load average is the real drag: even a cloud read runs
through masc's pipeline on the loaded host. Reducing concurrent keepers /
containers / microvms is what makes vision (and the fleet) responsive; the
`media_failover` wiring only ensures a fast model is *tried first*. masc also
sends images at full resolution (`max_image_bytes` rejects, it does not
downscale) — a downscale pass is a separate cost/latency win, tracked apart.

**Retained safety floor.** #33037 stays: when *no* vision runtime can read the
image, the deferred lane degrades (drops with a notice) rather than crashing.

**Secondary refinement (optional).** With a working read in place, the ingest
evict-vs-keep decision (`delegates_media`) can be made deferred-aware so a
deferred-committed text-only runtime evicts (reads) rather than keeping an image
it cannot reroute. This only matters once a read actually succeeds; without a
wired vision runtime it is moot.

## Verification

1. With `media_failover` wired to the local Ollama vision fleet, the same
   text-only keeper's image turn produces a **reading** in the turn text (not a
   dropped-image notice), and the read outcome is `Vo_ok`, not `Vo_no_runtime`.
2. Config loads (`masc` starts, the new provider/model/runtime resolve).
3. The #33037 degrade still fires when the local vision fleet is down (read
   returns no runtime → drop, not crash).

## Boundaries

- Do not re-declare caps by guessing; the caps here were verified against vendor
  docs and are mostly accurate already.
- The wiring is deployment config, not a code change; the routing refinement is
  a separate, later change and is not required for vision to work.
