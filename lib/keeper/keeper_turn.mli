(** Keeper_turn — keeper lifecycle and message-turn handlers.

    Provides MCP tool handlers for keeper agent management:
    start/stop and message dispatch.
    Internal helpers (team session dispatch, planner/executor spawn,
    JSON serialization) are hidden.
*)

(** Tool handler return type: (success, message). *)
type tool_result = Keeper_types.tool_result

(** Start or reconfigure a keeper agent. *)
val handle_keeper_up : _ Keeper_types.context -> Yojson.Safe.t -> tool_result

(** Send a message to a running keeper agent.

    When [on_text_delta] is provided, the initial MODEL call uses streaming
    and forwards text deltas through the callback in real time. Follow-up
    calls (tool loops, corrections, prompt fallback) run in batch mode.
    If streaming fails, the function falls back to batch automatically.

    @since 2.110.0 *)
val preflight_keeper_msg :
  _ Keeper_types.context -> Yojson.Safe.t -> (unit, string) result
(** Run synchronous validation for [handle_keeper_msg] before an async wrapper
    accepts the turn for later execution. *)

val handle_keeper_msg :
  ?on_text_delta:(string -> unit) ->
  _ Keeper_types.context -> Yojson.Safe.t -> tool_result

(** Stop a running keeper agent. *)
val handle_keeper_down : _ Keeper_types.context -> Yojson.Safe.t -> tool_result
