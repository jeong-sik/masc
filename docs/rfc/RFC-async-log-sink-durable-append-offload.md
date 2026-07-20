---
rfc: "async-log-sink-durable-append-offload"
title: "Offload the structured-log durable append off the emitting fiber"
status: Draft
created: 2026-07-19
updated: 2026-07-19
author: vincent
supersedes: []
superseded_by: null
related: ["0108", "0079"]
implementation_prs: []
---

# RFC: Offload the structured-log durable append off the emitting fiber

## 1. Problem

Every structured-log call at or above the module level gate funnels through
`Ring.push` (`lib/masc_log/log.ml:633-659`). When a file sink is installed (it
is, at boot, via `init_file_sink`), `Ring.push` calls `write_to_sink`
(`lib/masc_log/log.ml:417-445`) on the **emitting fiber**. `write_to_sink`
takes a process-global `Stdlib.Mutex` and performs `output_string oc line`
followed by `flush oc` — a blocking `write()` syscall, synchronously, on the
caller's Eio domain.

On a single Eio domain a blocking `write()` stalls the whole scheduler (every
fiber), and the mutex additionally serializes concurrent producers. This is a
latent throughput bottleneck for **all 644+ `Log.{Runtime,Keeper,Mcp}.{warn,error}`
call sites**, not any one subsystem.

It became load-bearing when #25162 (`Oas_diag_sink`) added a new high-rate
producer: OAS `Llm_provider.Diag.warn/error` now route into `Log.Runtime`, so a
provider 4xx/429 storm (observed: deepseek-v4-flash ~78% 4xx) fires one
synchronous durable flush per rejected request, serializing provider fibers on
the log mutex + disk flush precisely during the storm. #25162 merged with this
P1 unresolved (the adversarial review flagged it); it is not firing today only
because the live server predates that merge — it activates on the next deploy.

Prior art confirms this is the same class of problem the codebase already
fights: `log.ml:248-260` (#25003) throttled the sink-identity `stat` pair
because per-emit syscalls were ~27% of main-thread samples. Per-record
`write()`+`flush()` is the next such emit-path syscall.

## 2. Non-goals

- Dropping or sampling log records. The point of #25162 is durable 4xx request
  shapes; dropping them during the exact storm you want to inspect defeats it,
  and drop-with-a-counter is the manifest's telemetry-as-fix signature.
- Changing what is logged, the log format, or the in-memory ring buffer
  (`buf`) that the dashboard reads. Only the file append is deferred.
- A per-producer bound at `Oas_diag_sink` (rejected: see §6).

## 3. Design: dual-mode sink with a single backpressured consumer fiber

Add async-consumer state alongside the existing file-channel state
(`log.ml:244-246`):

```
let async_queue : string Eio.Stream.t option ref = ref None
```

a bounded stream of pre-serialized JSONL lines.

`write_to_sink` (`log.ml:417-445`) branches:

1. `!async_queue = Some q` → `Eio.Stream.add q line`. The stream is bounded, so
   this blocks the **producer** only when the queue is full (backpressure) —
   never on the disk write.
2. `!async_queue = None` → the current synchronous rotate + `Stdlib.Mutex` +
   `output_string` + `flush` path, unchanged.

Add `start_async_consumer ~sw ~clock ~capacity`:
- creates the bounded `Eio.Stream.t`, stores it in `async_queue`;
- forks **one** consumer fiber (`Fiber.fork ~sw`) that loops
  `Eio.Stream.take q` and runs the existing rotate + mutexed
  `output_string`/`flush` on the drained line. It may batch-drain the items
  currently available and `flush` once per batch to amortize the syscall;
- under `Switch.on_release`, sets `async_queue := None` and synchronously
  drains any residue through the sync path.

Spawn it in `server_runtime_bootstrap.ml run` (`~960`), just before
`Oas_diag_sink.install` (`~967`), using the threaded `~sw` and `env` clock.

### 3.1 Why the dual mode is load-bearing

Log calls happen **before** the Eio scheduler (`bin/main_eio.ml:611`
`init_file_sink` runs before `Eio_main.run` at `:613`) and **after** it
(`at_exit`, shutdown residue). An `Eio.Stream` cannot exist or be pushed to
outside a running scheduler. The `async_queue = None` sync fallback is therefore
mandatory: pre-Eio boot logs and post-Eio at_exit logs keep the synchronous
path; only the steady-state window uses the async path. A single-mode async
rewrite would break boot/shutdown logging.

## 4. Decisions

- **Backpressure, not drop.** Bound the stream; block the producer when full.
  Lossless and order-preserving. Producer-block latency is bounded and only
  bites under sustained overload, where the consumer is doing fast page-cache
  `write()`s. Drop-oldest-with-counter is rejected (§2, telemetry-as-fix).
- **Single consumer.** Preserves FIFO file ordering and keeps RFC-0108's
  no-interleave guarantee trivially (one mutexed `output`).
- **In-memory ring `buf` stays synchronous** (`log.ml:657`) so the dashboard
  reader is unaffected; only the JSONL file append defers.

## 5. Safety properties (to check, TLA+-style)

1. **No loss on clean shutdown.** On switch release, all enqueued-but-unflushed
   lines are synchronously drained. `NextBuggy` = consumer drops residue on
   cancel → must violate a `NoLossOnCleanShutdown` invariant.
2. **FIFO order.** File line order equals `seq` order (single consumer).
3. **No post-close enqueue.** After `async_queue := None` on release, producers
   take the sync path; no `Stream.add` to a closed queue.
4. **No byte interleave within a record** (RFC-0108): single consumer + one
   mutexed `output` holds it.

## 6. Alternative rejected: bound at `Oas_diag_sink`

Dedupe/sample/rate-bound the `oas:*` warns at `oas_diag_sink.ml:24-48`. Rejected
as a standalone fix: (a) it quiets only the one new producer while the other
644+ warn/error sites keep hitting the same synchronous flush; (b) cap / cooldown
/ dedup / sample is an explicit manifest workaround-rejection signature requiring
a `WORKAROUND:` label + replacement RFC + removal target; (c) it discards the
diagnostic data #25162 exists to capture. It does not meet the Override bar (the
P1 is latent, not production-blocking now).

## 7. Test plan

1. Ordering/no-loss: push M records through the async path, drain, assert the
   file has exactly M lines in `seq` order.
2. Backpressure: capacity N, paused consumer + N+K producers block (not drop);
   after resume the file has N+K lines, zero missing seqs.
3. Boot-boundary (counterfactual): emit with `async_queue=None` → synchronous
   path, line lands immediately; then start consumer → subsequent lines defer.
4. Shutdown-drain: enqueue, cancel the switch, assert residue synchronously
   flushed via `on_release` (models safety invariant #1).
5. Storm/harness: simulate the deepseek 429 pattern (hundreds of `oas:*`
   `Diag.warn`/s); assert producer emit latency stays bounded (no per-record
   flush syscall on the emitting fiber).
6. Interleave (RFC-0108 regression): concurrent producers never emit `}{`-concat
   lines.

## 8. Rollout

- Phase 1: add the dual-mode branch + `start_async_consumer`, default **off**
  (`async_queue=None`) so behaviour is byte-identical to today.
- Phase 2: wire `start_async_consumer` in `server_runtime_bootstrap`; the sync
  fallback still covers boot/shutdown.
- No config knob is introduced for on/off beyond the boot wiring: a knob that
  toggles durability semantics per deployment is itself a hazard.

## 9. Open questions

- Batch-flush size: fixed small batch vs drain-all-available. Prefer
  drain-all-available with one flush; measure under the storm harness.
- Bounded capacity N: start from the storm rate × an acceptable
  producer-stall bound; derive from harness measurement, not a guessed literal.
