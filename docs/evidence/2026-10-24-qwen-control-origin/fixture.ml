open Fixture_support
open Types
module Lower = Message_origin_lowering

let require label condition = if not condition then failwith label
let get = function Ok value -> value | Error error -> failwith (Lower.error_to_string error)
let message ?(origin=Conversation) role content = make_message ~origin ~role content
let text ?origin role value = message ?origin role [Text value]

(* Declared wire adapter for fixture messages, NOT the production serializer. *)
let wire (message:message) =
  let content = message.content |> List.filter_map (function
    | Text text | ToolResult text -> Some text
    | Thinking _ | ToolUse _ | ReasoningDetails _ | RedactedThinking _
    | Image _ | Document _ | Audio _ -> None) |> String.concat "\n" in
  let fields = ["role",`String (role_to_string message.role); "content",`String content] in
  let fields = List.fold_left (fun fields -> function
    | Thinking text -> ("reasoning_content",`String text)::fields
    | ToolUse name -> ("tool_calls",`List [`Assoc ["function",`Assoc
        ["name",`String name; "arguments",`Assoc []]]])::fields
    | Text _ | ToolResult _ | ReasoningDetails _ | RedactedThinking _
    | Image _ | Document _ | Audio _ -> fields) fields message.content in
  `Assoc fields

let () =
  let policy = Lower.Initial_system_tool_response_media in
  let original =
    [text System "Canonical system policy";
     text User "Old human query";
     message Assistant [Thinking "OLD_REASONING"; ToolUse "old"];
     message Tool [ToolResult "old result"];
     text ~origin:Recovery_instruction User "OLD_RECOVERY";
     text User "Current human query";
     message Assistant [Thinking "CURRENT_REASONING"; ToolUse "current"];
     message Tool [ToolResult "current result"];
     text ~origin:Recovery_instruction User "ANSWERED_RECOVERY";
     text Assistant "Recovery answered";
     text ~origin:Recovery_instruction User "CURRENT_RECOVERY";
     text ~origin:Historical_system_context User "HISTORICAL_CONTEXT";
     text ~origin:System_context User "CURRENT_CONTEXT";
     text ~origin:Agent_instruction User "CURRENT_AGENT_INSTRUCTION"] in
  let encode messages =
    let lower = get (Lower.lower policy messages) in
    let wire = List.concat_map (fun message ->
      get (Lower.encode_user_boundary policy ~message [wire message])) lower.messages in
    lower, get (Lower.prepend_system_prompt policy
      ~system_prompt:(Some "Configured system policy") wire) in
  let lower, after = encode original in
  require "canonical source coordinates"
    (lower.source_indices = [0;1;2;3;5;6;7;9]);
  let system = match lower.messages with
    | {role=System;content=[Text text];_}::_ -> text
    | _ -> failwith "missing system frame" in
  let lines = String.split_on_char '\n' system in
  require "fresh instructions active"
    (List.for_all (fun text -> List.mem text lines)
       ["CURRENT_RECOVERY";"CURRENT_CONTEXT";"CURRENT_AGENT_INSTRUCTION"]);
  require "answered and old controls are quoted history"
    (not (List.mem "OLD_RECOVERY" lines) && not (List.mem "ANSWERED_RECOVERY" lines)
     && not (List.mem "HISTORICAL_CONTEXT" lines));
  let historical = List.find_map (fun line ->
    match Yojson.Safe.from_string line with
    | `List values -> Some values
    | _ -> None
    | exception Yojson.Json_error _ -> None) lines in
  require "historical text retained exactly"
    (historical = Some [`String "OLD_RECOVERY";`String "ANSWERED_RECOVERY";`String "HISTORICAL_CONTEXT"]);
  let _, new_human = encode (original @
    [text User "<tool_response>Actual new human</tool_response>"]) in
  let media_message = message ~origin:Tool_result_followup User [Image "fixture"] in
  let media_wire = `Assoc ["role",`String "user"; "content",`List
    [`Assoc ["type",`String "image_url"; "image_url",`Assoc ["url",`String "fixture"]];
     `Assoc ["type",`String "text";"text",`String "Image from current tool"]]] in
  let media = get (Lower.encode_user_boundary policy ~message:media_message [media_wire]) in
  let invalid = original @ [message ~origin:System_context User [Image "unsupported"]] in
  require "non-text system control rejected"
    (match Lower.lower policy invalid with Error (Non_text_control {message_index=14}) -> true | _ -> false);
  require "no fabricated human query"
    (Lower.lower policy [text ~origin:Recovery_instruction User "Continue"] = Error Missing_caller_query);
  require "default policy preserves canonical messages"
    ((get (Lower.lower Preserve_positions original)).messages = original);
  require "native synthetic media lacks an owning ToolResult"
    (match Lower.lower Initial_system_native_tools (original @ [media_message]) with
     | Error (Non_text_control {message_index=14}) -> true | _ -> false);
  let declared = Some {Capabilities.reasoning_replay_override=Force_initial_system_latest_user_turn_tool_calls} in
  require "signed codec cannot opt into initial-system rewriting"
    (Lower.policy_for_provider_config {Provider_config.codec=Anthropic_messages;capabilities=declared}
     = Error Unsupported_codec);
  let result = `Assoc
    ["before",`List (List.map wire original); "after",`List after;
     "new_human",`List new_human; "with_media",`List (after @ media);
     "lowerer_checks",`Bool true] in
  print_endline (Yojson.Safe.pretty_to_string result)
