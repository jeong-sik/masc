(** Dashboard_execution_sessions — session-context aggregation
    for the execution dashboard.

    {b Cascade chain}: starts with
    [include Dashboard_execution_helpers], so
    {!Dashboard_execution_builders} (which does
    [include Dashboard_execution_sessions]) re-exports the full
    helpers + this module surface upward to
    {!Dashboard_execution}.

    Internal: 14 functions stay private.  Only
    {!related_session_for_member} (used by
    {!Dashboard_execution_builders}) and
    {!build_execution_queue} (used by {!Dashboard_execution}) are
    cascade-visible.  The remaining helpers are keeper-internal
    and refactor-free:

    - 9 JSON field accessors ([session_payload_json],
      [session_meta_json], [session_summary_json],
      [session_team_health_json],
      [session_communication_json],
      [session_status_string],
      [session_recent_events],
      [event_detail_json],
      [event_summary]).
    - [session_severity] (severity classification).
    - [build_session_seed] / [session_operation_links] /
      [build_session_contexts] (session aggregation).
    - [queue_summary_of_session] (queue helper consumed by
      {!build_execution_queue}).

    Future "expose builder pipeline" PR can reopen these
    explicitly with intent. *)

include module type of struct
  include Dashboard_execution_helpers
end

(** {1 Member -> session lookup (cascade-visible)} *)

val related_session_for_member :
  session_context list -> string -> session_context option
(** [related_session_for_member contexts name] returns the first
    {!session_context} from [contexts] whose normalised
    member-name list contains [name] (lowercased + trimmed before
    comparison).  Returns [None] when no member matches.

    Used by {!Dashboard_execution_builders} to resolve
    agent / keeper member -> session relationships during brief
    aggregation.  Pinned at the contract seam — agent-name
    normalisation rules (lowercase + trim) must stay consistent
    across cascade consumers. *)

(** {1 Execution queue (cascade-visible)} *)

val build_execution_queue :
  session_context list ->
  operation_context list ->
  queue_context list
(** [build_execution_queue session_contexts operation_contexts]
    aggregates the dashboard execution queue: blocked / pending
    sessions plus their linked operation contexts, sorted by
    severity (descending) then by [last_seen_ts] (descending).
    Returns a list of structurally-typed queue-item records (each
    has at minimum [severity_rank: int] and
    [last_seen_ts: float]).  {!Dashboard_execution} consumes the
    list bare via include cascade and applies a [take 10] cap
    before serialisation. *)
