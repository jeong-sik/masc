---
rfc: "async-log-sink-durable-append-offload"
title: "Offload the structured-log durable append off the emitting fiber"
status: Draft
created: 2026-07-19
updated: 2026-10-28
author: vincent
supersedes: []
superseded_by: null
related: ["0108", "0079"]
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
producer: agent_core `Llm_provider.Diag.warn/error` now route into `Log.Runtime`, so a
provider 4xx/429 storm (observed: deepseek-v4-flash ~78% 4xx) fires one
synchronous durable flush per rejected request, serializing provider fibers on
the log mutex + disk flush precisely during the storm. #25162 merged with this
P1 unresolved (the adversarial review flagged it); it is not firing today only
because the live server predates that merge — it activates on the next deploy.

Prior art confirms this is the same class of problem the codebase already
fights: `log.ml:248-260` (#25003) throttled the sink-identity `stat` pair
because per-emit syscalls were ~27% of main-thread samples. Per-record
`write()`+`flush()` is the next such emit-path syscall.

### 1.1 Measured on production (2026-10-28, #46410)

After #46467 removed the shell path checks from the main domain, the per-record
file flush became the largest blocking call left on the main thread
(`com.apple.main-thread`, the domain-0 Eio loop) in three 10-second `sample`s
of build `365dc0d3bf36`, load 11-18:

| OCaml caller | C call under it | main-thread samples |
|---|---|---|
| `Log` (`write_to_sink`) | `caml_ml_flush` → `write` | 1,095 |

Blocking calls other than Eio's own readv/writev took 1.0%, 10.8% and 12.2% of
the three samples; the `Log` flush was the largest. The console mirror is not
in this list: `Console_sink` has written from its own OS thread since #20684.

The same day's JSONL file (`system_log_2026-10-27.jsonl`, 263,532 records)
gives the load the queue must take:

| | p50 | p99 | max |
|---|---|---|---|
| records per second (seconds with any record) | 4 | 38 | 213 |
| bytes per record | 356 (mean) | 1,071 | 4,022 |

## 2. Non-goals

- Dropping or sampling log records. The point of #25162 is durable 4xx request
  shapes; dropping them during the exact storm you want to inspect defeats it,
  and drop-with-a-counter is the manifest's telemetry-as-fix signature.
- Changing what is logged, the log format, or the in-memory ring buffer
  (`buf`) that the dashboard reads. Only the file append is deferred.
- A per-producer bound at `Oas_diag_sink` (rejected: see §6).

## 3. Design: a backpressured queue drained by one OS writer thread

The 2026-07-19 draft drained the queue with an Eio fiber forked on the server
switch. That fiber runs on the main domain, so its `write()` still stops the
main domain's scheduler: batching lowers the number of stops, not their
length. `Console_sink` already answered the same question for the console
mirror (#20684) with an OS thread outside every Eio scheduler. The file sink
takes the same shape, with one difference: the file is the authoritative
record, so a full queue makes the producer wait instead of dropping the line.

State, beside the existing file-channel state in `Log.Ring`:

- a `string Queue.t` of serialized JSONL lines, bounded by `capacity`;
- one `Stdlib.Mutex` and two `Condition`s, `nonempty` and `nonfull`;
- a mode: `Synchronous` (before start, after stop) or `Queued`;
- the writer `Thread.t`.

`write_to_sink` serializes the record as today, then:

1. `Synchronous` → the current path, unchanged: rotate, take `sink_mutex`,
   `output_string`, `flush`.
2. `Queued` → take the queue mutex; while the queue holds `capacity` lines and
   the mode is still `Queued`, wait on `nonfull`; then append the line and
   signal `nonempty`. If the mode became `Synchronous` while waiting, release
   the queue mutex and take path 1.

The writer thread loops: take the queue mutex; wait on `nonempty` while the
queue is empty and the mode is `Queued`; move every queued line into a local
batch; release the mutex. It then runs `rotate_if_needed` once and, under
`sink_mutex`, writes the batch with `output_string` per line and one `flush`.
Only then does it take the queue mutex again, give the batch's room back and
broadcast `nonfull`. The lines it holds count against `capacity` until they
are written, so `capacity` bounds every buffered line: a writer that took
the whole queue just before `write()` blocked does not let the queue fill a
second time. When the queue is empty and the mode is `Synchronous`, it exits.

`start_writer ()` (idempotent) sets `Queued` and creates the thread. The server
calls it in `bin/main_eio.ml` right after `Log.Ring.init_file_sink`, before any
Keeper boots, next to `Console_sink.start`. `stop_writer ()` sets
`Synchronous`, broadcasts both conditions and joins the thread, which writes
what is left before it exits. It is registered with `at_exit` by
`start_writer`. Processes that never call `start_writer` (CLI one-shots,
tests, the TUI's own file sink) keep the synchronous path.

### 3.1 Why the synchronous path stays

A thread does not need an Eio scheduler, so the 2026-07-19 reason for the dual
mode (an `Eio.Stream` cannot exist outside `Eio_main.run`) is gone. Two others
remain: a process that never starts the writer must still write, and records
emitted after `stop_writer` (the rest of `at_exit`) must not land in a queue
nobody drains.

## 4. Decisions

- **Backpressure, not drop.** Unchanged from the draft. A full queue makes the
  producer wait on `nonfull`; it never drops. The console mirror drops because
  it is a copy; the file is the record.
- **One writer.** File order is queue order, and RFC-0108's no-interleave
  property holds because only the writer (or a synchronous producer, under
  `sink_mutex`) writes.
- **An OS thread, not a fiber.** See §3. The writer never runs on an Eio
  scheduler, so a slow `write()` stops only the writer.
- **Capacity 8,192 lines**, the console mirror's bound. At the busiest second
  measured in §1.1 (213 records/s) the writer may stall for 38 s before any
  producer waits; at p99 (38/s), 3.6 minutes. At the largest measured record
  (4,022 B) the queued and held lines take at most 33 MB. A producer that does wait blocks
  its domain's thread on `Condition.wait`, which is what every producer does
  today on every record.
- **The in-memory ring `buf` stays synchronous**, so the dashboard reader is
  unaffected.

## 5. Safety properties

1. **No loss on a normal exit.** `stop_writer` runs from `at_exit`, switches
   producers to the synchronous path and joins the writer after it empties the
   queue.
2. **Order.** File order equals queue order. Records written by different
   domains were never in `seq` order in the file; this does not change.
3. **No enqueue after stop.** A producer that finds `Synchronous`, or wakes to
   it, takes the synchronous path.
4. **No byte interleave within a record** (RFC-0108): every write is under
   `sink_mutex`.
5. **What can be lost.** A process that ends without `at_exit` (SIGKILL,
   `Unix._exit`, a crash) loses the lines still queued. Today it loses at most
   the record being written. The queue is normally empty within one write;
   its depth bounds the loss.

## 6. Alternative rejected: bound at `Oas_diag_sink`

Dedupe/sample/rate-bound the `agent_core:*` warns at `oas_diag_sink.ml:24-48`. Rejected
as a standalone fix: (a) it quiets only the one new producer while the other
644+ warn/error sites keep hitting the same synchronous flush; (b) cap / cooldown
/ dedup / sample is an explicit manifest workaround-rejection signature requiring
a `WORKAROUND:` label + replacement RFC + removal target; (c) it discards the
diagnostic data #25162 exists to capture. It does not meet the Override bar (the
P1 is latent, not production-blocking now).

## 7. Test plan

The tests drive the real sink through `init_file_sink` and the public writer
functions; they add no test-only setter.

1. **Order and no loss.** Start the writer, emit M records from several
   domains, stop the writer, and read the file: exactly M lines, each a
   complete JSON record, and each domain's records in its emit order.
2. **Backpressure.** Point the sink at a FIFO whose reader the test holds
   still. Emit more than `capacity` records plus the pipe buffer from a
   producer thread: the producer stops returning before it finishes, and no
   record is dropped. Start reading: the producer finishes and the reader gets
   every record in order.
3. **The main domain does not wait for the disk.** With the same stalled FIFO
   and a queue below capacity, an Eio fiber's emit returns while the writer is
   blocked in `write()`, and another fiber on that domain keeps running.
4. **Before start and after stop.** Without `start_writer`, a record is in the
   file when the emit returns. After `stop_writer`, the same holds.
5. **Interleave** (RFC-0108 regression): concurrent producers never write a
   `}{`-joined line.

## 8. Rollout

One implementation layer on top of this RFC: the writer in `Log.Ring`, the
`start_writer` call in `bin/main_eio.ml`, and the tests above. No setting turns
it on or off; a process either starts the writer or keeps the synchronous
path. After the deploy, the same three-`sample` measurement as §1.1 checks
that `caml_ml_flush` under `Log` is gone from the main thread (#46410).

## 9. Open questions

- None for the first layer. The capacity is the measured bound in §4; if a
  later measurement shows producers waiting on `nonfull`, that measurement,
  not a new literal, sets the next value.
