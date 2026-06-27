(** Generic 5-kind FD accountant (RFC-0101 + provider CLI extension).

    Extends {!Docker_spawn_throttle}'s 2-layer cap (semaphore + FD-pressure
    serialization) into a multi-class pool covering every spawn class
    that shares the host [kern.maxfiles] ceiling.

    Reference incident: 2026-05-16 18:08-18:15 ENFILE storm — 12+
    keepers concurrently retried runtime tiers, each retry spawned a
    fresh [docker run --rm], no backpressure existed at the host
    layer. PR #15727 closed docker; this module closes the other
    classes against the same ceiling.

    Layer A (per-kind): bounded concurrency via [Eio.Semaphore]. Each
    [kind] has its own slot count, env-overridable.

    Layer B (shared): when [Keeper_fd_pressure.active ()] is true, ALL
    kinds serialize against a shared global mutex. Engaged
    automatically; gives the cooldown workspace to drain.

    Callers wrap with [with_slot ~kind f]; [f] is invoked after a slot
    is acquired and FD-pressure (if active) is taken. *)

type kind =
  | Docker_spawn
      (** [docker run / exec / ...] subprocess. Migrates from
          {!Docker_spawn_throttle.with_slot} which now delegates here. *)
  | Provider_http
      (** Outbound LLM/tool HTTP connection
          ([Eio.Net.with_tcp_connect] + TLS state). One slot per
          in-flight call. *)
  | Provider_cli
      (** Outbound LLM provider subprocess attempt (Anthropic CLI). OAS
          owns the subprocess implementation; MASC accounts the call at
          the transport boundary so CLI fan-out shares FD-pressure
          backpressure. *)
  | Sandbox_exec
      (** Inner shell exec inside a sandbox container (popen pipes
          stdin/out/err + cgroup FD). Distinct from [Docker_spawn]
          which is the *container* spawn. *)
  | Log_writer

val set_pressure_hooks : active:(unit -> bool) -> nofile_soft_limit:(unit -> int option) -> unit
      (** High-throughput log writer (dashboard SSE log stream,
          telemetry JSONL append). Low-throughput [Log.warn] /
          [Log.error] paths are NOT slotted — they're FD-cost
          negligible. *)

val with_slot : kind:kind -> (unit -> 'a) -> 'a
(** [with_slot ~kind f] acquires a [kind]-typed slot, runs [f ()],
    releases the slot, returns [f]'s result. When
    [Keeper_fd_pressure.active ()] is true at acquire time, [f] is
    additionally serialized against all in-flight callers across all
    kinds.

    Nested calls for the same [kind] on the same Eio fiber are reentrant:
    the inner call runs under the outer slot instead of consuming a second
    semaphore credit. This lets low-level process guards and explicit
    high-level wrappers coexist during migration.

    Exceptions from [f] propagate; the slot is always released
    (via [Eio.Semaphore.release] under [Fun.protect ~finally],
    after a [mark_release] state-machine transition).  PR-C1
    (follow-up to PR-B / PR #20583) removed the
    [Eio.Switch.on_release] counter-style callback: a parent-fibre
    cancellation can no longer leave the holding state stuck
    because [holding_state] is a typed variant with only two
    valid transitions, performed under
    [Eio.Mutex.use_rw ~protect:true]. *)

val acquire_lifetime_slot : kind:kind -> unit -> (unit -> unit)
(** [acquire_lifetime_slot ~kind ()] acquires a [kind]-typed slot and
    returns an idempotent release callback. This is for resources whose FD
    lifetime intentionally outlives the spawning call, such as background
    shell tasks. The release callback must be invoked exactly when the
    underlying FDs are closed; double invocation is ignored.  PR-C1
    removed the [Eio.Switch.on_release] counter-style callback; the
    holding state is a typed variant transitioned by
    {!mark_acquire} / {!mark_release} under the per-slot mutex.  The
    callback's [released] atomic is a separate idempotency guard for
    *release invocation*, not for the holding state. *)

val effective_concurrency : kind:kind -> int
(** [effective_concurrency ~kind] returns the current cap.
    Returns [1] while [Keeper_fd_pressure.active ()] is true
    (degraded serialization), the kind's configured maximum
    otherwise. Observability only — not a synchronization primitive. *)

val configured_concurrency : kind:kind -> int
(** [configured_concurrency ~kind] returns the env-configured cap
    irrespective of current pressure state. *)

val install_dated_jsonl_log_writer_guard : unit -> unit
(** [install_dated_jsonl_log_writer_guard ()] installs the process-wide
    {!Dated_jsonl} append guard that accounts date-split JSONL writes as
    {!Log_writer} while {!Eio_guard} is ready. Before Eio startup, the guard
    runs the append directly so module-load and pure test paths stay safe. The
    module installs it at load time; the explicit function exists for tests and
    future bootstrap code that resets storage hooks. *)

val install_process_eio_sandbox_exec_guard : unit -> unit
(** [install_process_eio_sandbox_exec_guard ()] installs the process-wide
    {!Process_eio} foreground spawn guard that accounts [run_argv*] calls as
    {!Sandbox_exec} while {!Eio_guard} is ready. Before Eio startup, the guard
    runs directly so module-load and pure fallback paths stay safe. The module
    installs it at load time; the explicit function exists for tests and future
    bootstrap code that resets process hooks. *)

val install_with_process_sandbox_exec_guard : unit -> unit
(** [install_with_process_sandbox_exec_guard ()] installs the process-wide
    {!With_process} guard that accounts [Unix.open_process_*] helper calls as
    {!Sandbox_exec} while {!Eio_guard} is ready. The slot covers the whole
    subprocess lifetime: open, caller drain, and close. Before Eio startup, the
    guard runs directly so pure test/module paths stay safe. *)

val install_autonomy_exec_sandbox_exec_guard : unit -> unit
(** [install_autonomy_exec_sandbox_exec_guard ()] installs the process-wide
    {!Masc_cdal_runtime.Autonomy_exec} guard that accounts autonomy-loop
    child execution as {!Sandbox_exec} while {!Eio_guard} is ready. The slot
    covers the whole child lifetime, including waitpid, timeout handling, and
    stdout/stderr drain. *)

val install_bg_sandbox_exec_guard : unit -> unit
(** [install_bg_sandbox_exec_guard ()] installs the process-wide
    {!Bg_task} lifetime guard that accounts detached background shell tasks as
    {!Sandbox_exec} while {!Eio_guard} is ready. The slot is held until
    [Bg_task] observes task closure and closes stdout/stderr FDs. *)

type snapshot = {
  per_kind : (kind * int) list ;
      (** in-flight count per class. Maintained separately from Eio semaphore
          credits so snapshots remain safe from dashboard worker domains. *)
  fd_open : int ;
      (** Best-effort observation of process-wide open FDs.
          On macOS / Linux uses [/dev/fd] / [/proc/self/fd] counting;
          on platforms where neither is available, returns [-1]. *)
  fd_limit : int ;
      (** [RLIMIT_NOFILE] soft cap. [-1] when not available. *)
  pressure_active : bool ;
}

val fd_snapshot : unit -> snapshot
(** [fd_snapshot ()] returns a point-in-time observability snapshot
    suitable for OTel export and the
    dashboard System Health panel. Best-effort: missing platform data
    is reported as [-1] rather than raising. *)

val kind_to_string : kind -> string
val kind_of_string : string -> kind option

val all_kinds : kind list
(** Enumerable list, used by snapshot iteration and tests. *)

(** {1 Holding state machine}

    PR-C1 (follow-up to PR-B / PR #20583) replaced the
    per-kind [int Atomic.t] counter with a typed variant.  The
    counter used to live next to the [Eio.Semaphore] and was
    decremented by an [Eio.Switch.on_release] callback; under
    parent-fibre cancellation the callback could fire too late
    (over-decrement, hidden by a [max 0 (... - 1)] clamp) or
    never fire (stuck positive).  The typed state machine is
    the only writer of [holding_state] and admits exactly two
    transitions, both performed under the per-slot mutex:

    - [Idle] -> [In_flight { acquired_at ; hold_id }] by
      {!mark_acquire}  (allocates the next [hold_id])
    - [In_flight _] -> [Idle] by {!mark_release}

    The semaphore and the holding state are *separate* concerns:
    the semaphore is the back-pressure primitive, the holding
    state is the counter-style invariant.  PR-C1 does not touch
    the semaphore. *)

type fd_holding_state =
  | Idle
  | In_flight of {
      acquired_at : float;
        (** Wall-clock at the matching {!mark_acquire} call,
            stamped via [Unix.gettimeofday ()].  Useful for
            observability — the per-cycle in-flight duration
            can be derived on the next {!mark_release}. *)
      hold_id : int;
        (** Strictly monotonic identifier for the
            [In_flight] branch.  Allocated from the
            per-slot [next_hold_id] counter inside
            {!mark_acquire}; never reused. *)
    }
(** Typed state of a single per-kind slot.  PR-C1
    replacement for the legacy [int] counter. *)

val read_holding : kind:kind -> int
(** [read_holding ~kind] returns the current holding count
    as a pure projection of [kind]'s [holding_state]:
    [Idle] -> [0], [In_flight _] -> [1].  Does not mutate
    state.  Thread-safe under the per-slot mutex. *)

val mark_acquire : kind:kind -> int
(** Transitions [kind]'s [holding_state] from [Idle] to
    [In_flight { ... }], allocates the next [hold_id], and
    returns it.  The caller is expected to pair this with a
    matching {!mark_release} when the slot is released.
    PR-C1 implementation: the [holding_state] field is the
    only writer, so the typed invariant holds regardless of
    caller-site exceptions. *)

val mark_release : kind:kind -> hold_id:int -> unit
(** Transitions [kind]'s [holding_state] back to [Idle].  The
    [hold_id] is the value returned by the matching
    {!mark_acquire}; it is currently accepted for API
    symmetry / future cycle-tag tracking but does not gate
    the transition (the [holding_state] is the only source
    of truth).  Idempotent on [Idle]: a stray release is a
    no-op rather than an error, so user-site exception paths
    that re-raise after partial teardown cannot desync the
    state machine. *)
