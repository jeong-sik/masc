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
(** What a published tool audit says about its own read. An audit that was
    read and holds no tool call is [Tool_audit_read]; the other two say
    nothing about what the Keeper called. *)
type tool_audit_read_state =
  | Tool_audit_read
  | Tool_audit_timed_out
  | Tool_audit_unreadable

val tool_audit_read_field : string
(** The JSON field that carries {!tool_audit_read_state_to_wire}. *)

val tool_audit_read_error_field : string
(** The JSON field that carries the diagnostic of an unreadable audit. *)

val tool_audit_read_state_to_wire : tool_audit_read_state -> string
(** ["read"], ["timed_out"] or ["unreadable"]. *)

val empty_tool_audit_snapshot : tool_audit_snapshot
val latest_tool_audit_snapshot_from_files :
  Workspace.config ->
  keeper_name:string ->
  (tool_audit_snapshot option, Dated_jsonl.read_error) result
(** The newest recorded turn's tool audit. [Ok None] means the metrics store
    holds no turn row; [Error] means the store could not be read, which says
    nothing about whether a turn was recorded.

    The value is a fact of the Keeper's metrics store
    ({!Dated_jsonl.newest_selected}). A process that holds the workspace's
    writer lease and has said so ([Server_startup_takeover.keep_store_facts])
    keeps it in memory and reads no file for it; any other process reads the
    files each time. Code that removes the store's files without going through
    [Dated_jsonl] tells it with {!Dated_jsonl.directories_removed}, as the
    Keeper's purge does. *)

val recent_metrics_row_count : int
(** How many of a Keeper's newest metrics rows the Keeper list's recent tools
    and the metrics chart look at. *)

val newest_metrics_lines_result :
  Workspace.config -> keeper_name:string -> (string list, Dated_jsonl.read_error) result
(** The text of the Keeper's newest {!recent_metrics_row_count} metrics rows,
    oldest first, as [Dated_jsonl.read_recent_lines_result] reads them: a row
    that is not JSON keeps its place. Decode a row with
    {!Dated_jsonl.parse_line}.

    A fact of the Keeper's metrics store ({!Dated_jsonl.last_lines}), kept and
    forgotten as {!latest_tool_audit_snapshot_from_files} is. *)

val newest_metrics_lines_passing_over_what_is_not_the_stores :
  Workspace.config -> keeper_name:string -> string list
(** {!newest_metrics_lines_result} for a reader that shows the rows it can.
    When the strict read refuses the store, the rows are read with
    [Dated_jsonl.read_recent_lines], which passes over a directory entry that
    is not the store's and answers no row for a directory it cannot list. *)
