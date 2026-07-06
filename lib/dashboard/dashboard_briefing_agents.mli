(** Dashboard_briefing_agents — agent briefs + per-entity context
    records for the mission dashboard.

    {b Runtime chain}: starts with [include Dashboard_utils], so
    {!Dashboard_briefing_assembly} (which does [include
    Dashboard_briefing_agents]) re-exports the full
    Dashboard_utils + this module surface to
    {!Dashboard_briefing}.

    Internal: 9 helpers (\[build_task_lookup\],
    \[latest_message_from\], \[latest_message_to\],
    \[read_recent_workspace_event_lines\], \[is_session_concluded\],
    \[status_of_archived_session\], \[archived_reason_for_session\],
    \[archived_agent_meta_map\], \[keeper_alias_by_agent_name\])
    stay private — none are referenced bare in the runtime
    consumer.  Future "expose archive utilities" PR can reopen
    explicitly. *)

include module type of struct
  include Dashboard_utils
end

(** {1 Dashboard JSON helpers (runtime-visible)} *)

val dedup_strings : string list -> string list
(** [dedup_strings items] is [List.sort_uniq String.compare items].
    Used by Dashboard_briefing_assembly during agent / keeper list
    aggregation. *)

val event_detail_json : Yojson.Safe.t -> Yojson.Safe.t
(** [event_detail_json event_json] returns
    [event_json.detail] as a JSON value (or [\`Null] when missing). *)

val event_summary : Yojson.Safe.t -> string
(** [event_summary event_json] returns a one-line text summary of
    the event for dashboard display. *)

val session_recent_events : Yojson.Safe.t -> Yojson.Safe.t list
(** [session_recent_events session_json] returns
    [session_json.recent_events] as a JSON list (or [\[\]] when
    missing). *)

(** {1 Per-entity context records}

    Each context record bundles (a) sort / rank fields used by
    cross-section ordering and (b) the rendered JSON payload.
    Concrete records because runtime consumers
    ({!Dashboard_briefing_assembly},
    {!Dashboard_briefing}) construct them field-by-field. *)

type session_context = {
  session_id : string;
  goal : string;
  created_by : string option;
  origin_kind : string;
  namespace : string option;
  status : Dashboard_utils.session_lifecycle;
  health : Dashboard_utils.health_level;
  member_names : string list;
  started_at : string option;
  elapsed_sec : int option;
  operation_id : string option;
  blocker_summary : string option;
  last_event_at : string option;
  last_event_ts : float;
  last_event_summary : string;
  communication_summary : string;
  active_count : int;
  seen_count : int;
  planned_count : int;
  required_count : int;
  counts_basis : string;
  top_attention : Yojson.Safe.t option;
  top_recommendation : Yojson.Safe.t option;
}

type attention_context = {
  severity : string;
  has_action : bool;
  last_seen_ts : float;
  related_session_ids : string list;
  related_agent_names : string list;
  json : Yojson.Safe.t;
}

type agent_context = {
  status_rank : int;
  related_attention_count : int;
  last_seen_ts : float;
  json : Yojson.Safe.t;
}

type keeper_context = {
  pressure_rank : int;
  last_seen_ts : float;
  json : Yojson.Safe.t;
}

type operation_context = {
  operation_id : string;
  linked_session_id : string option;
  status : string option;
  detachment_status : string option;
  objective : string option;
  updated_at : string option;
}

type archived_agent_meta = {
  last_event_at : string option;
}

(** {1 Brief builder} *)

val latest_message_to :
  string -> Masc_domain.message list -> Masc_domain.message option
(** [latest_message_to agent_name messages] returns the most recent message
    that mentions [agent_name] and was not sent by it. Exposed for testing:
    tolerates an empty/whitespace-only [agent_name] (returns [None] rather than
    raising). *)

val build_agent_briefs :
  Workspace.config ->
  session_context list ->
  attention_context list ->
  Yojson.Safe.t ->
  Yojson.Safe.t list ->
  Yojson.Safe.t list
(** [build_agent_briefs config sessions attention_queue workspace_json
      keepers] aggregates per-agent briefs from session contexts +
    attention queue + keeper list.

    [workspace_json] is currently unused (placeholder for future workspace
    metadata expansion) — kept in signature for forward compat.

    Returns a JSON list, one entry per active / archived agent,
    sorted for dashboard display. *)

val build_agent_briefs_with_read_errors :
  Workspace.config ->
  session_context list ->
  attention_context list ->
  Yojson.Safe.t ->
  Yojson.Safe.t list ->
  Yojson.Safe.t list * Yojson.Safe.t list
(** [build_agent_briefs_with_read_errors] returns the same agent brief list as
    {!build_agent_briefs}, plus row-indexed read errors observed while scanning
    archived workspace-event metadata. *)
