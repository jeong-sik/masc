open Base

(** Coord_goals — Goal-management MCP tool handlers.

    Reachable from {!Tool_coord.dispatch} for the 5 goal tools:
    [masc_goal_list], [masc_goal_upsert], [masc_goal_transition],
    [masc_goal_verify], [masc_goal_review].  Goal data is
    persisted via {!Goal_store}; this module owns the parsing /
    validation / authorization / response-shape contract.

    Internal: ~27 helpers + 7 string lists stay private —
    \[goal_horizon_strings] / \[goal_status_strings] /
    \[goal_phase_strings] / \[goal_review_outcome_strings] /
    \[goal_transition_action_strings] /
    \[goal_vote_decision_strings] /
    \[goal_principal_kind_strings] (allowed-value tables for
    enum field validation), the
    \[make_enum_field_error] / \[make_type_field_error] error
    formatters, the 12 \[parse_optional_*] field parsers
    (horizon, goal_status, goal_phase, review_outcome, priority,
    bool, policy, principal, vote_decision, transition_action,
    string_list), \[goal_upsert_lifecycle_error],
    \[actor_must_be_operator] (operator-vs-keeper authorization
    gate), \[validate_goal_completion_ready],
    \[goal_policy_nodes], \[verification_summary_json],
    plus per-handler private branch helpers.  All consumed only
    inside the 5 public {!handle_goal_*} entries. *)

val handle_goal_list :
  Coord_types.context -> Yojson.Safe.t -> Coord_types.tool_result
(** [handle_goal_list ctx args] handles [masc_goal_list].
    Optional filters: [horizon] (short / mid / long), [status]
    (active / paused / done / dropped), [phase] (executing /
    awaiting_verification / etc.).  Returns the goal list with a
    rollup summary.  Validation errors return
    [(false, error_json)] without touching the store. *)

val handle_goal_upsert :
  Coord_types.context -> Yojson.Safe.t -> Coord_types.tool_result
(** [handle_goal_upsert ctx args] handles [masc_goal_upsert] —
    create-or-update a goal record.  Validates horizon /
    status / phase / priority / policy / principal /
    string_list fields against the pinned allowed-value tables.
    Lifecycle field errors are reported via the dedicated
    [goal_upsert_lifecycle_error] formatter. *)

val handle_goal_transition :
  Coord_types.context -> Yojson.Safe.t -> Coord_types.tool_result
(** [handle_goal_transition ctx args] handles
    [masc_goal_transition].  Required arg: [action] (one of
    {!goal_transition_action_strings}).  Operator-only
    transitions are gated by the internal
    [actor_must_be_operator] check — keeper callers receive a
    validation error.  Goal-completion transitions invoke
    {!validate_goal_completion_ready} which inspects task
    coverage and sub-goal status before allowing the move. *)

val handle_goal_verify :
  Coord_types.context -> Yojson.Safe.t -> Coord_types.tool_result
(** [handle_goal_verify ctx args] handles [masc_goal_verify] —
    record an operator/keeper verification vote (approve /
    reject) on a goal completion claim.  Updates the goal's
    verification summary; transitions to verified state when
    the policy quorum is met. *)

val handle_goal_review :
  Coord_types.context -> Yojson.Safe.t -> Coord_types.tool_result
(** [handle_goal_review ctx args] handles [masc_goal_review] —
    add a periodic review note to a goal with outcome (done /
    progress / blocked / dropped).  Reviews are append-only;
    drift to mutable updates would lose audit trail and break
    the verification timeline contract. *)
