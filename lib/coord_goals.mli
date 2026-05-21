(** Coord_goals — Goal-management MCP tool handlers.

    Reachable from {!Tool_coord.dispatch} for the 4 goal tools:
    [masc_goal_list], [masc_goal_upsert], [masc_goal_transition],
    [masc_goal_verify].  Goal data is
    persisted via {!Goal_store}; this module owns the parsing /
    validation / authorization / response-shape contract.

    Internal: ~25 helpers + 6 string lists stay private —
    \[goal_horizon_strings] / \[goal_status_strings] /
    \[goal_phase_strings] / \[goal_transition_action_strings] /
    \[goal_vote_decision_strings] /
    \[goal_principal_kind_strings] (allowed-value tables for
    enum field validation), the
    \[make_enum_field_error] / \[make_type_field_error] error
    formatters, the 11 \[parse_optional_*] field parsers
    (horizon, goal_status, goal_phase, priority, bool, policy,
    principal, vote_decision, transition_action, string_list),
    \[goal_upsert_lifecycle_error],
    \[actor_must_be_operator] (operator-vs-keeper authorization
    gate), \[validate_goal_completion_ready],
    \[goal_policy_nodes], \[verification_summary_json],
    plus per-handler private branch helpers.  All consumed only
    inside the 4 public {!handle_goal_*} entries. *)

(** [handle_goal_list ctx args] handles [masc_goal_list].
    Optional filters: [horizon] (short / mid / long), [status]
    (active / paused / done / dropped), [phase] (executing /
    awaiting_verification / etc.).  Returns the goal list with a
    rollup summary.  Validation errors return
    [(false, error_json)] without touching the store. *)
val handle_goal_list
  :  tool_name:string
  -> start_time:float
  -> Coord_types.context
  -> Yojson.Safe.t
  -> Tool_result.t

(** [handle_goal_upsert ctx args] handles [masc_goal_upsert] —
    create-or-update a goal record.  Validates horizon /
    status / phase / priority / policy / principal /
    string_list fields against the pinned allowed-value tables.
    Lifecycle field errors are reported via the dedicated
    [goal_upsert_lifecycle_error] formatter. *)
val handle_goal_upsert
  :  tool_name:string
  -> start_time:float
  -> Coord_types.context
  -> Yojson.Safe.t
  -> Tool_result.t

(** [handle_goal_transition ctx args] handles
    [masc_goal_transition].  Required arg: [action] (one of
    {!goal_transition_action_strings}).  Operator-only
    transitions are gated by the internal
    [actor_must_be_operator] check — keeper callers receive a
    validation error.  Goal-completion transitions invoke
    {!validate_goal_completion_ready} which inspects task
    coverage and sub-goal status before allowing the move. *)
val handle_goal_transition
  :  tool_name:string
  -> start_time:float
  -> Coord_types.context
  -> Yojson.Safe.t
  -> Tool_result.t

(** [handle_goal_verify ctx args] handles [masc_goal_verify] —
    record an operator/keeper verification vote (approve /
    reject) on a goal completion claim.  Updates the goal's
    verification summary; transitions to verified state when
    the policy quorum is met. *)
val handle_goal_verify
  :  tool_name:string
  -> start_time:float
  -> Coord_types.context
  -> Yojson.Safe.t
  -> Tool_result.t
