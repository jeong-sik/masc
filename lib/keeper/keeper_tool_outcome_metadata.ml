let declared (metadata : Yojson.Safe.t option) : Keeper_tool_outcome.t option =
  match Tool_outcome_declaration.of_metadata metadata with
  | Some Tool_outcome_declaration.Progress -> Some Keeper_tool_outcome.Progress
  | None -> None
;;
