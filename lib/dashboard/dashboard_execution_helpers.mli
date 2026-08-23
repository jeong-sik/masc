(** Dashboard_execution_helpers — JSON envelope helpers,
    per-entity context records, agent-profile resolver,
    and tone/severity utilities for the execution
    dashboard pipeline.

    {b Runtime chain}: 3 sister modules
    ({!Dashboard_execution_fixture}, {!Dashboard_execution}) do
    [include Dashboard_execution_helpers] in their .ml +
    .mli, so this boundary's surface flows through to
    every dashboard execution consumer.  Plus dotted
    callers ({!get_agent_profile} from
    [server_dashboard_http_core] +
    [server_routes_http_routes_workspace]).

    External surface is limited to the records and helpers consumed by the
    current execution projection.

    Internal helpers stay private at this boundary
    ([all_agent_statuses] / [valid_agent_status_strings]
    re-exports, [neo4j_identity_cache] /
    [neo4j_cache_loaded] / [neo4j_cache_mu] /
    [populate_neo4j_identity_cache_locked] internal
    cache state and loader, the every-other-let
    accumulator helpers consumed only inside
    [extract_keeper_name] / [lookup_neo4j_profile] /
    [is_keeper_offline] / [is_health_at_risk] / [option_or_else] /
    [string_list_json] / [latest_iso_timestamp] /
    [cap_string_list] / [execution_tool_preview_limit] /
    [string_list_of_field]). *)

val extract_keeper_name : string -> string
(** Strip a keeper-agent alias down to the keeper name, or return the input
    unchanged when it is not one. Delegates to
    [Keeper_identity.keeper_name_of_agent_alias], which owns the four accepted
    spellings; exported so a test can pin all four rather than only the pair
    this module used to hand-roll. *)

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

type operation_context = {
  operation_id : string;
  severity : tone;
  last_seen_ts : float;
  json : Yojson.Safe.t;
}

type worker_context = {
  tone_rank : int;
  last_signal_ts : float;
  json : Yojson.Safe.t;
}

type continuity_context = {
  tone_rank : int;
  last_signal_ts : float;
  json : Yojson.Safe.t;
}

(** {1 Agent profile} *)

type agent_profile = {
  emoji : string;
  korean_name : string;
}

val get_agent_profile : string -> agent_profile
(** Resolves the agent's profile through Neo4j and an identity fallback. *)

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
val dashboard_fixture_name : ?fixture:string -> unit -> string option
val cap_string_list : ?limit:int -> string list -> string list

(** {1 Health predicates} *)


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
