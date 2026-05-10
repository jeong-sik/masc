
(** Tool_suspend — agent suspension and circuit-breaker tools.

    Implements the [masc_suspend] dispatch path (currently retired —
    {!schemas} is empty) and the {!check_can_join} guard the join
    handler invokes before allowing an agent into a room.  Maintains
    a per-process blacklist (in-memory [Hashtbl] guarded by an Eio
    mutex) for forced-leave / suspension records.

    Part of MASC Social v4 Tier 1 security layer.

    @since 0.6.0 *)

(** {1 Context} *)

type context = {
  config : Coord.config;
  caller_agent : string option;
}
(** Tool dispatch context.  [caller_agent] is the agent identity
    extracted from the JSON-RPC envelope, [None] when the caller is
    anonymous (system-level invocations).  Concrete record because
    test fixtures construct it field-by-field. *)

(** {1 Blacklist management}

    The blacklist is stored in a process-local [Hashtbl] guarded by
    an [Eio.Mutex.t].  Entries auto-expire on lookup
    ({!check_blacklist}); bulk-prune happens whenever the table
    accumulates beyond 32 entries.  All three accessors are
    thread-safe. *)

val add_to_blacklist :
  agent_id:string -> until:float -> reason:string -> unit
(** [add_to_blacklist ~agent_id ~until ~reason] inserts (or
    overwrites) a blacklist entry that expires at [until]
    (Unix epoch seconds, monotonic clock).  [reason] is operator-
    visible — it surfaces in the {!check_can_join} error message
    so dashboards can explain why the agent cannot join. *)

val check_blacklist :
  agent_id:string -> (float * string) option
(** [check_blacklist ~agent_id] returns [Some (until, reason)] when
    the agent is currently blacklisted, [None] when absent or when
    the entry has expired.  Expired entries are removed in-place
    on each call.

    Bulk-prune side effect: when the table size exceeds 32 entries,
    all expired records are removed in one pass.  The 32-entry
    threshold is tuned to keep the [Hashtbl] from growing unbounded
    in long-running processes while avoiding per-call O(n) scans
    in the small-table case. *)

val remove_from_blacklist : agent_id:string -> unit
(** [remove_from_blacklist ~agent_id] is a no-op when the agent is
    absent.  Used by tests and by manual unsuspend operator
    actions. *)

(** {1 Tool dispatch} *)

val schemas : Masc_domain.tool_schema list
(** Currently the empty list — [masc_suspend] has been retired from
    the public surface but the module remains live for the
    blacklist + circuit-breaker behaviours used by the join guard. *)

val dispatch :
  context -> name:string -> args:Yojson.Safe.t -> Tool_result.t option
(** [dispatch ctx ~name ~args] is the JSON-RPC dispatch hook.
    Currently always returns [None] (no tools dispatched here)
    because {!schemas} is empty.  The function is kept for the
    Tool_dispatch wiring contract; a future re-introduction of
    [masc_suspend] would extend this match. *)

(** {1 Join guard} *)

val check_can_join : agent_id:string -> (unit, string) Result.t
(** [check_can_join ~agent_id] is called before allowing an agent
    to join a room.  Two-stage check:

    1. {!check_blacklist} — if the agent is suspended, returns
       [Error] with a message of the form
       ["Agent '<id>' is suspended for <N> more seconds. Reason: <reason>"].
    2. Otherwise delegates to {!Circuit_breaker.check_global} —
       returns [Error] when the agent has tripped the global
       error-rate circuit breaker.

    The error message wording is operator-visible — runbooks and
    dashboard alerts grep on the literal "is suspended for" prefix
    to distinguish suspension from circuit-breaker rejection. *)
