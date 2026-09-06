(** Local_runtime_pool — local LLM runtime pool with
    health / cooldown / least-loaded selection.

    Tracks every locally-discovered LLM HTTP endpoint
    ([http://127.0.0.1:<port>] etc) as a {!runtime} entry
    with EMA-smoothed latency, an active-slot counter, a
    failure streak, and a cooldown window after repeated
    failures.

    {1 Status — 2026-05-05}

    The leasing API ([acquire] / [release] / [lease] /
    [assignment]) had zero production callers as of
    2026-05-05 and was removed surgically per audit response;
    if leasing semantics are needed in the future, the design
    should land at the AGENT_CORE runtime layer per RFC-0026 (the
    same architectural rollback as [admission_queue]).
    [parse_errors] below is currently unconsumed — the local-runtime
    status tool that surfaced it was removed — but is retained because
    it captures runtime.toml load-time parse errors. See
    [docs/audit-responses/2026-05-05-dashboard-heuristic.md]
    §7.1 for the verification matrix.

    State architecture: the process-global value is an atomic reference to an
    immutable [pool_state], with compound refreshes serialized by a standard
    mutex. Production and test code reach it only through typed accessors. *)

(** {1 Runtime + snapshot records} *)

type runtime = {
  id : string;
  base_url : string;
  model : string option;
  max_concurrency : int;
  active_slots : int;
  queue_depth : int;
  failure_streak : int;
  cooldown_until : float option;
  last_error : string option;
  total_started : int;
  total_success : int;
  total_failure : int;
}
(** Per-endpoint runtime entry.  [failure_streak] is 1 when the latest
    discovery pass marked the endpoint unhealthy (else 0); unhealthy
    endpoints also get a [cooldown_until] window so the selector skips
    the runtime until the window elapses. *)

type runtime_snapshot = {
  id : string;
  base_url : string;
  model : string option;
  max_concurrency : int;
  active_slots : int;
  queue_depth : int;
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

type pool_state = {
  runtimes : runtime list;
  fingerprint : string;
  parse_errors : string list;
}
(** Snapshot of the pool.  [fingerprint] is recomputed from
    the discovery cache on each load and used by
    {!ensure_loaded} to detect that the underlying endpoints
    have changed. *)

(** {1 Constants + global state} *)

val default_pool_label : string
(** ["local64"] — the canonical label used when the caller
    does not specify a [preferred_pool]. *)

(** {1 Lifecycle} *)

val reset : unit -> unit
(** Reinstalls the empty state under the pool lock.  Used by
    tests to clear state between cases. *)

module For_testing : sig
  val install_pool : runtime list -> unit
  (** Install a deterministic runtime snapshot under the pool lock. *)
end

val runtime_id_of_base_url : string -> string
(** Derives a stable runtime id from a [base_url] (e.g.
    ["http://127.0.0.1:8081"] →
    ["local-127-0-0-1-8081"]).  Identical URLs always map
    to the same id; the id is the join key between the
    discovery cache and the pool entries. *)

(** {1 Read accessors (locked)} *)

val snapshots : unit -> runtime_snapshot list
(** Read-only projection of every {!runtime} into a
    {!runtime_snapshot} (adds derived [port]).  Caller may
    keep the list across yields — values are immutable. *)



(** {1 Snapshot serialization} *)

val snapshot_to_yojson : runtime_snapshot -> Yojson.Safe.t
(** Wire-format encoder used by the operator dashboard
    endpoint.  Field names mirror the record exactly; option
    fields collapse to JSON [null] when absent. *)
