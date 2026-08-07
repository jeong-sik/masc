(** Dashboard_briefing_assembly — keeper briefs and internal signals
    for the mission dashboard.

    {b Runtime chain}: includes
    {!Dashboard_briefing_agents} (which itself runtimes
    {!Dashboard_utils}), so callers reach the agent-brief
    + per-entity context records ({!attention_context},
    {!agent_context}, {!keeper_context}) and {!build_agent_briefs}
    unqualified through this module's facade.  Type
    identity propagates end-to-end via
    [include module type of struct include M end].

    External surface beyond the runtime (8 own-module
    entries) — all consumed by {!Dashboard_briefing} when
    rendering the mission HTTP envelope, plus
    [build_keeper_briefs] reached directly by
    [test/test_dashboard_briefing.ml].

    Internal helpers stay private at this boundary
    ([lane_pressure_ctx_ratio] tuning constant,
    [keeper_tool_audit_json_fields],
    [is_internal_action] / [is_internal_incident],
    [identity_digest], [action_identity], [severity_rank],
    [option_to_json] / [Json_util.string_opt_to_json] /
    [string_list_json] envelope helpers,
    [parse_iso_opt] / [trim_to_option],
    [take]). *)

include module type of struct
  include Dashboard_briefing_agents
end

(** {1 Brief / context builders} *)

val build_keeper_briefs :
  Workspace.config -> Yojson.Safe.t list -> Yojson.Safe.t list
(** Assembles the keeper brief list from a raw [keepers]
    JSON list.  Looks up each keeper through the
    {!Keeper_registry}, falling back to in-band fields
    ([latest_tool_names]) when file-backed audit data has no record.  Pinned because
    [test/test_dashboard_briefing.ml] exercises this path
    directly. *)

val build_internal_signals :
  Yojson.Safe.t list ->
  Yojson.Safe.t list ->
  Yojson.Safe.t list
(** [build_internal_signals incidents actions] emits the operator's incident
    and recommended-action streams as one internal-signal list, sorted by
    descending pressure rank. Each row carries the stream it came from and
    leaves the other field [null]: the digest records no link between an
    attention item and a recommended action, so none is asserted. *)
