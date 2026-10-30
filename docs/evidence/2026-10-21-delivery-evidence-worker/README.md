# Delivery evidence scheduling

Observed server: `0920933e057f231f71a221e1823e266fc96eb1f4`, PID 70091,
instance `01a15a63-ef69-7000-b825-bcc9a143d9c6`.

A five-second macOS sample starting 2026-10-21T02:51:10.940+09:00 recorded
3,243 main-thread observations. Separate branches below the top Fun.protect
include Dated_jsonl open (791), path inspection (442), and directory listing
(367). Other resolved branches name read_delivery_evidence_cached,
read_delivery_evidence_file, append_delivery_evidence and Keeper_ask_answer_wake.
Parent callers are truncated in parts of this sample. Observation counts are
not individual call durations; neither all filesystem observations nor an
earlier 2.58-second simultaneous API delay can be attributed to this read.

The strict delivery reader enumerates partitions, opens and verifies files,
advances its private evidence cache and merges immutable proof sets. Its
cache mutex and native file operations previously ran on the calling fiber.
The caller can hold the queue owner's cross-context lock while checking this
evidence before a durable enqueue.

Move the complete private read into the existing CPU pool, then run its native
work in a system thread of that worker domain, following the existing tool-call
index boundary. The cache mutex is acquired inside the job; file acquisition,
read and close remain together. Queue ownership, the transaction and applying
the result stay on the caller. The shared pool's absent-pool, raw-domain and
nested-worker policies remain, and worker exceptions do not rerun the read on
the caller. This adds no pool, cache, timeout or observation-based gate.

Do not move Dated_jsonl's open operation alone: cancellation could discard an
opened channel before its caller adopts it. Adding a yield to common metadata
helpers inside an existing native mutex would also change their callers'
locking behavior. No common Dated_jsonl callback contract changes here.

Real-pool cases reuse strict corruption, appended-byte and invalidation
scenarios, plus a one-worker nested call and a raw-domain read. These verify
canonical results across the execution boundary; they do not time the UI,
measure scheduler latency or inject cancellation during a file read.

Native execution and installed-candidate performance remain unverified.
