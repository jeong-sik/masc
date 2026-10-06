let declared (metadata : Yojson.Safe.t option) : Keeper_tool_outcome.t option =
  match Tool_outcome_declaration.of_metadata metadata with
  | Some Tool_outcome_declaration.Progress -> Some Keeper_tool_outcome.Progress
  | Some Tool_outcome_declaration.No_progress ->
    Some (Keeper_tool_outcome.No_progress { reason = Keeper_tool_outcome.Nothing_changed })
  | None -> None
;;
