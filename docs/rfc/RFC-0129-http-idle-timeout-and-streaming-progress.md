---
rfc: "0129"
title: "HTTP idle-timeout & streaming progress for OAS cascade attempts"
status: Draft
created: 2026-05-18
updated: 2026-05-18
author: vincent
supersedes: []
superseded_by: null
related: ["0107"]
implementation_prs: []
---

# RFC-0129: HTTP idle-timeout & streaming progress for OAS cascade attempts

## §1 Problem

Fleet-wide measurement on 2026-05-18 (this session): **9 keepers × 14
`oas_timeout_budget` events in 24h**, with `productive_phase_elapsed_ms`
clustered at **307,500 ± 200ms across every event**. The variance is
deterministic — it is not provider latency jitter, it is a code cap.

Decomposition matches the live constants in
`lib/keeper/keeper_turn_cascade_budget.ml`:

```
remaining_turn_budget        = 600s
oas_timeout_guard_sec        = 15s
degraded_retry_reserve_frac  = 0.5
effective_timeout_sec        = (600 - 15) × 0.5         = 292.5s
+ oas_timeout_guard_sec                                 + 15.0s
≈ cascade_attempt_watchdog hard wall                    ≈ 307.5s
```

Every event's first attempt is killed by `cascade_attempt_watchdog` at
the same wall-clock value. The receipt rotation distribution today is
**strict_tool_candidates → glm-spark : 9** versus
**glm-spark → strict_tool_candidates : 5** — both tier-groups hit the
same cap because they share members (GLM-5-1, codex-spark, ollama)
and route through the same HTTP path.

## §2 Why the current cap is a band-aid

`pool.ml:286-345`:

```ocaml
let do_request t ?headers ?body ~method_ uri : (response, string) result =
  ...
  let body_result = Piaf.Body.to_string (Piaf.Response.body resp) in
  ...

let with_optional_timeout (type a) ?clock ?timeout_seconds (f : unit -> ...) =
  match clock, timeout_seconds with
  | Some clock, Some t when t > 0.0 ->
    Eio.Fiber.first
      (fun () -> f ())
      (fun () -> Eio.Time.sleep clock t;
                 Error (Printf.sprintf "Pool.request: timeout after %.1fs" t))
```

The wall-clock race is taken around the **whole** request — connection
acquire, send, *and* `Piaf.Body.to_string`. The body read offers zero
chunk-level visibility. The fiber is cancelled at exactly
`timeout_seconds` whether:

| scenario | what the system sees | what is true |
|---|---|---|
| **A.** provider streaming for 280s, would have finished at 310s | timeout | output exists, gets discarded, cascade rotates and pays the cost twice |
| **B.** provider has produced zero bytes after 280s (hang) | timeout | fair fail-over, but we cannot tell it apart from A |
| **C.** provider finishes at 292.3s, race wins | success or timeout, jitter-decided | non-deterministic outcome |

The code's own comment self-admits this (line 173-174 of
`keeper_turn_cascade_budget.ml`):

```
Root cause is OAS HTTP body lacking timeout (`http_client.ml take_all`);
this is a band-aid until that lands.
```

`degraded_retry_budget_reserve_fraction = 0.5` was added so a profile
with a declared fallback "must not spend the whole turn on the first
provider". That decision is rational *only because we cannot tell A
from B*. If we can, the reserve is unnecessary.

## §3 Goal

Replace total-wall-clock timeout with **idle timeout + observability**:

1. Distinguish "stream is silent for N seconds" (real hang) from
   "stream is delivering bytes, just slowly" (in-progress work).
2. Cancel only the former. Let the latter finish.
3. Emit `bytes_received` / `last_chunk_at` / `first_byte_at` into
   `cascade.rotation_attempts` so future audits stop guessing.
4. Once (1)-(3) ship, `degraded_retry_budget_reserve_fraction` and the
   307.5s cap become dead code and are removed in the same PR (no
   transitional baseline, per the workaround rejection bar in
   `CLAUDE.md`).

## §4 Design

### §4.1 New API on `masc_http_client.Pool`

```ocaml
type body_progress = {
  first_byte_at : float option;   (* monotonic, seconds since request start *)
  last_chunk_at : float option;
  bytes_received : int;
  total_bytes : int option;        (* from Content-Length if present *)
}

val request_with_idle_timeout :
  t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  idle_timeout_sec:float ->
  ?total_timeout_sec:float ->        (* hard cap fallback, optional *)
  method_:http_method ->
  url:string ->
  ?headers:Cohttp.Header.t ->
  ?body:string ->
  unit ->
  (response * body_progress, string * body_progress) result
```

- `idle_timeout_sec` is the **gap between consecutive chunks**, not the
  total. Chunk arrival resets the timer.
- `total_timeout_sec` remains available as a hard cap when callers
  explicitly want one. Default off — caller opts in.
- Progress is returned on both success **and** failure (the `Error`
  branch is `string * body_progress`), so cascade rotation receipts can
  attach progress without an extra side-channel.

### §4.2 Implementation sketch

```ocaml
let read_body_with_idle_timeout ~clock ~idle_timeout_sec body =
  let buf = Buffer.create 16384 in
  let progress = ref { first_byte_at = None; last_chunk_at = None;
                       bytes_received = 0; total_bytes = None } in
  let start = Eio.Time.now clock in
  let touched = Eio.Condition.create () in
  let cancelled = ref false in
  Eio.Fiber.both
    (fun () ->
       Piaf.Body.iter_string (fun chunk ->
         if !cancelled then raise Exit;
         Buffer.add_string buf chunk;
         let now = Eio.Time.now clock in
         progress := {
           !progress with
           first_byte_at =
             (match !progress.first_byte_at with
              | None -> Some (now -. start) | s -> s);
           last_chunk_at = Some (now -. start);
           bytes_received = !progress.bytes_received + String.length chunk;
         };
         Eio.Condition.broadcast touched
       ) body)
    (fun () ->
       let rec watch () =
         Eio.Condition.await_no_mutex touched
           ~timeout:(Eio.Time.Timeout.seconds clock idle_timeout_sec);
         let last = match !progress.last_chunk_at with
           | Some t -> start +. t | None -> start in
         let idle = Eio.Time.now clock -. last in
         if idle >= idle_timeout_sec then cancelled := true
         else watch ()
       in
       watch ());
  if !cancelled then Error ("idle timeout", !progress)
  else Ok (Buffer.contents buf, !progress)
```

(Exact API match against `Piaf.Body.iter_string` / `Piaf.Body.fold`
verified in PR-1 of the implementation. Pseudocode here.)

### §4.3 Callers

Single migration site that matters in practice:

```
lib/cascade/cascade_runner.ml — wraps OAS provider calls
lib/keeper/keeper_turn_cascade_budget.ml — computes the budget today
```

After migration:

- `keeper_turn_cascade_budget` stops computing `effective_timeout_sec`
  via the 0.5-reserve formula. The "watchdog phase" wraps the
  per-attempt idle timeout instead. Remove
  `degraded_retry_budget_reserve_fraction` and
  `oas_timeout_guard_sec`-padding logic in the same diff.
- `cascade.rotation_attempts[i]` gains
  `{ first_byte_at, last_chunk_at, bytes_received }`.
  Receipts written by `keeper_turn_*` carry these fields under
  `cascade.rotation_attempts[i].body_progress`.

### §4.4 Default tuning

| field | default | rationale |
|---|---|---|
| `idle_timeout_sec` | 30s | first-token + chunk gap p99 for GLM/RunPod observed today is well under 30s. 30s gives the provider a real chance to be slow without being hung. |
| `total_timeout_sec` | None | total cap is an explicit opt-in. Keeper turn 600s already bounds the outer loop; we trust it. |

Defaults are env-tunable (`MASC_HTTP_IDLE_TIMEOUT_SEC`,
`MASC_HTTP_TOTAL_TIMEOUT_SEC`).

## §5 Migration & rollout

Three PRs, stacked:

- **PR-1** Add `request_with_idle_timeout` + `body_progress` type;
  add unit tests with mock chunk streams (steady stream not cancelled,
  silent-from-start cancelled, mid-stream silence cancelled). Old
  `request` kept (caller-by-caller migration).
- **PR-2** Migrate `cascade_runner` + `keeper_turn_cascade_budget`. Add
  `body_progress` to `cascade.rotation_attempts`. Delete
  `degraded_retry_budget_reserve_fraction` and the
  307.5s-shaped formula in the same diff (no transitional flag, per
  workaround-rejection bar).
- **PR-3** Remove the legacy `request` from `Pool` once the migration
  is done. (Mechanical; depends on call-site audit.)

No backwards-compatibility shims. The replacement is a strict
generalisation (old behaviour = `total_timeout_sec` set, idle disabled
via a sentinel) so the migration is one straight transformation, not a
flag-gated coexistence.

## §6 Validation

The same diagnostic that uncovered this RFC becomes the success
metric. After PR-2 merges, run on a 24h window:

```
rg 'oas_timeout_budget' "$MASC_BASE_PATH"/.masc/keepers/*/execution-receipts/2026-05/*.jsonl \
  | python3 .tmp/from_cascade.py
```

Expected:

1. `productive_phase_elapsed_ms` distribution **stops clustering at
   307,500 ± 200ms**. Real provider latency has visible spread (seconds
   of jitter at minimum).
2. New `body_progress.bytes_received > 0` is observed for the majority
   of timeout-cancelled attempts → confirms scenario A (we were killing
   work-in-progress). Or near-zero → confirms scenario B (real hangs),
   in which case provider-side investigation is the next step.
3. `degraded_retry_budget_reserve_fraction`-related rotations disappear
   from the audit grep (`adaptive_estimated_input_tokens_capped_by_*`).

## §7 Non-goals

- Provider-side latency investigation. RFC-0129 is purely about
  distinguishing in-progress from hung, not making providers faster.
- Streaming UI / token-by-token rendering. The `body_progress` record
  is for observability and cancellation logic, not user surfaces.
- Replacing `Piaf`. Idle timeout fits inside Piaf's chunk-iteration
  API; no library swap.

## §8 Evidence

- Fleet measurement, 2026-05-18, this session:
  `~/me/me/workspace/yousleepwhen/masc-mcp/.tmp/from_cascade.py` output
  reproduced in the issue thread that spawned this RFC.
- Self-admitting comment in `keeper_turn_cascade_budget.ml:173-174`.
- 9 keeper × 14 hit distribution + 307,500ms deterministic clustering.

## §9 Open questions

1. Should `idle_timeout_sec` be per-route or global? Current proposal:
   global default + per-cascade override on the cascade.toml side.
2. Does `Piaf.Body.iter_string` lose tail bytes if we cancel the fiber
   mid-iteration? Needs a unit test that asserts buffer contents on
   forced cancel.
3. SSE / true-streaming endpoints (voice_bridge in
   `Pool.with_connection`) are out of scope for now but should
   eventually share the same idle-timeout primitive.
