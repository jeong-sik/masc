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

let response_accept_rejection_reason (response : Agent_sdk.Types.api_response) =
  if response_has_text_or_tool_progress response
  then None
  else (
    let has_thinking =
      List.exists
        (function
          | Agent_sdk.Types.Thinking _ | Agent_sdk.Types.RedactedThinking _ -> true
          | _ -> false)
        response.content
    in
    let has_blank_text =
      List.exists
        (function
          | Agent_sdk.Types.Text text -> String.trim text = ""
          | _ -> false)
        response.content
    in
    let has_tool_result =
      List.exists
        (function
          | Agent_sdk.Types.ToolResult _ -> true
          | _ -> false)
        response.content
    in
    Some
      (match response.content with
       | [] -> "empty_end_turn"
       | _ when has_thinking -> "thinking_only"
       | _ when has_blank_text -> "blank_text"
       | _ when has_tool_result -> "tool_result_only"
       | _ -> "no_visible_progress"))
;;
