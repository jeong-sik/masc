(** Dashboard_gate_metrics — operator-visible aggregates of tool
    rejections and the live approval queue.

    Two ingestion paths backing the public surface:
    - In-memory ring of recent tool-skip events fed by
      [record_tool_skipped] (the [Keeper_keepalive_signal] callback).
    - Workspace-scoped durable approval queue reads.

    The ring buffer, rejection event record, and supporting helpers
    (snapshot, percentile, JSON projection) are intentionally hidden:
    callers consume the top-level [gate_tool_events_json] payload
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

val approval_queue_summary :
  now_ts:float ->
  base_path:string ->
  unit ->
  (approval_summary, Keeper_approval_queue.storage_error) result
(** Read the current approval queue and produce depth + wait-time
    percentiles. Durable store unavailability remains explicit. *)

val gate_tool_events_json :
  base_path:string ->
  window_minutes:int ->
  unit ->
  Yojson.Safe.t
(** Top-level HTTP endpoint payload combining tool-rejection counts
    over the [window_minutes] window with the approval queue summary.
    The production boundary samples its clock exactly once. *)

(** {1 Test hooks} *)

val reset_for_testing : unit -> unit
(** Drop every event from the in-memory ring so an alcotest case can
    start from a clean state regardless of test order. *)

val inject_for_testing :
  tool_name:string ->
  reason_code:string ->
  ts:float ->
  unit
(** Push a synthetic skip event into the ring without going through
    the production [record_tool_skipped] path so tests can backdate
    [ts] for window-boundary assertions. *)

val max_ring_size_for_testing : int
(** Production ring cap, exposed only so tests do not duplicate the
    bounded-buffer constant. *)

val ring_size_for_testing : unit -> int
(** Current bounded ring size. *)

val record_tool_skipped_with_append_for_testing :
  append:(unit -> unit) ->
  tool_name:string ->
  reason_code:string ->
  unit
(** Run the production exception-handling path with an injected append
    callback so tests can prove metrics/log visibility without relying
    on an actual mutex failure. *)

val gate_tool_events_json_with_pending_result_for_testing :
  now_ts:float ->
  window_minutes:int ->
  ( Keeper_approval_queue_rules_types.pending_approval list
  , Keeper_approval_queue.storage_error )
  result ->
  Yojson.Safe.t
(** Project an injected workspace read result through the production
    ready/unavailable JSON boundary. *)

val tool_rejection_counts :
  now_ts:float ->
  window_minutes:int ->
  unit ->
  (string * string * int) list
(** Aggregate [(tool_name, reason_code, count)] over the supplied
    window. [now_ts] is injectable for testing. Returns a deterministic
    ordering: count desc, then tool_name asc, then reason_code asc.
    Exposed for direct test access; the HTTP path consumes it via
    {!gate_tool_events_json}. *)
