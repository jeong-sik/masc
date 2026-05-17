(** Generic 4-kind FD accountant (RFC-0101).

    Extends {!Docker_spawn_throttle}'s 2-layer cap (semaphore + FD-pressure
    serialization) into a multi-class pool covering every spawn class
    that shares the host [kern.maxfiles] ceiling.

    Reference incident: 2026-05-16 18:08-18:15 ENFILE storm — 12+
    keepers concurrently retried cascade tiers, each retry spawned a
    fresh [docker run --rm], no backpressure existed at the host
    layer. PR #15727 closed docker; this RFC closes the other three
    classes against the same ceiling.

    Layer A (per-kind): bounded concurrency via [Eio.Semaphore]. Each
    [kind] has its own slot count, env-overridable.

    Layer B (shared): when [Keeper_fd_pressure.active ()] is true, ALL
    kinds serialize against a shared global mutex. Engaged
    automatically; gives the cooldown room to drain.

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
  | Sandbox_exec
      (** Inner shell exec inside a sandbox container (popen pipes
          stdin/out/err + cgroup FD). Distinct from [Docker_spawn]
          which is the *container* spawn. *)
  | Log_writer
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
    (via [Eio.Switch.on_release]). *)

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

type snapshot = {
  per_kind : (kind * int) list ;
      (** in-flight count per class (cap − available semaphore slots). *)
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
    suitable for the [/metrics] Prometheus endpoint (PR-5) and the
    dashboard System Health panel. Best-effort: missing platform data
    is reported as [-1] rather than raising. *)

val kind_to_string : kind -> string
val kind_of_string : string -> kind option

val all_kinds : kind list
(** Enumerable list, used by snapshot iteration and tests. *)
