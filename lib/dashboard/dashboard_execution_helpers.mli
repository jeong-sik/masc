(** Dashboard_execution_helpers — JSON envelope helpers,
    per-entity context records, agent-profile resolver,
    and tone/severity utilities for the execution
    dashboard pipeline.

    {b Cascade chain}: 3 sister modules
    ({!Dashboard_execution_fixture},
    {!Dashboard_execution_sessions},
    {!Dashboard_execution}) do
    [include Dashboard_execution_helpers] in their .ml +
    .mli, so this boundary's surface flows through to
    every dashboard execution consumer.  Plus 2 dotted
    callers ({!get_agent_identity} from
    [dashboard_http_keeper_metrics],
    {!get_agent_profile} from
    [server_dashboard_http_core] +
    [server_routes_http_routes_room]).

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
    [load_persona_profile] / [extract_persona_name] /
    [merge_profiles] / [lookup_neo4j_profile] /
    [is_keeper_offline] / [is_health_at_risk] /
    [is_session_terminal] / [option_or_else] /
    [string_list_json] / [latest_iso_timestamp] /
    [cap_string_list] / [tool_preview_fields] /
    [execution_tool_preview_limit] / [tool_audit_snapshot]
    / [skill_route_summary_of_keeper] /
    [string_list_of_field]). *)

(** {1 Tone} *)

type tone = Dashboard_utils.tone =
  | Tone_ok
  | Tone_warn
  | Tone_bad
(** Severity tone re-export from {!Dashboard_utils.tone}.
    Type-equality preserves so every cascade consumer
    (Dashboard_mission_assembly, etc.) can use the same
    constructors regardless of which alias they reach
    them through. *)

val string_of_tone : tone -> string
val tone_rank : tone -> int

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
  status : string;
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
  allowed_tool_names : string list;
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
}

val get_agent_profile : string -> agent_profile
(** Resolves the agent's profile through the persona
    file → Neo4j cache → fallback chain. *)

val get_agent_identity : string -> string * string
(** [(emoji, korean_name)] tuple for [name] — pinned for
    [dashboard_http_keeper_metrics]. *)

(** {1 JSON envelope helpers} *)

val json_string_option : string option -> Yojson.Safe.t
val option_to_json : ('a -> Yojson.Safe.t) -> 'a option -> Yojson.Safe.t
val member_assoc : string -> Yojson.Safe.t -> Yojson.Safe.t
val string_field : ?default:string -> string -> Yojson.Safe.t -> string
val string_field_opt : string -> Yojson.Safe.t -> string option
val int_field : ?default:int -> string -> Yojson.Safe.t -> int
val list_field : string -> Yojson.Safe.t -> Yojson.Safe.t list
val string_list_of_json : Yojson.Safe.t -> string list
val string_list_json : string list -> Yojson.Safe.t
val string_list_of_field : string -> Yojson.Safe.t -> string list

(** {1 Misc helpers} *)

val option_or_else : (unit -> 'a option) -> 'a option -> 'a option
val take : int -> 'a list -> 'a list
val trim_to_option : string -> string option
val parse_iso_opt : string option -> float option
val latest_iso_timestamp : string option list -> string option
val compact_text : ?max_len:int -> string -> string
val dedup_strings : string list -> string list
val severity_rank : string -> int
val dashboard_fixture_name : ?fixture:string -> unit -> string option
val execution_tool_preview_limit : int
val cap_string_list : ?limit:int -> string list -> string list
val tool_preview_fields :
  ?limit:int -> string -> string list -> (string * Yojson.Safe.t) list

(** {1 Health predicates} *)

val is_keeper_offline : string -> bool
val is_health_critical : Dashboard_utils.health_level -> bool
val is_health_warning : Dashboard_utils.health_level -> bool
val is_health_at_risk : Dashboard_utils.health_level -> bool
val is_session_terminal : Dashboard_utils.session_lifecycle -> bool
val is_session_blocked : Dashboard_utils.session_lifecycle -> bool

(** {1 Tool audit + skill route} *)

val tool_audit_snapshot : string -> tool_audit_snapshot
(** Returns the most recent tool-audit projection for
    [agent_name] from the A2A heartbeat snapshots. *)

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
