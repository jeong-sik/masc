(** Keeper_turn_up — keeper start/reconfigure handler.

    Orchestrates the [masc_keeper_up] tool by delegating to
    [Keeper_turn_up_args] (parse/validate), [Keeper_turn_up_create]
    (new keeper), and [Keeper_turn_up_update] (existing keeper). *)

type tool_result = Keeper_types.tool_result

(** Handle the [masc_keeper_up] MCP tool call: parse args, look up the
    existing keeper meta, and dispatch to create or update. *)
val handle_keeper_up :
  _ Keeper_types.context -> Yojson.Safe.t -> tool_result
