(** Keeper_turn_lifecycle — keeper shutdown handlers.

    Extracted from keeper_turn.ml. *)

type tool_result = Keeper_types.tool_result

(** Handle the [masc_keeper_down] MCP tool call: stop keepalive,
    optionally remove meta and/or session directory, broadcast
    Operator_pause to the registry. *)
val handle_keeper_down :
  _ Keeper_types.context -> Yojson.Safe.t -> tool_result
