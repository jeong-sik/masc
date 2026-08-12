let schema = "masc.official-client-context-message.v2"

let media_source_to_json ~media_type ~data ~source_type =
  `Assoc
    [ "type", `String (Agent_core.Types.media_source_kind_to_string source_type)
    ; "media_type", `String media_type
    ; "data", `String data
    ]
;;

let rec content_block_to_json = function
  | Agent_core.Types.Text text ->
    `Assoc [ "type", `String "text"; "text", `String text ]
  | Thinking { content; signature } ->
    `Assoc
      ([ "type", `String "thinking"; "thinking", `String content ]
       @
       match signature with
       | None -> []
       | Some value -> [ "signature", `String value ])
  | ReasoningDetails { reasoning_content; details } ->
    `Assoc
      ([ ( "details"
         , `List
             (List.map
                (fun (detail : Agent_core.Types.reasoning_detail) -> detail.raw)
                details) )
       ; "type", `String "reasoning_details"
       ]
       @
       match reasoning_content with
       | None -> []
       | Some value -> [ "reasoning_content", `String value ])
  | RedactedThinking data ->
    `Assoc [ "type", `String "redacted_thinking"; "data", `String data ]
  | ToolUse { id; name; input } ->
    `Assoc
      [ "type", `String "tool_use"
      ; "id", `String id
      ; "name", `String name
      ; "input", input
      ]
  | ToolResult { tool_use_id; content; outcome; json; content_blocks } ->
    let content =
      match content_blocks with
      | None -> `String content
      | Some blocks -> `List (List.map content_block_to_json blocks)
    in
    let structured_content =
      match json with
      | None -> []
      | Some value -> [ "structured_content", value ]
    in
    let failure =
      match outcome with
      | Agent_core.Types.Tool_succeeded -> []
      | Tool_failed { failure_kind; error_class } ->
        [ "failure_kind", Agent_core.Types.tool_failure_kind_to_yojson failure_kind ]
        @ (match error_class with
           | None -> []
           | Some value ->
             [ "error_class", Agent_core.Types.tool_error_class_to_yojson value ])
    in
    `Assoc
      ([ "type", `String "tool_result"
       ; "tool_use_id", `String tool_use_id
       ; "content", content
       ; "is_error", `Bool (Agent_core.Types.tool_result_outcome_is_error outcome)
       ]
       @ structured_content
       @ failure)
  | Image { media_type; data; source_type } ->
    `Assoc
      [ "type", `String "image"
      ; "source", media_source_to_json ~media_type ~data ~source_type
      ]
  | Document { media_type; data; source_type } ->
    `Assoc
      [ "type", `String "document"
      ; "source", media_source_to_json ~media_type ~data ~source_type
      ]
  | Audio { media_type; data; source_type } ->
    `Assoc
      [ "type", `String "audio"
      ; "source", media_source_to_json ~media_type ~data ~source_type
      ]
;;

let message_to_json (message : Agent_core.Types.message) =
  `Assoc
    [ "role", `String (Agent_core.Types.role_to_string message.role)
    ; "content_blocks", `List (List.map content_block_to_json message.content)
    ; ( "name"
      , Option.fold ~none:`Null ~some:(fun value -> `String value) message.name )
    ; ( "tool_call_id"
      , Option.fold ~none:`Null ~some:(fun value -> `String value) message.tool_call_id )
    ; "metadata", `Assoc message.metadata
    ]
;;

let to_json message =
  `Assoc [ "schema", `String schema; "message", message_to_json message ]
;;

let encode message = to_json message |> Yojson.Safe.to_string
