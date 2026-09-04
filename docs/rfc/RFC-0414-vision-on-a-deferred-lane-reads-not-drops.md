# RFC-0414: Vision on a deferred lane reads the image, it does not drop it

Status: Draft
Relates to: RFC-0265 (graceful media degrade), RFC-keeper-vision-delegation, #33037 (deferred-lane degrade floor), #33034 (the failing cycle)

## Problem

An analyst keeper cycle with an attached image failed:

```
keeper cycle FAILED runtime=kimi_coding.kimi-k3-256k
error=Invalid config 'multimodal_input': provider glm:glm-5.3 cannot accept
requested multimodal input: unsupported image input (required=image supported=text)
```

#33037 stopped the crash: a deferred lane now runs the RFC-0265 degrade floor, so the image is **stripped and the turn runs text-only**. That removes the crash but **drops the image** — vision does not "work", it is silently discarded (with a notice). The operator's question stands: the image was requested from a text-only model, and now it is thrown away.

## Root cause (cross-stage timing)

The evict-vs-keep decision for an attached image is made at **turn assembly (ingest)**, before dispatch:

- `lib/keeper/keeper_turn.ml:461` calls `Keeper_vision_ingest.evict_blocks ~mode:Eager ~delegate:(delegates_media ~runtime_id:(runtime_id_of_meta meta))`.
- `delegates_media ~runtime_id` (`keeper_vision_ingest.ml:253`) resolves the *lane* and evicts only when **no** candidate takes images. If any candidate is image-capable it keeps the image, on the assumption "dispatch's RFC-0265 reroute will route to that candidate and the model sees pixels" (`keeper_turn.ml:453-458`).

Dispatch then breaks that assumption for a **deferred lane**: `keeper_turn_driver.ml` forces the modality decision to the degrade floor (deferred lanes commit to one runtime and cannot reroute — `remaining_runtimes = []`, see #33037). So a deferred-committed **text-only** runtime whose lane *did* contain an image-capable sibling gets:

- ingest: keeps the image (a sibling could take it), and
- dispatch: cannot reroute to that sibling, so it strips the image.

Neither the eager read nor the reroute runs. `meta` carries no deferred field (`runtime_id_of_meta : keeper_meta -> string`), so ingest cannot tell it is on a deferred lane and cannot make the right call there.

## What already exists (measured)

The read path is built and, with an image-capable runtime configured, works:

- `Keeper_vision_tool.vision_runtime_candidates ()` selects image-capable runtimes with the **same predicate the dispatch gate uses** (`caps_admit_required_modalities`), so a vision pick never lands on a runtime the gate rejects (`keeper_vision_tool.ml:78-115`). `first_vision_runtime_id ()` returns `Error "no image-capable runtime configured"` only when there is none.
- `analyze_image` (`Tool_analyze_image`, `keeper_tool_in_process_runtime.ml:2068`) delegates to `lib/multimodal/vision_analyze`.
- Ingest eager read: `evict_blocks ~mode:Eager`, capped `max_eager_reads_per_turn = 1`, produces `"[image read: … | artifact:…]"`; on no read, `"[image artifact:… - …; call analyze_image to read it]"`.
- `config/runtime.toml` declares image-capable runtimes (lines 578, 599, 717, 750, 774, 803, 912, 998, 1052).

So the meaning of an image can be carried as text without any new subsystem.

## Options

**A — modality-aware assignment.** Make the runtime assignment (where the deferred lane is budgeted) prefer an image-capable runtime when the turn's input contains an image, so the committed runtime sees the pixels. Best result (pixels beat a reading) but changes an earlier stage than ingest and must thread the turn's modality into the assignment decision.

**B — read at the deferred floor.** At the deferred `No_capable_runtime` floor (where #33037 strips the image), instead of dropping it, carry its meaning as text — either eager-read it there (reuse `evict_blocks ~mode:Eager`) or leave the `image_unread_placeholder` so the keeper calls `analyze_image` itself. Localized to the floor, reuses the existing read path, and does not touch the non-deferred reroute.

**C — ingest evicts on the first candidate only (rejected).** Make `delegates_media` evict whenever the first/committed candidate cannot take images. This **regresses** non-deferred lanes: a text-first, vision-second lane would read the image instead of rerouting to see the pixels. Not acceptable.

## Recommendation

Ship **B** first, keep **A** as a follow-up.

- B is localized, reuses a measured read path, and cannot regress non-deferred vision.
- Minimal B (**B2**): at the deferred floor, replace the strip-drop with the `image_unread_placeholder` and confirm `analyze_image` is in the keeper's tool surface, so the keeper reads on demand. No net/clock plumbing at the dispatch seam.
- Fuller B (**B1**): eager-read at the floor for a one-call reading in the same turn — needs the vision tool's `sw`/`clock`/`net` context available at the dispatch seam; do it only if that context is already threaded there.
- A later, when the assignment can be made modality-aware, so an image turn commits to a vision runtime and sees pixels.

## Implementation sketch (B2)

- At the deferred branch that reaches the degrade floor (`keeper_turn_driver.ml`, the path added in #33037), when the dropped modality is `image` and a vision runtime exists (`first_vision_runtime_id` is `Ok`), replace the stripped block with `image_unread_placeholder` instead of removing it, and keep the degrade manifest row (the drop is still non-silent).
- Verify the analyst keeper's tool surface includes `analyze_image`; if a text-only keeper does not surface it, surface it whenever the turn carried image input.

## Verification (measured, not asserted)

1. A deferred-lane keeper with an attached image runs without the multimodal crash **and** without silently dropping the image: the turn text contains the reading or the `call analyze_image` placeholder, and a follow-up `analyze_image` returns `Vo_ok` (not `Vo_no_runtime`).
2. Non-deferred image turns are unchanged: a text-first/vision-second lane still reroutes and the model sees pixels (no reading substituted).
3. With no image-capable runtime configured, the floor still degrades (drops) rather than looping on a read that cannot resolve.

## Implementation finding (2026-09-04)

Starting B revealed a gap in the sketch: **the floor cannot read without an
artifact**. The eager read produces `"[image read: … | artifact:…]"` because
ingest **stored** the image first; but ingest only stores on the evict branch
(`delegates_media = true`). In the deferred-keep case ingest kept the raw block
and stored nothing, so at the floor there is no artifact for `analyze_image` to
retrieve. B2's placeholder would point at nothing — it degrades to a
better-worded drop, not a working read.

Two ways to actually read, both heavier than the sketch:

- **B-store-at-floor.** At the deferred floor, store each dropped image to the
  `<keeper>.vision` artifact store (the bytes are in hand) and substitute
  `image_unread_placeholder` with that handle. Localized to
  `keeper_turn_driver`, but needs a reusable "store one image block → handle"
  entry from `keeper_vision_ingest`/`keeper_vision_tool` (today the store is
  internal to `evict_block`).
- **A'-ingest-aware (preferred for correctness).** Thread the deferred committed
  runtime into ingest so `delegates_media` evicts (store + eager read) when the
  committed runtime is text-only: `delegate = not (runtime_takes_images_itself
  committed)` for a deferred turn, lane-based otherwise. Reuses the whole ingest
  eviction, but `deferred_runtime_lane` (`keeper_unified_turn.ml:400`) reaches
  the ingest site (`keeper_turn.ml:374 run_keeper_invocation_turn_admitted_inner`)
  only through intermediate layers, so it is a multi-signature thread through
  delicate keeper-runtime code.

Neither is the one-line the first sketch implied. Both touch core keeper-runtime
(TLA-adjacent), so the implementation is scoped as its own careful change, not
folded into the floor edit from #33037.

Revised recommendation: **A'-ingest-aware** as the correct read path (it reuses
store + read and keeps the floor a pure drop for the truly-no-vision-runtime
case), with **B-store-at-floor** as the lighter alternative if the ingest thread
proves too invasive. C stays rejected.

## Live finding (2026-09-04, kidsnote-pr-jira-checker) — invalidates B's placeholder

A live text-only keeper (`ollama_cloud.ollama-cloud-deepseek-v4-flash-0731`)
received a pasted image and reported, in its own turn:

> vision read 실패 + analyze_image 접근 불가 … keeper_analyze_image가 operator_only로
> 표시 … (operator_only, not_model_invocable)

Two facts the sketch got wrong:

1. **`keeper_analyze_image` is `Operator_only` by design** (`keeper_tool_descriptor.ml:2109`): "the model has its own analyze_image builtin … hiding it takes its schema off every keeper turn." That reasoning assumes a **vision-capable model**. A text-only keeper has no builtin *and* cannot call the hidden tool — so **B2's "call analyze_image" placeholder points at a tool the keeper cannot invoke**. B2 is invalid for exactly the keepers this RFC is about.
2. **The eager read itself failed** ("vision read 실패"). The eager read is the *only* path left for a text-only keeper, and it did not produce a reading. Likely causes, in order of suspicion: no reachable image-capable runtime (config declares `supports-image-input = true` on e.g. `kimi-for-coding` at runtime.toml:717, but a coding model rejecting an image would fail the read), or `media_failover` is unset (no `media-failover` key in `config/runtime.toml`) so `vision_runtime_candidates` falls back to possibly over-declared main-list caps.

So the problem is deeper than "deferred drops the image": for a text-only keeper there is **no working read path at all** — the model can't see pixels, the eager read fails, and the tool is operator-only.

### Revised direction

The floor/ingest edits (A'/B-store) are moot until a **read actually succeeds**. The gating question is runtime, not routing:

1. **Is any image-capable runtime actually reachable, and are its caps accurate?** Verify `first_vision_runtime_id ()` resolves to a runtime the provider will accept an image on (probe it — the "vision read 실패" says the current pick does not work). Fix over-declared `supports-image-input` caps, or configure a real `media-failover` vision fleet.
2. **Then** the eager read carries the image's meaning as text at ingest, and the deferred floor never sees an image. A' (ingest-aware evict for a deferred-committed text-only runtime) becomes the routing fix on top of a working read.
3. Only if a text-only keeper must read on demand does surfacing `analyze_image` to it (making `keeper_model_projection` conditional on the runtime lacking image input) come into play — and it still needs a working vision runtime.

C stays rejected. B2 (placeholder → keeper calls analyze_image) is **withdrawn** — the tool is not model-invocable.

## Boundaries

- Do not change the ingest `delegates_media` decision for non-deferred lanes.
- Do not add a deferred field to `meta` solely to move this decision to ingest; the floor already knows it is deferred.
- No new "vision runtime" selection logic — reuse `vision_runtime_candidates` / `first_vision_runtime_id`.
