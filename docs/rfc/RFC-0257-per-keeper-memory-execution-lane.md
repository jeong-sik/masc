# RFC-0257 — Per-keeper memory execution lane

- Status: Draft
- Date: 2026-06-17
- Related: RFC-0225 (per-keeper turn single-flight), RFC-0153 (runtime backpressure and admission), RFC-0147 (keeper-agent-run decomposition)

## Problem

Before this RFC, post-turn memory work (librarian extraction + memory-bank compaction) ran through
a process-global single slot in `keeper_librarian_runtime.ml`.

`with_provider_slot` acquired that one module-level semaphore on every librarian invocation, with a
short wait; on timeout the extraction was dropped (`provider_slot_busy`).

With ~13 keepers, every keeper's librarian work funnels through one slot. One keeper holding
the slot forces the others to wait 0.25s and then discard the extraction. This contradicts the
baseline concurrency model: keeper turns are lane-per-keeper (RFC-0225 `keeper_turn_admission.ml`
`turn_mu : Eio.Mutex.t`, one slot per keeper). A shared cross-keeper slot serializes independent
lanes — the same anti-pattern rejected in PR #21344.

The librarian today also runs *inline* inside the turn lane: `run_turn` finalize
(`keeper_agent_run_finalize_response.ml:192`) calls `Keeper_agent_run_post_turn_memory.run`
synchronously, which executes under the keeper's `turn_mu`. So memory extraction (a provider
round-trip) blocks that keeper's next chat turn.

## Design

Give each keeper its own memory execution lane, detached from the turn lane.

### Lane registry

`Keeper_memory_lane` owns execution; `Keeper_memory_job_store` owns durable
state:

- Per-keeper in-process entries contain only worker/wake ownership. They never
  retain a closure or payload backlog on the OCaml heap.
- One domain-safe `Eio.Mutex` per keeper serializes filesystem state
  transitions and yields while contended; short worker-token and registry
  critical sections use `Stdlib.Mutex` and never perform I/O or switch fibers.
- A typed job is atomically staged below
  `<BasePath>/.masc/keepers/<keeper>/memory-jobs/awaiting-turn-commit/` before
  turn finalization returns. This outbox state is not runnable.
- The owning execution receipt includes the job id and is appended with file
  and directory fsync. Only after that commit does the job move
  `awaiting-turn-commit -> pending -> inflight -> terminal receipt`. Receipt
  failure aborts the awaiting row. A crash between receipt append and activation
  is recovered by a strict receipt scan; malformed receipt rows fail explicitly
  with path and line evidence rather than authorizing work.
- If receipt append reports an error after an uncertain filesystem boundary,
  the same strict scan classifies the exact job id before abort or activation.
  A proof-read failure preserves the awaiting payload and starts reconciliation;
  it never guesses that the receipt committed or silently drops the outbox.
- The full
  SHA-256 job id is derived from the typed Keeper/trace/generation/turn/OAS-turn
  identity; a conflicting payload for the same identity is rejected.
- One drain daemon validates and sorts the current pending batch once, leases
  it in Keeper turn order, and executes it serially. This preserves turn N
  before turn N+1 without re-reading and re-sorting the full directory for
  every job.
- Different keepers run concurrently (independent lanes).
- Executor shutdown or worker-spawn failure leaves committed work durable.
  Startup discovery or activation wakes it; retryable execution/store failures
  self-schedule from the shared typed Keeper backoff policy without requiring a
  later submission. A post-receipt activation failure starts the same strict
  receipt reconciliation loop immediately rather than waiting for restart.

### Executor switch

The detached fibers are owned by the server root switch, established at startup:

The server composition root installs `sw` in `Eio_context` before runtime
restoration and memory-lane initialization.

`Keeper_memory_lane.init ~sw ~clock ~base_path ~execute` records this switch only
after Runtime/config restoration. It discovers pending/inflight jobs and starts
one drain daemon
with `Eio.Fiber.fork_daemon ~sw`; that daemon re-binds the switch via
`Eio_context.with_turn_switch sw` for every unit so that
`run_best_effort` (which reads `sw`/`net`/`clock` from `Eio_context`, `keeper_librarian_runtime.ml:331,347`)
issues its provider call under the executor switch. `net`/`clock` are global atomics set at the
same startup point, available everywhere.

The daemon does not keep normal server shutdown alive. Cancellation releases
only process-local worker ownership; the inflight file deliberately remains.
On restart, receipt-less inflight jobs return to pending, while an inflight job
whose terminal receipt already committed is acknowledged without re-execution.

### What moves to the lane vs stays inline

`Keeper_agent_run_post_turn_memory.run` does five things:

1. typed tool-result memory promotion (`Memory.append_from_tool_results`)
2. librarian extraction (`Keeper_librarian_runtime.run_best_effort`)
3. advisory draft-skill projection (`Skill_candidate_store.write_all_post_turn_candidates`)
4. memory-bank compaction (`Memory.compact_if_needed`)
5. post-turn quality metrics → decision log (`append_jsonl_line` to `keeper_decision_log_path`)

`Memory.append_from_tool_results` / `compact_if_needed` carry no internal lock; they are safe today only
because the turn lane calls them single-fiber-per-keeper. Detaching (4) while (1) still ran inline
would let two fibers touch the same keeper's memory bank concurrently. Therefore **(1)–(4) — all
memory-system work — move onto the lane** (serialized by the keeper's FIFO worker). **(5) stays
inline**: it only reads the typed turn history and writes the *decision* log, a separate
file independent of (1)–(4).

### Separate keeper ordering from provider-call protection

The old global slot mixed two concerns: per-keeper memory ordering and provider-pool
protection. Per-keeper ordering now comes from `Keeper_memory_lane`'s FIFO worker. A later
per-keeper provider semaphore duplicated that same ordering because the only production
`run_best_effort` caller is already inside the Keeper's memory lane. Its fixed acquisition window
could only discard work; it could not protect fleet-wide capacity.

The duplicate semaphore and `MASC_KEEPER_MEMORY_OS_LIBRARIAN_GLOBAL_SLOT` knob are retired.
Provider/model capacity, health, and fallback belong to the OAS provider/runtime boundary. MASC
keeps independent Keeper lanes and does not recreate a cross-Keeper provider scheduler.

### Correctness under detachment

Detaching means a keeper's turn N+1 can run while turn N's memory unit is still
on the lane. The data the unit reads must not race that later turn:

- `Keeper_meta_contract.keeper_meta` is serialized through its canonical JSON
  codec. Replay reconstructs the exact immutable turn snapshot and validates
  Keeper/trace identity against the durable envelope.
- The one mutable per-keeper read in the deterministic write is the
  tool-emission accumulator. Finalization consumes it exactly once with
  `take_all`; the immutable value fans out to the durable memory job and, after
  successful admission, the post-turn multimodal working context. On admission
  failure, or when the owning execution receipt fails and aborts the staged
  outbox, it is restored behind any concurrently captured items. This prevents
  later-turn bleed, receipt-failure loss, and stale-checkpoint re-snapshot
  duplication.
- The librarian checkpoint is an OAS checkpoint value reduced to the same
  bounded raw-message window the librarian consumes. Tool schemas, MCP
  sessions, working context, and unbounded history are not copied into each
  job.
- Tool-result promotion de-duplicates persisted `artifact_id` values under the
  memory-bank lock. Librarian extraction stages the provider episode under
  `memory-jobs/operations/<job-id>.json` before publishing facts/events; the
  event carries that operation id as its commit marker. Inspection has three
  typed states (`absent`, `staged`, `committed`). A staged result bypasses all
  enablement/cadence/runtime/provider gates and enters publication directly.
  The terminal job receipt commits before operation/pending/inflight cleanup.
  Cleanup errors are reported as debt but cannot roll back the receipt or block
  later jobs. It therefore does not duplicate a provider call or expose an
  uncommitted stage through episode recall.
- The librarian enablement/cadence decision is encoded in the immutable job
  payload at admission. Cadence is a pure function of the Keeper's durable
  timeline turn id; there is no process-local cadence table for restart, detached
  execution, or admission failure to corrupt. Replay consumes the typed
  decision verbatim.
- Every Memory OS path used by the detached executor receives the worker's
  explicit BasePath-derived `keepers_dir`; no librarian write consults ambient
  config-dir state. Startup performs an explicit byte-preserving migration from
  the historical canonical `<BasePath>/.masc/config/keepers` runtime artifacts;
  divergent destinations remain untouched and are reported individually
  without stopping unrelated Keeper/artifact migrations or healthy lane
  startup. Keeper TOML remains in the config root.
- Facts publish atomically and event rows use a durable append as the episode
  commit marker. A retryable persistence failure keeps the job inflight. A
  malformed historical event row is first durably quarantined, then the valid
  rows are atomically rewritten under the episode-bundle lock.
- Queue envelopes are accepted only when their typed keeper, job id filename,
  and state directory agree. Atomic-write temp orphans use the filesystem SSOT:
  zero-length files are removed and non-empty files are moved to a private
  forensic directory with an explicit error log.
- Startup discovery isolates malformed Keeper-local backlogs and starts every
  healthy Keeper lane. Only failure to inspect the Keeper root itself prevents
  fleet discovery.

## Accepted consequence

Detaching memory work means a keeper can have a chat turn and a memory unit queued or in flight at
the same time. Without a MASC-wide gate, N keepers may issue N concurrent provider calls. That is
the intended lane-independence boundary. Measured provider saturation remains observable, but
provider capacity and fallback must be enforced by the selected runtime/provider implementation
rather than by discarding Keeper memory after a hardcoded wait.

Memory writes become eventually consistent: a keeper's turn N+1 can begin before turn N's
deterministic note lands, so recall on turn N+1 may miss turn N's note. Ordering within a keeper is
preserved by the FIFO (turn N completes before turn N+1 on the lane).

## Relationship to #21408

PR #21376 merged the per-Keeper memory lane and closed competing PR #21408. Later source drift
reintroduced #21408's per-Keeper semaphore shape even though the lane already serialized its only
production caller. This revision restores one ownership primitive: the memory lane owns Keeper
ordering; the OAS provider runtime owns provider capacity.

## Failure and replay semantics

- A terminal-only stage failure produces a failed terminal job receipt; it does
  not block the Keeper turn lane or the next memory job. If weakly-coupled
  stages contain both terminal and retryable failures, retryable persistence
  wins at the job boundary so the terminal stage cannot acknowledge and discard
  the other stage's work. Typed retryable failures keep the inflight job and
  self-schedule. Disabled/not-due librarian work is a typed skip, not a failure.
  Tool-result promotion and librarian publication carry unique turn input and
  therefore retry persistence failures. Draft-skill projection and compaction
  are derivable hygiene; their failure is recorded for this job and a later job
  recomputes them without holding the Keeper lane indefinitely.
- The retained terminal receipt carries typed turn identity, the original
  enqueue timestamp, a canonical payload SHA-256 (never the checkpoint/tool
  payload itself), worker start/end timestamps, and per-stage outcomes.
  Queue directories are mode `0700` and atomic files finish at mode `0600`.
  Librarian detail includes the
  resolved runtime/model, measured latency, typed error or skip reason, and the
  exact turn-count distance to the next cadence decision (`null` while
  disabled). Accepted jobs have no drop transition; admission rejection is a
  separate typed result and metric.
- If terminal receipt persistence itself fails, the worker leaves the inflight
  job intact and retries with the typed Keeper backoff even when no new wake
  arrives. All lane store transitions share one domain-safe, fiber-yielding
  mutex per Keeper. Other Keepers continue independently.
- A crash after a provider response but before its atomic staged-episode write
  may repeat the external provider call. No local side effect has committed at
  that point. Once staging succeeds, replay is idempotent through the operation
  event marker.
- Terminal receipt files are retained as audit evidence. Retention must be an
  explicit operator/storage policy; the execution path does not invent a
  heuristic count cap or silently delete receipts.

## Runtime tunables and metrics

Per-keeper lane:

- `masc_keeper_memory_lane_submitted_total`
- `masc_keeper_memory_lane_admission_rejected_total`
- `masc_keeper_memory_lane_replayed_total`
- `masc_keeper_memory_lane_completed_total`
- `masc_keeper_memory_lane_failed_total`
- `masc_keeper_memory_lane_pending` (gauge, per-keeper)
- `masc_keeper_memory_lane_in_flight` (gauge, per-keeper)

Admission, claim, replay, and terminal-receipt failures are logged with the
Keeper/job identity; no accepted job has an abandonment path. If the retired
`MASC_KEEPER_MEMORY_OS_LIBRARIAN_GLOBAL_SLOT` variable is still configured, startup logs and
counts the ignored setting explicitly.

## Tests

`test/test_keeper_memory_lane.ml`:

- an awaiting outbox row is runnable after restart only when its strict
  execution-receipt proof exists; an uncommitted row is explicitly aborted.
- duplicate staging is idempotent; conflicting payloads are rejected.
- queue files whose typed state disagrees with their directory are rejected.
- queue files whose Keeper or filename coordinate disagrees with their envelope
  are rejected.
- zero-length atomic orphans are removed and non-empty ones are preserved
  outside the queue.
- terminal receipts omit the full job payload and receipt acknowledgement
  removes the staged provider journal only after the receipt is durable.
- one FIFO daemon serializes submissions for the same keeper.
- two different keepers run concurrently (no cross-keeper blocking).
- one malformed Keeper backlog does not suppress healthy Keeper discovery.
- a failed job commits a failed receipt and the next job still runs.
- cancelling the executor with an inflight job leaves it durable; a fresh
  executor replays it and commits one success receipt.
- a receipt-backed inflight artifact is acknowledged without execution.
- cleanup failure after a terminal receipt is surfaced as debt without blocking
  the lane.
- a retryable failure self-schedules without a later submit signal.
- a post-receipt activation failure self-reconciles without a later turn or
  restart.
- legacy Memory OS runtime artifacts migrate byte-for-byte, divergent
  destinations are reported without stopping independent artifacts, and
  malformed event rows are quarantined before repair.
- a receipt-write failure racing with a second submit replays inflight work and
  continues to the second job without losing the wake.
- librarian operation replay makes one provider call and one event; a staged
  result is a distinct typed state and commits without provider replay gates.

## Rollback

Rollback must drain or explicitly migrate the on-disk memory-job schema before
removing the executor. Re-inlining while pending jobs exist would orphan
accepted work and is therefore not a valid source-only revert.
