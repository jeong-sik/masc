(** Keeper_tool_response - provider response acceptance and keeper reply text
    normalization. *)

let normalize_response_text ~(text : string) ~(tool_names : string list) ()
  : (string, string) result
  =
  let trimmed = String.trim text in
  if trimmed <> ""
  then Ok text
  else (
    match tool_names with
    | [] -> Error "keeper turn completed with no textual reply"
    | _ ->
      Ok
        (Printf.sprintf
           "Completed without a textual reply. Tools used: %s."
           (String.concat ", " tool_names)))
;;

let response_has_text_or_tool_progress (response : Agent_sdk.Types.api_response) =
  let text = Agent_sdk.Types.text_of_content response.content |> String.trim in
  text <> ""
  || List.exists
       (function
         | Agent_sdk.Types.ToolUse _ -> true
         | Agent_sdk.Types.Text _
         | Agent_sdk.Types.Thinking _
         | Agent_sdk.Types.RedactedThinking _
         | Agent_sdk.Types.ToolResult _
         | Agent_sdk.Types.Image _
         | Agent_sdk.Types.Document _
         | Agent_sdk.Types.Audio _ -> false)
       response.content
  || response.stop_reason <> Agent_sdk.Types.EndTurn
;;
