(** Workspace_goals — Goal-management MCP tool handlers.

    Reachable from {!Tool_workspace.dispatch} for goal list, upsert, and
    transition operations. Goal data is persisted via {!Goal_store};
    this module owns parsing, validation, and response shapes. *)

(** [handle_goal_list ctx args] handles [masc_goal_list].
    Optional filter: [phase] (executing / blocked / completed / etc.).
    Returns the goal list with a
    rollup summary.  Validation errors return
    [(false, error_json)] without touching the store. *)
val handle_goal_list
  :  tool_name:string
  -> start_time:float
  -> Workspace_types.context
  -> Yojson.Safe.t
  -> Tool_result.result

(** [handle_goal_upsert ctx args] handles [masc_goal_upsert] —
    create-or-update a goal record. Validates priority and rejects lifecycle
    fields, which belong to [masc_goal_transition]. Lifecycle field errors are
    reported via the dedicated
    [goal_upsert_lifecycle_error] formatter. *)
val handle_goal_upsert
  :  tool_name:string
  -> start_time:float
  -> Workspace_types.context
  -> Yojson.Safe.t
  -> Tool_result.result

(** [handle_goal_assign ctx args] handles [masc_goal_assign] — RFC-0362 §4.2.
    Both [goal_id] and [owner] are required; omitting [owner] is an error, never
    an auto-pick. [owner] must name a registered keeper (its metadata file under
    the keepers runtime dir); an unknown goal or unknown owner is a typed
    validation error rather than a permissive default. *)
val handle_goal_assign
  :  tool_name:string
  -> start_time:float
  -> Workspace_types.context
  -> Yojson.Safe.t
  -> Tool_result.result

(** [handle_goal_transition ctx args] handles
    [masc_goal_transition].  Required arg: [action] (one of
    {!goal_transition_action_strings}). [request_complete] moves an executing
    Goal directly to [Completed]. *)
val handle_goal_transition
  :  tool_name:string
  -> start_time:float
  -> Workspace_types.context
  -> Yojson.Safe.t
  -> Tool_result.result
