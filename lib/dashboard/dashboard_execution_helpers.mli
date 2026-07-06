(** Dashboard_execution_helpers — JSON envelope helpers,
    per-entity context records, agent-profile resolver,
    and tone/severity utilities for the execution
    dashboard pipeline.

    {b Runtime chain}: 3 sister modules
    ({!Dashboard_execution_fixture},
    {!Dashboard_execution_sessions},
    {!Dashboard_execution}) do
    [include Dashboard_execution_helpers] in their .ml +
    .mli, so this boundary's surface flows through to
    every dashboard execution consumer.  Plus dotted
    callers ({!get_agent_profile} from
    [server_dashboard_http_core] +
    [server_routes_http_routes_workspace]).

    External surface (38 entries — 8 records + 30
    helpers).

    Internal helpers stay private at this boundary
    ([all_agent_statuses] / [valid_agent_status_strings]
    re-exports, [neo4j_identity_cache] /
    [neo4j_cache_loaded] / [neo4j_cache_mu] /
    [populate_neo4j_identity_cache_locked] internal
    cache state and loader, the every-other-let
    accumulator helpers consumed only inside
    [tool_audit_snapshot] / [skill_route_summary_of_keeper]
    /
    [load_persona_profile] / [resolve_persona_name] /
    [merge_profiles] / [lookup_neo4j_profile] /
    [is_keeper_offline] / [is_health_at_risk] /
    [is_session_terminal] / [option_or_else] /
    [string_list_json] / [latest_iso_timestamp] /
    [cap_string_list] / [execution_tool_preview_limit] / [tool_audit_snapshot]
    / [skill_route_summary_of_keeper] /
    [string_list_of_field]). *)

(** {1 Tone} *)

type tone = Dashboard_utils.tone =
  | Tone_ok
  | Tone_warn
  | Tone_bad
(** Severity tone re-export from {!Dashboard_utils.tone}.
    Type-equality preserves so every runtime consumer
    (Dashboard_briefing_assembly, etc.) can use the same
    constructors regardless of which alias they reach
    them through. *)


(** {1 Per-entity context records} *)

type queue_context = {
  severity_rank : int;
  last_seen_ts : float;
  json : Yojson.Safe.t;
}

type session_seed = {
  session_id : string;
  goal : string;
  namespace : string option;
  status : string option;
  health : string;
  member_names : string list;
  last_activity_at : string option;
  last_activity_ts : float;
  last_activity_summary : string;
  communication_summary : string;
  active_count : int;
  seen_count : int;
  planned_count : int;
  required_count : int;
  counts_basis : string;
  runtime_blocker : string option;
  worker_gap_summary : string option;
  top_attention : Yojson.Safe.t option;
  top_recommendation : Yojson.Safe.t option;
}

type session_context = {
  session_id : string;
  severity : tone;
  last_seen_ts : float;
  linked_operation_id : string option;
  member_names : string list;
  json : Yojson.Safe.t;
}

type operation_context = {
  operation_id : string;
  severity : tone;
  last_seen_ts : float;
  linked_session_id : string option;
  linked_detachment_id : string option;
  json : Yojson.Safe.t;
}

type worker_context = {
  tone_rank : int;
  last_signal_ts : float;
  related_session_id : string option;
  json : Yojson.Safe.t;
}

type continuity_context = {
  tone_rank : int;
  last_signal_ts : float;
  related_session_id : string option;
  json : Yojson.Safe.t;
}

type tool_audit_snapshot = {
  latest_tool_names : string list;
  latest_tool_call_count : int option;
  latest_action_source : string option;
  tool_audit_source : string option;
  tool_audit_at : string option;
}

(** {1 Agent profile} *)

type agent_profile = {
  emoji : string;
  korean_name : string;
  model : string option;
  traits : string list;
  interests : string list;
  activity_level : float option;
  primary_value : string option;
  profile_errors : agent_profile_error list;
}

and agent_profile_error = {
  source : agent_profile_error_source;
  path : string option;
  detail : string;
}

and agent_profile_error_source =
  | Profile_identity_normalization
  | Persona_profile_file

val get_agent_profile : string -> agent_profile
(** Resolves the agent's profile through the persona
    file → Neo4j cache → fallback chain. *)

val agent_profile_errors_json : agent_profile -> Yojson.Safe.t
(** Serializes profile lookup errors carried by {!agent_profile}. *)

(** {1 JSON envelope helpers} *)

val member_assoc : string -> Yojson.Safe.t -> Yojson.Safe.t
val string_field : ?default:string -> string -> Yojson.Safe.t -> string
val list_field : string -> Yojson.Safe.t -> Yojson.Safe.t list
val string_list_of_field : string -> Yojson.Safe.t -> string list

(** {1 Misc helpers} *)

val option_or_else : (unit -> 'a option) -> 'a option -> 'a option
val take : int -> 'a list -> 'a list
val latest_iso_timestamp : string option list -> string option
val compact_text : ?max_len:int -> string -> string
val dedup_strings : string list -> string list
val session_payload_json : Yojson.Safe.t -> Yojson.Safe.t
val session_meta_json : Yojson.Safe.t -> Yojson.Safe.t
val session_summary_json : Yojson.Safe.t -> Yojson.Safe.t
val session_team_health_json : Yojson.Safe.t -> Yojson.Safe.t
val session_communication_json : Yojson.Safe.t -> Yojson.Safe.t
val session_status_opt : Yojson.Safe.t -> string option
val session_recent_events : Yojson.Safe.t -> Yojson.Safe.t list
val event_detail_json : Yojson.Safe.t -> Yojson.Safe.t
val severity_rank : string -> int
val dashboard_fixture_name : ?fixture:string -> unit -> string option
val execution_tool_preview_limit : int
val cap_string_list : ?limit:int -> string list -> string list

(** {1 Health predicates} *)


(** {1 Tool audit + skill route} *)

val tool_audit_snapshot : string -> tool_audit_snapshot
(** Returns the most recent tool-audit projection for *)

val skill_route_summary_of_keeper : Yojson.Safe.t -> string option

(** {1 Handoff envelope} *)

val handoff_json :
  surface:string ->
  ?command_surface:string ->
  ?operation_id:string ->
  label:string ->
  target_type:string ->
  target_id:string ->
  focus_kind:string ->
  unit ->
  Yojson.Safe.t
