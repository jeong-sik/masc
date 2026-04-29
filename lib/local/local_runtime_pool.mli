(** Local_runtime_pool — local LLM runtime pool with
    health / cooldown / least-loaded selection.

    Tracks every locally-discovered LLM HTTP endpoint
    ([http://127.0.0.1:<port>] etc) as a {!runtime} entry
    with EMA-smoothed latency, an active-slot counter, a
    failure streak, and a cooldown window after repeated
    failures.  {!acquire} hands a caller an {!assignment}
    (runtime selection + lease handle); {!release} returns
    the lease and folds the success / latency / error
    outcome into the runtime's stats.

    Ref-cell architecture: {!pool} is a global [pool_state ref]
    guarded by an [Eio.Mutex].  The ref is exposed because
    [test/test_local_runtime_pool.ml] needs to install a
    custom seed state without rebuilding the discovery cache
    on every test.  Production code paths reach {!pool}
    only through the locked accessors below. *)

(** {1 Runtime + snapshot records} *)

type runtime = {
  id : string;
  base_url : string;
  model : string option;
  max_concurrency : int;
  active_slots : int;
  queue_depth : int;
  latency_ema_ms : float option;
  failure_streak : int;
  cooldown_until : float option;
  last_error : string option;
  total_started : int;
  total_success : int;
  total_failure : int;
}
(** Per-endpoint runtime entry.  [latency_ema_ms] is the
    exponential moving average of release-reported latency
    (alpha = 0.2).  [failure_streak] tracks consecutive
    failures; >= 3 triggers a [cooldown_until] window so
    the selector skips the runtime until the window
    elapses. *)

type runtime_snapshot = {
  id : string;
  base_url : string;
  model : string option;
  max_concurrency : int;
  active_slots : int;
  queue_depth : int;
  latency_ema_ms : float option;
  failure_streak : int;
  cooldown_until : float option;
  last_error : string option;
  total_started : int;
  total_success : int;
  total_failure : int;
  port : int option;
}
(** External-facing read-only view.  Mirrors {!runtime} plus
    a derived [port] field parsed from [base_url]. *)

type lease = {
  runtime_id : string;
}
(** Opaque-ish handle returned to callers via
    {!assignment.lease}.  Carries only the runtime id back
    to {!release}; mutation goes through the locked pool. *)

type assignment = {
  runtime_id : string;
  base_url : string;
  model_name : string;
  max_concurrency : int;
  lease : lease;
}
(** Result of {!acquire}.  [model_name] is the resolved
    label (caller-requested model when applicable, otherwise
    the runtime's advertised model).  [max_concurrency] is
    the runtime cap so the caller can size its own
    concurrency primitives. *)

type pool_state = {
  runtimes : runtime list;
  fingerprint : string;
  parse_errors : string list;
  measured_ceiling : int option;
}
(** Snapshot of the pool.  [fingerprint] is recomputed from
    the discovery cache on each load and used by
    {!ensure_loaded} to detect that the underlying endpoints
    have changed.  [measured_ceiling] is the operator-set
    upper bound on total concurrent acquires. *)

(** {1 Constants + global state} *)

val default_pool_label : string
(** ["local64"] — the canonical label used when the caller
    does not specify a [preferred_pool]. *)

val empty_pool : pool_state
(** Zero-valued [pool_state] used as the reset target and
    the test-seed scaffolding template. *)

val pool : pool_state ref
(** Global pool ref.  Production code reaches this only
    through the locked accessors below; the ref is exposed
    because [test/test_local_runtime_pool.ml] installs a
    fixed runtime list ([Local_runtime_pool.pool := ...])
    to drive deterministic acquire / release scenarios. *)

(** {1 Lifecycle} *)

val reset : unit -> unit
(** Reinstalls {!empty_pool} under the pool lock.  Used by
    tests to clear state between cases. *)

val current_fingerprint : unit -> string
(** Stable hash of the current discovery cache snapshot.
    Equality of two consecutive calls means no endpoints
    were added / removed / re-discovered. *)

val runtime_id_of_base_url : string -> string
(** Derives a stable runtime id from a [base_url] (e.g.
    ["http://127.0.0.1:8081"] →
    ["local-127-0-0-1-8081"]).  Identical URLs always map
    to the same id; the id is the join key between the
    discovery cache and the pool entries. *)

(** {1 Read accessors (locked)} *)

val parse_errors : unit -> string list
(** Returns the [pool_state.parse_errors] list.  Populated
    when [load_runtimes_from_env] could not interpret the
    [MASC_LOCAL_LLM_ENDPOINTS] entry; surfaced to the
    operator dashboard. *)

val snapshots : unit -> runtime_snapshot list
(** Read-only projection of every {!runtime} into a
    {!runtime_snapshot} (adds derived [port]).  Caller may
    keep the list across yields — values are immutable. *)

val configured_capacity : unit -> int
(** Sum of [max_concurrency] over every runtime in the
    pool.  Hard ceiling on simultaneous acquires across the
    pool. *)

val healthy_runtime_count : unit -> int
(** Number of runtimes whose [cooldown_until] is unset or
    in the past — the count of slots currently considered
    eligible by {!select_runtime_from}. *)

val allocated_slots : unit -> int
(** Sum of [active_slots] across the pool.  Equals the
    number of outstanding leases. *)

val measured_ceiling : unit -> int option
(** Operator-installed upper bound on
    {!allocated_slots}.  [None] when no measurement has
    been recorded yet; consumed by the rate-limiter to
    decide whether to admit additional acquires. *)

val record_measured_ceiling : int -> unit
(** Stores a new [measured_ceiling].  Replaces the previous
    value unconditionally (no monotonic guard — the
    operator endpoint validates the value before calling). *)

(** {1 Selection + acquire / release} *)

val select_runtime_from :
  runtime list ->
  ?preferred_pool:string ->
  ?model_name:string ->
  unit ->
  (runtime, string) result
(** Pure runtime selector — no side effects, takes the
    candidate list as an argument so callers can run
    deterministic tests without mutating the global pool.

    Selection rules:
    - filter by [preferred_pool] when given (fall back to
      all runtimes when no match);
    - require an exact [model] match when [model_name]
      names a non-generic label, otherwise allow generic
      runtimes;
    - drop runtimes still in cooldown;
    - sort by ([active_slots], [latency_ema_ms]) ascending
      and pick the first.

    Errors when no candidate satisfies the filters. *)

val acquire :
  ?preferred_pool:string ->
  model_name:string option ->
  unit ->
  (assignment, string) result
(** Picks a runtime via {!select_runtime_from}, increments
    its [active_slots], and returns the {!assignment}.
    Holds the pool lock for the slot bump so concurrent
    acquires serialize cleanly.  Errors when selection
    fails (no eligible runtime). *)

val release :
  lease ->
  success:bool ->
  ?error:string ->
  ?latency_ms:int ->
  unit ->
  unit
(** Returns a previously-acquired lease.  Decrements
    [active_slots], folds the latency into [latency_ema_ms]
    when given, and updates the success / failure counters.
    On three consecutive failures opens a cooldown window
    via {!cooldown_seconds}.  Idempotent on unknown leases
    (missing runtime id is silently dropped — useful when
    the pool was reset between acquire and release). *)

(** {1 Snapshot serialization} *)

val snapshot_to_yojson : runtime_snapshot -> Yojson.Safe.t
(** Wire-format encoder used by the operator dashboard
    endpoint.  Field names mirror the record exactly; option
    fields collapse to JSON [null] when absent. *)
