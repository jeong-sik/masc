(** Dashboard_mission_assembly — keeper briefs, operation
    contexts, session assembly, internal signals, and
    timeline rendering for the mission dashboard.

    {b Cascade chain}: includes
    {!Dashboard_mission_agents} (which itself cascades
    {!Dashboard_utils}), so callers reach the agent-brief
    + per-entity context records ({!attention_context},
    {!session_context}, {!agent_context},
    {!keeper_context}, {!operation_context},
    {!archived_agent_meta}) and {!build_agent_briefs}
    unqualified through this module's facade.  Type
    identity propagates end-to-end via
    [include module type of struct include M end].

    External surface beyond the cascade (8 own-module
    entries) — all consumed by {!Dashboard_mission} when
    rendering the mission HTTP envelope, plus
    [build_keeper_briefs] reached directly by
    [test/test_dashboard_mission.ml].

    Internal helpers stay private at this boundary
    ([lane_pressure_ctx_ratio] tuning constant,
    [keeper_tool_audit_json_fields],
    [is_internal_action] / [is_internal_incident],
    [incident_action_types],
    [identity_digest], [action_identity],
    [matched_internal_action_keys],
    [operation_badge_json], [severity_rank],
    [option_to_json] / [json_string_option] /
    [string_list_json] envelope helpers,
    [parse_iso_opt] / [trim_to_option],
    [take]). *)

include module type of struct
  include Dashboard_mission_agents
end

(** {1 Brief / context builders} *)

val build_keeper_briefs :
  Coord.config -> Yojson.Safe.t list -> Yojson.Safe.t list
(** Assembles the keeper brief list from a raw [keepers]
    JSON list.  Looks up each keeper through the
    {!Keeper_registry}, falling back to in-band fields
    ([allowed_tool_names], [latest_tool_names]) when the
    registry has no record.  Pinned because
    [test/test_dashboard_mission.ml] exercises this path
    directly. *)

val build_internal_signals :
  Yojson.Safe.t list ->
  Yojson.Safe.t list ->
  Yojson.Safe.t list
(** [build_internal_signals incidents actions] fuses the
    operator's incident + recommended-action streams into
    one internal-signal list, sorted by descending
    pressure rank. *)

val build_operation_contexts : tasks:Masc_domain.task list -> operation_context list
(** Projects non-terminal tasks into operation contexts for mission
    badges.  Task contract links provide operation/session ids when
    available; otherwise the task id remains visible as the operation id. *)

(** {1 Session assembly} *)

val build_sessions :
  ?operation_contexts:operation_context list ->
  session_context list ->
  attention_context list ->
  Yojson.Safe.t list ->
  Yojson.Safe.t list ->
  Yojson.Safe.t list
(** [build_sessions ?operation_contexts sessions attention_queue
      agent_briefs keeper_briefs] renders the session row JSON list,
    sorted by attention count → severity rank → recency.
    Each row carries the embedded [member_previews] /
    [operation_badges] / [keeper_refs] envelopes built
    via the helpers below. *)

val operation_badges_for_session :
  session_context ->
  operation_context list ->
  Yojson.Safe.t list
(** Returns the operation-badge JSON list for a session.
    Falls back to a synthetic ["unknown"] badge when the
    session declares an [operation_id] but no matching
    {!operation_context} is present. *)

val participant_preview_json :
  string ->
  string list ->
  Yojson.Safe.t list ->
  Yojson.Safe.t list
(** [participant_preview_json session_id member_names
      agent_briefs] returns the per-member preview JSON
    list — one entry per name in [member_names] (deduped),
    cross-referenced against [agent_briefs]. *)

val keeper_refs_for_session :
  string list -> Yojson.Safe.t list -> Yojson.Safe.t list
(** [keeper_refs_for_session member_names keeper_briefs]
    returns the keeper-ref JSON list filtered to keepers
    whose name appears in [member_names]. *)

(** {1 Timeline rendering} *)

val session_timeline_json : Yojson.Safe.t -> Yojson.Safe.t list
(** Renders the session's recent-events list (top 10 by
    descending timestamp) into the dashboard timeline
    JSON shape — [id] / [timestamp] / [event_type] /
    [actor] / [summary] fields. *)
