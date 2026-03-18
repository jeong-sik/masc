(** Keeper_feedback_tool — MCP tool handler for human feedback on deliberation decisions.

    Accepts [keeper_name], [decision_id], [score] (-1.0 to 1.0), and optional [comment]. *)

val handle_keeper_feedback_record :
  _ Keeper_types.context -> Yojson.Safe.t -> Keeper_types.tool_result
(** Handle the keeper feedback record tool call.
    Validates inputs, verifies the decision exists, and persists the feedback. *)
