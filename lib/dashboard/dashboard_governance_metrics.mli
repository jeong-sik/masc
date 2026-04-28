(** Dashboard_governance_metrics — operator-visible aggregates of tool
    rejections and the live approval queue.

    Two ingestion paths backing the public surface:
    - In-memory ring of recent tool-skip events fed by
      {!record_tool_skipped} (called from [Keeper_hooks_oas]).
    - Live approval queue read of
      {!Keeper_approval_queue.list_pending_json}.

    The ring buffer, rejection event record, and supporting helpers
    (snapshot, percentile, JSON projection) are intentionally hidden:
    callers consume the top-level [governance_tool_events_json] payload
    and the {!approval_summary} record only. *)

(** Approval queue snapshot computed from the live pending set.
    [depth] is the count of pending approvals; the percentile fields
    are [None] only when [depth = 0]. *)
type approval_summary = {
  depth : int;
  p50_wait_sec : float option;
  p95_wait_sec : float option;
  oldest_pending_sec : float option;
}

val record_tool_skipped :
  keeper_name:string -> tool_name:string -> reason_code:string -> unit
(** Record a tool-skip event into the bounded ring. Safe to call from
    cancellable Eio fibers — internal cancellation is re-raised, all
    other exceptions are swallowed so SSE broadcast can never fail
    because of metrics bookkeeping. *)

val approval_queue_summary : unit -> approval_summary
(** Read the current approval queue and produce depth + wait-time
    percentiles. *)

val governance_tool_events_json :
  ?now_ts:float -> window_minutes:int -> unit -> Yojson.Safe.t
(** Top-level HTTP endpoint payload combining tool-rejection counts
    over the [window_minutes] window with the approval queue summary.
    [now_ts] is injectable for testing. *)

(** {1 Test hooks} *)

val reset_for_testing : unit -> unit
(** Drop every event from the in-memory ring so an alcotest case can
    start from a clean state regardless of test order. *)

val inject_for_testing :
  keeper_name:string ->
  tool_name:string ->
  reason_code:string ->
  ts:float ->
  unit
(** Push a synthetic skip event into the ring without going through
    the production [record_tool_skipped] path so tests can backdate
    [ts] for window-boundary assertions. *)

val tool_rejection_counts :
  ?now_ts:float ->
  window_minutes:int ->
  unit ->
  (string * string * int) list
(** Aggregate [(tool_name, reason_code, count)] over the supplied
    window. [now_ts] is injectable for testing. Returns a deterministic
    ordering: count desc, then tool_name asc, then reason_code asc.
    Exposed for direct test access; the HTTP path consumes it via
    {!governance_tool_events_json}. *)
