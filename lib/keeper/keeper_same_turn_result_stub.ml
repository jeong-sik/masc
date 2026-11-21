module Types = Agent_core.Types
module String_map = Map.Make (String)

let encode ~first_tool_use_id ~bytes ~sha256 =
  Printf.sprintf
    "[masc:same-result first_tool_use_id=%S bytes=%d sha256=%s]"
    first_tool_use_id
    bytes
    sha256
;;

let is_user = function
  | Types.User -> true
  | Types.System | Types.Assistant | Types.Tool -> false
;;

let is_conversation = function
  | Types.Conversation -> true
  | Types.System_context
  | Types.Historical_system_context
  | Types.Recovery_instruction
  | Types.Tool_result_followup
  | Types.Agent_instruction
  | Types.Outside_context -> false
;;

let starts_turn (message : Types.message) =
  is_user message.role && is_conversation message.origin
;;

let is_media : Types.content_block -> bool = function
  | Types.Image _ | Types.Document _ | Types.Audio _ -> true
  | Types.Text _
  | Types.Thinking _
  | Types.ReasoningDetails _
  | Types.RedactedThinking _
  | Types.ToolUse _
  | Types.ToolResult _ -> false
;;

(* The tool each call id names, from the ToolUse blocks seen so far. An id a
   later cycle reuses names the later call. *)
let record_tool_names names (message : Types.message) =
  List.fold_left
    (fun names (block : Types.content_block) ->
       match block with
       | Types.ToolUse { id; name; input = _ } -> String_map.add id name names
       | Types.Text _
       | Types.Thinking _
       | Types.ReasoningDetails _
       | Types.RedactedThinking _
       | Types.ToolResult _
       | Types.Image _
       | Types.Document _
       | Types.Audio _ -> names)
    names
    message.content
;;

(* [first] maps the sha256 of a result's text to the tool_use_id of the
   turn's first result with that text. *)
let stub_block ~enabled ~min_bytes ~names ~first (block : Types.content_block) =
  match block with
  | Types.ToolResult { tool_use_id; content; outcome; json = _; content_blocks = None } ->
    let tool_is_on =
      match String_map.find_opt tool_use_id names with
      | None -> false
      | Some name -> enabled name
    in
    let bytes = String.length content in
    if (not tool_is_on) || bytes < min_bytes
    then first, None
    else (
      let sha256 = Agent_core_sha256.(digest_string content |> to_hex) in
      match String_map.find_opt sha256 first with
      | None -> String_map.add sha256 tool_use_id first, None
      | Some first_tool_use_id ->
        let stub = encode ~first_tool_use_id ~bytes ~sha256 in
        if String.length stub < bytes
        then
          ( first
          , Some
              (Types.ToolResult
                 { tool_use_id; content = stub; outcome; json = None; content_blocks = None })
          )
        else first, None)
  | Types.ToolResult
      { tool_use_id = _; content = _; outcome = _; json = _; content_blocks = Some _ }
  | Types.Text _
  | Types.Thinking _
  | Types.ReasoningDetails _
  | Types.RedactedThinking _
  | Types.ToolUse _
  | Types.Image _
  | Types.Document _
  | Types.Audio _ -> first, None
;;

let stub_message ~enabled ~min_bytes ~names ~first (message : Types.message) =
  if List.exists is_media message.content
  then first, None
  else (
    let (first, changed), content =
      List.fold_left_map
        (fun (first, changed) block ->
           match stub_block ~enabled ~min_bytes ~names ~first block with
           | first, None -> (first, changed), block
           | first, Some stub -> (first, true), stub)
        (first, false)
        message.content
    in
    first, if changed then Some { message with content } else None)
;;

let apply ~enabled ~min_bytes messages =
  let (_names, _first, changed), stubbed =
    List.fold_left_map
      (fun (names, first, changed) (message : Types.message) ->
         let first = if starts_turn message then String_map.empty else first in
         let names = record_tool_names names message in
         match stub_message ~enabled ~min_bytes ~names ~first message with
         | first, None -> (names, first, changed), message
         | first, Some message -> (names, first, true), message)
      (String_map.empty, String_map.empty, false)
      messages
  in
  if changed then stubbed else messages
;;
