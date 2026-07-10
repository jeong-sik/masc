# RFC: Keeper media-degrade floor (graceful drop at the RFC-0265 reroute floor)

- Status: Draft
- Author: vincent (+ Claude Opus 4.8)
- Created: 2026-06-25
- Builds on: RFC-0265 (capability-driven proactive runtime reroute) — this is its follow-up
- Related: RFC-0037 (board multimedia/vision), RFC-0126/0145 (silent-fallback discipline)
- Implementation: this PR (`lib/runtime/runtime_agent.{ml,mli}`, `lib/keeper/keeper_turn_driver.ml`, `test/test_runtime_modality_reroute.ml`)

## 1. Summary

RFC-0265 routes a media turn whose modality the assigned runtime cannot accept to
a capable runtime, and when **no** configured runtime qualifies it keeps the
assigned runtime so the loud capability gate in `Runtime_agent.run_blocks`
**terminally rejects** the turn (`No_capable_runtime` → floor). The reject is
correct (fail-closed before a provider 400) but terminal: the keeper turn dies,
and a keeper that keeps re-attempting an image-bearing turn parks in
`pause_human`.

This RFC changes only the **floor**: at `No_capable_runtime`, instead of letting
the turn die, strip the unsupported media blocks from the dispatch view (current
goal + prior `initial_messages` + resumed checkpoint), emit a degraded
`Runtime_routed` manifest row, inject one model-input notice, and proceed on
text. Reroute and modality-satisfied turns are untouched. MASC-side only; no OAS
change.

## 2. Problem

Keeper `sangsu` was routed to text-only models (`devstral-small-2:24b` via
`glm-coding`/`ollama_cloud`) and received image input. The RFC-0265 floor would
reject the turn terminally; observed live, the keeper recorded
`api_error_invalid_request` / `operator_disposition: pause_human` repeatedly
(`<base-path>/.masc/keepers/sangsu/execution-receipts/2026-06/{20,23}.jsonl`). For an
autonomous keeper, a paused turn on a recurring history-borne image is worse than
a degraded text turn: the keeper makes no progress until a human intervenes.

The operator's intent (selected for this change) is **keeper liveness over media
fidelity**: drop the image, tell the model it was dropped, keep going.

## 3. Design

On the keeper dispatch seam (`keeper_turn_driver.run_named`), the RFC-0265 reroute
decision is computed once. When it is `No_capable_runtime`:

1. Resolve the assigned runtime's effective input caps via the existing
   `Runtime_agent.input_capabilities_of_runtime` (the resolved `Runtime.t`, not a
   re-derivation from `config` — reliable).
2. `strip_unsupported_modality_blocks` / `strip_unsupported_modality_messages`
   drop the top-level `Image`/`Document`/`Audio` blocks the caps do not admit from
   the current goal, `initial_messages`, and the resumed `oas_checkpoint.messages`,
   keeping text/thinking/tool blocks and reporting a per-modality drop count.
3. If anything was dropped, append a `Runtime_routed` manifest row with
   `status="degraded"` and redacted drop counts, inject one `Text` note
   (`media_degrade_note`) into the goal, and emit a `WARN` log. The turn then
   dispatches on text and the capability gate admits it (no media remains).

The strip and note builders are pure functions in `runtime_agent` (unit-tested).
The drop is **non-silent** (RFC-0126/0145): a degraded runtime-manifest row for
the dashboard trace, a structured WARN at the dispatch site, and the injected
note in the model input.

The stripped checkpoint is the **dispatch view only** — the persisted checkpoint is
not rewritten, so if the keeper is later routed to a vision-capable runtime the
original media is still in history.

## 4. Trade-off (vs the RFC-0265 fail-closed floor)

| | RFC-0265 floor | This RFC |
|--|----------------|----------|
| No capable runtime | terminal reject (turn dies) | drop media + note, proceed on text |
| Operator visibility | error surfaced to operator | degraded runtime manifest + WARN log + in-context note |
| Media fidelity | preserved (nothing dispatched) | image omitted this turn (recoverable from history) |
| Keeper liveness | can park in `pause_human` | continues |

Reroute still takes precedence: when a vision-capable runtime is configured (and
its resolved OAS model catalog row declares image input, RFC-0265 §4.1), the turn
reroutes there and is **not** degraded. Degrade fires only at the floor where
RFC-0265 would otherwise hard-reject.

## 5. Non-goals / deferred

- **ToolResult-nested media** is not stripped (rare; a tool returning an image).
  The strip is a total function over the leaf media blocks an operator attaches;
  nested media still meets the existing capability-gate floor.
- **Gate config-resolution fail-open.** `Runtime_agent.input_capabilities_for_config`
  returns raw provider caps when `runtime_id_of_config config` does not resolve
  (`None -> caps`). For keeper turns this is harmless — `config.description` carries
  the `runtime:<id>/runtime` marker (`keeper_turn_driver_try_provider.ml`) so the
  gate resolves the model caps — and this RFC's degrade strips media before
  dispatch via the **reroute** path (which resolves the runtime directly), so it
  does not depend on the gate. Making the gate use the resolved caps for every
  caller (so an unregistered-runtime config cannot fail-open) is a separate change
  and is intentionally out of scope here (a naive fail-closed default over-blocks
  non-keeper `run_blocks` callers that legitimately support media via provider
  caps — verified against `test_gate_keeper_backend`).
- **Output-modality** (image generation) — out of scope, as in RFC-0265.

## 6. Tests

`test/test_runtime_modality_reroute.ml` adds a `media_degrade` group:
strip drops an unsupported image, strip keeps a supported image on a vision
runtime, message-level strip removes history media while retaining the message,
and `media_degrade_note` returns `Some` with the count when media dropped and
`None` when nothing dropped (including all-zero counts). It also pins the public
runtime-manifest projection for the degraded row and a source-level wiring guard
that the dispatch branch emits `Runtime_routed status=degraded`. The existing
RFC-0265 reroute suite and the `test_gate_keeper_backend` gate suite are
unchanged.

## 7. Migration

Zero. With no capable runtime configured the previous behavior was a terminal
reject; this replaces only that terminal path with a degraded text turn. Reroute,
modality-satisfied turns, and text-only turns are byte-for-byte unchanged.
