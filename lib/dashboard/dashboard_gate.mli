(** Read-only dashboard projection of the non-hierarchical Keeper Gate. *)

val dashboard_json :
  base_path:string ->
  limit:int ->
  window_minutes:int ->
  Yojson.Safe.t
(** [dashboard_json ~base_path ~limit ~window_minutes] projects the Gate mode,
    the pending HITL queue, the exact Always Allowed rules, and the resolved
    decisions of the last [window_minutes] capped at [limit] rows.

    The resolved page is emitted as two fields that must be read together:
    ["recent_resolved"] holds the rows and ["recent_resolved_page"] holds the
    bounds that produced them ([returned], [matched], [limit],
    [window_minutes], [truncated], [scan_exhausted]). A client that renders the
    rows alone cannot distinguish a complete history from the newest slice of a
    larger one. Both bounds are enforced by
    {!Keeper_approval.Audit.list_recent_resolved}. *)
