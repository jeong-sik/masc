type metrics_summary

type tool_audit_snapshot = {
  latest_tool_names : string list;
  latest_tool_call_count : int option;
  latest_action_source : string option;
  tool_audit_source : string option;
  tool_audit_at : string option;
}

val empty_metrics_summary : metrics_summary
val age_seconds_opt : now_ts:float -> float -> float option
(** Convert a persisted timestamp to an age while preserving the [0.0]
    sentinel as [None]. A missing event must not render as "just now". *)
val metrics_summary_to_json : metrics_summary -> Yojson.Safe.t
(** Render the window counters as JSON: [sample_points], [turn_points],
    [heartbeat_points], [proactive_points], [window_interactions] and the two
    intervention ratios. Counts only, so a Keeper that has never run and a
    Keeper whose rows failed to decode are told apart by [sample_points]. *)

val summarize_metrics_lines : string list -> metrics_summary
(** Fold metrics-ledger lines into the window counters.

    A Turn row counts when it carries [ts_unix], a non-empty [trace_id] and a
    [channel] the observation vocabulary knows; a Heartbeat row counts when it
    carries [ts_unix] and the literal channel ["heartbeat"]. Every row the
    producer writes today satisfies one of those shapes. Rows failing to parse
    as JSON are reported through the persistence read-drop surface; rows of an
    unknown record kind are skipped without counting. *)
val empty_tool_audit_snapshot : tool_audit_snapshot
val latest_tool_audit_snapshot_from_files :
  Workspace.config -> keeper_name:string -> tool_audit_snapshot option
val invalidate_tool_audit_cache :
  Workspace.config -> keeper_name:string -> unit
(** Forget the process-local tool-audit snapshot when a Keeper metrics
    directory is removed. A later Keeper with the same name must not inherit
    the deleted runtime's audit state. *)
