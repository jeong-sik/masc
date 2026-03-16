(** Keeper_turn — keeper lifecycle and message-turn handlers.

    Provides MCP tool handlers for keeper agent management:
    start/stop, message dispatch, and model switching.
    Internal helpers (team session dispatch, planner/executor spawn,
    JSON serialization) are hidden.
*)

(** Tool handler return type: (success, message). *)
type tool_result = Keeper_types.tool_result

(** Start or reconfigure a keeper agent. *)
val handle_keeper_up : _ Keeper_types.context -> Yojson.Safe.t -> tool_result

(** Send a message to a running keeper agent. *)
val handle_keeper_msg : _ Keeper_types.context -> Yojson.Safe.t -> tool_result

(** Set the active model for a keeper agent. *)
val handle_keeper_model_set : _ Keeper_types.context -> Yojson.Safe.t -> tool_result

(** Stop a running keeper agent. *)
val handle_keeper_down : _ Keeper_types.context -> Yojson.Safe.t -> tool_result
