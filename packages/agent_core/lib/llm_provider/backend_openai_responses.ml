(** OpenAI Responses API codec.

    Responses is item-based: assistant messages, reasoning summaries, function
    calls, and function-call outputs are all ordered items. Keep this separate
    from the Chat Completions codec so [choices[].message] assumptions cannot
    leak into Responses request/response handling. *)

open Types

type request_artifact = string Request_artifact_internal.t

let request_payload = Request_artifact_internal.payload
let request_output_token_receipt = Request_artifact_internal.output_token_receipt
open Result.Syntax

let json_assoc_opt key = function
  | `Assoc fields -> List.assoc_opt key fields
  | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> None
;;

let opt_bind opt f =
  match opt with
  | Some value -> f value
  | None -> None
;;

let json_string_opt = function
  | `String s -> Some s
  | `Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> None
;;

let json_int_opt = function
  | `Int n -> Some n
  | `Intlit s -> int_of_string_opt s
  | `Float _ | `String _ | `Assoc _ | `List _ | `Bool _ | `Null -> None
;;

let assoc_remove keys fields =
  List.filter (fun (key, _) -> not (List.mem key keys)) fields
;;

let response_phase_metadata_key = "openai.responses.phase"

type response_phase =
  | Commentary
  | Final_answer

let response_phase_to_wire = function
  | Commentary -> "commentary"
  | Final_answer -> "final_answer"
;;

let response_phase_metadata phase =
  response_phase_metadata_key, `String (response_phase_to_wire phase)
;;

let response_phase_of_metadata metadata =
  match List.assoc_opt response_phase_metadata_key metadata with
  | None -> None
  | Some (`String "commentary") -> Some Commentary
  | Some (`String "final_answer") -> Some Final_answer
  | Some (`String raw) ->
    invalid_arg
      (Printf.sprintf
         "Backend_openai_responses.phase: unsupported %s=%S"
         response_phase_metadata_key
         raw)
  | Some (`Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null) ->
    invalid_arg
      (Printf.sprintf
         "Backend_openai_responses.phase: %s must be a string"
         response_phase_metadata_key)
;;

let responses_raw_reasoning_item_of_redacted data =
  try
    match Yojson.Safe.from_string data with
    | `Assoc fields as json ->
      (match List.assoc_opt "type" fields with
       | Some (`String "reasoning") -> Some json
       | Some (`Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null)
       | Some (`String _)
       | None -> None)
    | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> None
  with
  | Yojson.Json_error _ -> None
;;

let message_has_responses_raw_reasoning (msg : message) =
  List.exists
    (function
      | RedactedThinking data ->
        Option.is_some (responses_raw_reasoning_item_of_redacted data)
      | Text _
      | Thinking _
      | ReasoningDetails _
      | ToolUse _
      | ToolResult _
      | Image _
      | Document _
      | Audio _ -> false)
    msg.content
;;

let validate_projected_opaque_reasoning (messages : message list) =
  List.iteri
    (fun message_index (message : message) ->
       List.iteri
         (fun block_index -> function
            | RedactedThinking data
              when Option.is_none (responses_raw_reasoning_item_of_redacted data) ->
              invalid_arg
                (Printf.sprintf
                   "Backend_openai_responses.build_request: malformed opaque reasoning \
                    at history index %d block %d"
                   message_index
                   block_index)
            | RedactedThinking _
            | Text _
            | Thinking _
            | ReasoningDetails _
            | ToolUse _
            | ToolResult _
            | Image _
            | Document _
            | Audio _ -> ())
         message.content)
    messages
;;

let responses_tool_json tool =
  let definition = Backend_openai_serialize.tool_definition_of_json tool in
  `Assoc
    (("type", `String "function")
     :: Backend_openai_serialize.tool_definition_fields definition)
;;

let content_string_of_tool_result ~content ~content_blocks =
  match content_blocks with
  | Some blocks ->
    Yojson.Safe.to_string (`List (List.map Api_common.content_block_to_json blocks))
  | None -> Utf8_sanitize.sanitize content
;;

let input_text_content_part text =
  `Assoc [ "type", `String "input_text"; "text", `String (Utf8_sanitize.sanitize text) ]
;;

let input_image_content_part ~media_type ~source =
  (* The responses surface takes image_url OR file_id on input_image,
     mutually exclusive; the docs' file_id names a Files API upload. Same
     three-carrier mapping as the chat serializer. *)
  match source with
  | Url url ->
    `Assoc [ "type", `String "input_image"; "image_url", `String url ]
  | File_id file_id ->
    `Assoc [ "type", `String "input_image"; "file_id", `String file_id ]
  | Base64 _ ->
    let image_url =
      Api_common.base64_media_data_url
        ~backend:"openai_responses"
        ~block:"image"
        ~media_type
        source
    in
    `Assoc [ "type", `String "input_image"; "image_url", `String image_url ]
;;

let input_content_part_of_block = function
  | Text s -> Some (input_text_content_part s)
  | Image { media_type; source } ->
    Some (input_image_content_part ~media_type ~source)
  | Document { media_type; source } ->
    let file_data =
      Api_common.base64_media_data_url
        ~backend:"openai_responses"
        ~block:"document"
        ~media_type
        source
    in
    Some (`Assoc [ "type", `String "input_file"; "file_data", `String file_data ])
  | Audio { media_type; source } ->
    let data =
      Api_common.base64_media_payload
        ~backend:"openai_responses"
        ~block:"audio"
        source
    in
    Some
      (`Assoc
          [ "type", `String "input_audio"
          ; "input_audio", `Assoc [ "data", `String data; "format", `String media_type ]
          ])
  | Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolUse _ | ToolResult _ ->
    None
;;

let output_text_content_part text =
  `Assoc [ "type", `String "output_text"; "text", `String (Utf8_sanitize.sanitize text) ]
;;

let with_response_phase phase fields =
  match phase with
  | Some phase -> ("phase", `String (response_phase_to_wire phase)) :: fields
  | None -> fields
;;

let message_item ~role content_blocks =
  match List.filter_map input_content_part_of_block content_blocks with
  | [] ->
    let text = Api_common.text_blocks_to_string content_blocks in
    if Api_common.string_is_blank text
    then []
    else
      [ `Assoc [ "role", `String role; "content", `String (Utf8_sanitize.sanitize text) ]
      ]
  | parts -> [ `Assoc [ "role", `String role; "content", `List parts ] ]
;;

let assistant_output_item_of_block ?phase = function
  | Thinking { content; _ } when not (Api_common.string_is_blank content) ->
    Some
      (`Assoc
          [ "type", `String "reasoning"
          ; ( "summary"
            , `List [ `Assoc [ "type", `String "summary_text"; "text", `String content ] ]
            )
          ])
  | ReasoningDetails _ -> None
  | Text s when not (Api_common.string_is_blank s) ->
    Some
      (`Assoc
          (with_response_phase
             phase
             [ "type", `String "message"
             ; "role", `String "assistant"
             ; "content", `List [ output_text_content_part s ]
             ]))
  | RedactedThinking data -> responses_raw_reasoning_item_of_redacted data
  | ToolUse { id; name; input } ->
    Some
      (`Assoc
          [ "type", `String "function_call"
          ; "call_id", `String id
          ; "name", `String name
          ; "arguments", `String (Yojson.Safe.to_string input)
          ])
  | Thinking _ | Text _ | ToolResult _ | Image _ | Document _ | Audio _ -> None
;;

(* Responses function outputs accept an array of input_text/input_image/input_file,
   not the full input-message union (in particular, not input_audio). Project
   images natively and retain other structured blocks as their existing JSON
   text representation. Nested image-bearing results use text boundaries because
   the output union has no native nested tool_result part. Their identity and
   error flag enclose the ordered child parts. The canonical checkpoint stays
   unchanged.
   https://github.com/openai/openai-python/blob/main/src/openai/types/responses/response_function_call_output_item_list_param.py *)
let rec tool_output_has_image = function
  | Image _ -> true
  | ToolResult { content_blocks = Some blocks; _ } ->
    List.exists tool_output_has_image blocks
  | Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolUse _
  | ToolResult { content_blocks = None; _ } | Document _ | Audio _ -> false
;;

let rec tool_output_parts = function
  | Text text -> [ input_text_content_part text ]
  | Image { media_type; source } ->
    [ input_image_content_part ~media_type ~source ]
  | ToolResult { tool_use_id; outcome; content_blocks = Some blocks; _ }
    when List.exists tool_output_has_image blocks ->
    let identity =
      Yojson.Safe.to_string
        (`Assoc [ "tool_use_id", `String tool_use_id
                ; "is_error", `Bool (tool_result_outcome_is_error outcome) ])
    in
    input_text_content_part ("Begin nested tool result " ^ identity)
    :: (List.concat_map tool_output_parts blocks
        @ [ input_text_content_part ("End nested tool result " ^ identity) ])
  | (Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolUse _
    | ToolResult _ | Document _ | Audio _) as block ->
    [ input_text_content_part
        (Yojson.Safe.to_string (Api_common.content_block_to_json block)) ]
;;

let function_call_output_content ~content ~content_blocks =
  match content_blocks with
  | Some blocks when List.exists tool_output_has_image blocks ->
    `List (List.concat_map tool_output_parts blocks)
  | Some _ | None -> `String (content_string_of_tool_result ~content ~content_blocks)
;;

let function_call_output_item ~tool_use_id ~content ~content_blocks =
  `Assoc
    [ "type", `String "function_call_output"
    ; "call_id", `String tool_use_id
    ; "output", function_call_output_content ~content ~content_blocks
    ]
;;

let tool_result_items blocks =
  blocks
  |> List.filter_map (function
    | ToolResult { tool_use_id; content; content_blocks; _ } ->
      Some (function_call_output_item ~tool_use_id ~content ~content_blocks)
    | Text _
    | Thinking _
    | ReasoningDetails _
    | RedactedThinking _
    | ToolUse _
    | Image _
    | Document _
    | Audio _ -> None)
;;

let input_items_of_native_groups content replay =
  let groups =
    match Response_replay.partition ~content replay with
    | Ok groups -> groups
    | Error detail -> invalid_arg detail
  in
  List.concat_map
    (fun (kind, blocks) ->
       match kind with
       | Response_replay.Message phase ->
         let parts = List.map (function
           | Text text -> output_text_content_part text
           | Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolUse _
           | ToolResult _ | Image _ | Document _ | Audio _ ->
             invalid_arg "responses_replay:message_content_kind") blocks in
         [`Assoc (Response_replay.phase_fields phase @
           ["type", `String "message"; "role", `String "assistant"; "content", `List parts])]
       | Response_replay.Reasoning | Response_replay.Function_call ->
         List.filter_map assistant_output_item_of_block blocks)
    groups
;;

let input_items_of_message (msg : message) =
  match msg.role with
  | System -> message_item ~role:"system" msg.content
  | User ->
    let tool_results = tool_result_items msg.content in
    let non_tool_content =
      List.filter
        (function
          | ToolResult _ -> false
          | Text _
          | Thinking _
          | ReasoningDetails _
          | RedactedThinking _
          | ToolUse _
          | Image _
          | Document _
          | Audio _ -> true)
        msg.content
    in
    tool_results @ message_item ~role:"user" non_tool_content
  | Assistant ->
    (match Response_replay.of_metadata ~content:msg.content msg.metadata with
     | Error detail -> invalid_arg detail
     | Ok (Some replay) ->
       if List.mem_assoc response_phase_metadata_key msg.metadata then
         invalid_arg "responses_replay:aggregate_phase_conflict";
       input_items_of_native_groups msg.content replay
     | Ok None ->
       let phase = response_phase_of_metadata msg.metadata in
       List.filter_map (assistant_output_item_of_block ?phase) msg.content)
  | Tool -> tool_result_items msg.content
;;

let tool_choice_to_responses_json = function
  | Auto -> Some (`String "auto")
  | Any -> Some (`String "required")
  | None_ -> Some (`String "none")
  | Tool name -> Some (`Assoc [ "type", `String "function"; "name", `String name ])
;;

let responses_json_schema_payload schema =
  match Backend_openai_request.openai_json_schema_payload schema with
  | `Assoc fields ->
    let schema_fields =
      assoc_remove [ "description" ] fields
      @
      match List.assoc_opt "description" fields with
      | Some (`String _ as description) -> [ "description", description ]
      | Some (`Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null) | None
        -> []
    in
    `Assoc (("type", `String "json_schema") :: schema_fields)
  | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null ->
    `Assoc
      [ "type", `String "json_schema"
      ; "name", `String (Provider_config.structured_output_name_of_schema schema)
      ; "schema", schema
      ; "strict", `Bool true
      ]
;;

let response_text_config_of_config (config : Provider_config.t) =
  match Backend_openai_request.structured_schema_of_config config with
  | Some schema -> Some (`Assoc [ "format", responses_json_schema_payload schema ])
  | None when config.response_format = JsonMode ->
    Some (`Assoc [ "format", `Assoc [ "type", `String "json_object" ] ])
  | None -> None
;;

let capabilities_of_config = Backend_openai_request.capabilities_of_config

(* Output-token budget (clamp WARN included) and sampling-drop policy
   (dialect WARN included) are single-sourced with the Chat Completions
   builder; Responses only renames the budget wire field to
   [max_output_tokens]. *)
let add_sampling_field = Backend_openai_request.add_sampling_field

(* The reasoning blocks this codec puts on the wire, and the ones it
   drops. Separated from [build_request] so a caller that must size a
   request before building it gets the same answer the wire will give;
   the diagnostic [observe] stays at the call site, which keeps this a
   function of its arguments. *)
let project_history ?(tools_present = false) config messages =
  Reasoning_history_projection.project_for_provider_config
    ~tools_present
    ~assistant_has_payload:(fun content -> content <> [])
    ~reasoning_block_supported:(function
      | RedactedThinking _ | Thinking _ -> true
      | ReasoningDetails _
      | Text _
      | ToolUse _
      | ToolResult _
      | Image _
      | Document _
      | Audio _ -> false)
    config
    messages
;;

let build_request_artifact
      ?(stream = false)
      ~(config : Provider_config.t)
      ~(messages : message list)
      ?(tools : Yojson.Safe.t list = [])
      ()
  =
  let tools = Backend_openai_request.effective_tools config tools in
  let projected_messages =
    match project_history ~tools_present:(tools <> []) config messages with
    | Error error ->
      invalid_arg
        ("Backend_openai_responses.build_request: "
         ^ Reasoning_history_projection.error_to_string error)
    | Ok projection ->
      Reasoning_history_projection.observe ~component:"backend_openai_responses" ~stream projection;
      validate_projected_opaque_reasoning projection.messages;
      projection.messages
  in
  let dialect = Reasoning_dialect.for_provider_config config in
  let output_token_receipt =
    Backend_openai_request.output_token_receipt
      ~envelope:Types.Openai_responses_max_output_tokens
      config
  in
  let request_control =
    (match Provider_config.validate_reasoning_effort_request config with
     | Ok () -> ()
     | Error reason ->
       invalid_arg (Printf.sprintf "Backend_openai_responses.reasoning_effort: %s" reason));
    match
      Reasoning_dialect.request_control_fields
        Reasoning_dialect.Responses
        dialect
        ~enable_thinking:config.enable_thinking
        ~preserve_thinking:config.preserve_thinking
        ~reasoning_effort:config.reasoning_effort
        ()
    with
    | Ok artifact -> artifact
    | Error rejection ->
      invalid_arg (Reasoning_dialect.request_control_rejection_to_message rejection)
  in
  let body =
    [ "model", `String config.model_id
    ; "input", `List (List.concat_map input_items_of_message projected_messages)
    ]
  in
  let body =
    match Types.output_token_receipt_effective output_token_receipt with
    | Some mt -> body @ [ "max_output_tokens", `Int mt ]
    | None -> body
  in
  let body =
    match config.previous_response_id with
    | Some id when not (Api_common.string_is_blank id) ->
      ("previous_response_id", `String id) :: body
    | Some _ | None -> body
  in
  let body =
    match config.system_prompt with
    | Some s when not (Api_common.string_is_blank s) ->
      ("instructions", `String (Utf8_sanitize.sanitize s)) :: body
    | Some _ | None -> body
  in
  let body =
    match config.temperature with
    | Some t -> add_sampling_field dialect config Capabilities.Temperature (`Float t) body
    | None -> body
  in
  let body =
    match config.top_p with
    | Some p -> add_sampling_field dialect config Capabilities.Top_p (`Float p) body
    | None -> body
  in
  let body =
    match response_text_config_of_config config with
    | Some text -> ("text", text) :: body
    | None -> body
  in
  let body = request_control.fields @ body in
  let body =
    if
      request_control.fields <> []
      || List.exists message_has_responses_raw_reasoning projected_messages
    then ("include", `List [ `String "reasoning.encrypted_content" ]) :: body
    else body
  in
  let body =
    (* Same emission gate as the Chat builder
       ([Backend_openai_request.should_emit_tool_choice]): advisory [Auto]
       is suppressed when the model does not support tool_choice. Only the
       wire mapping ([tool_choice_to_responses_json]) is Responses-specific. *)
    if Backend_openai_request.should_emit_tool_choice config
    then (
      match config.tool_choice, Backend_openai_request.effective_tool_choice config with
      | Some choice, Some _ ->
        (match tool_choice_to_responses_json choice with
         | Some choice -> ("tool_choice", choice) :: body
         | None -> body)
      | Some _, None | None, _ -> body)
    else body
  in
  let body =
    match tools with
    | [] -> body
    | ts -> ("tools", `List (List.map responses_tool_json ts)) :: body
  in
  let body =
    let tools_present = tools <> [] in
    let caps = capabilities_of_config config in
    let disable_parallel =
      Capabilities.effective_disable_parallel_tool_use
        ~caller_disabled:config.disable_parallel_tool_use
        ~supports_parallel_tool_calls:caps.supports_parallel_tool_calls
        ~tools_present
    in
    Backend_openai_serialize.parallel_tool_calls_fields ~disable_parallel ~tools_present
    @ body
  in
  let body = if stream then ("stream", `Bool true) :: body else body in
  Request_artifact_internal.create
    ~payload:(Yojson.Safe.to_string (`Assoc body))
    ~output_token_receipt
;;

let build_request ?stream ~config ~messages ?tools () =
  build_request_artifact ?stream ~config ~messages ?tools () |> request_payload
;;

let output_text_of_content = function
  | `Assoc fields ->
    (match List.assoc_opt "type" fields, List.assoc_opt "text" fields with
     | Some (`String ("output_text" | "text")), Some (`String text) -> Some text
     | _, _ -> None)
  | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> None
;;

let content_blocks_of_output_message item =
  match json_assoc_opt "content" item with
  | Some (`List content) ->
    content |> List.filter_map output_text_of_content |> List.map (fun text -> Text text)
  | Some (`String text) when not (Api_common.string_is_blank text) -> [ Text text ]
  | Some (`String _)
  | Some (`Assoc _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null)
  | None -> []
;;

let content_blocks_of_reasoning_item item =
  Result.map (function
    | Responses_reasoning.Plaintext channels ->
      (match Responses_reasoning.selected channels with
       | None -> [] | Some(_,content) -> [ Thinking {signature=None;content} ])
    | Opaque item -> [ RedactedThinking (Yojson.Safe.to_string item) ])
    (Responses_reasoning.decode item)
;;

let content_block_of_function_call item =
  let* {Responses_function_call.call_id;name;input;arguments=_} =
    Responses_function_call.decode item in
  Ok (ToolUse { id = call_id; name; input })
;;

let content_blocks_of_output_item ~drop_function_call item =
  match opt_bind (json_assoc_opt "type" item) json_string_opt with
  | Some "message" -> Ok (content_blocks_of_output_message item)
  | Some "reasoning" -> content_blocks_of_reasoning_item item
  | Some "function_call" when drop_function_call -> Ok []
  | Some "function_call" ->
    let* block = content_block_of_function_call item in
    Ok [ block ]
  | Some _ ->
    (* Responses output items are an extensible set. Hosted-tool items such as
       web-search calls are valid non-content for this parser; preserve later
       message/reasoning/function_call items instead of failing the whole
       response because OpenAI added a new output item type. Malformed
       supported items (notably function_call) still fail closed above. *)
    Ok []
  | None -> Error "malformed_responses_output_item:missing_type"
;;

let content_and_replay_of_output ~drop_function_call output =
  let rec loop content_rev groups_rev = function
    | [] ->
      let content = List.rev content_rev |> List.concat in
      let* replay = Response_replay.make ~content (List.rev groups_rev) in
      Ok (content, replay)
    | item :: rest ->
      let* blocks = content_blocks_of_output_item ~drop_function_call item in
      let* kind = match opt_bind (json_assoc_opt "type" item) json_string_opt with
        | Some "message" ->
          let fields = match item with `Assoc fields -> fields | _ -> [] in
          Result.map (fun phase -> Some (Response_replay.Message phase))
            (Response_replay.phase_of_fields fields)
        | Some "reasoning" -> Ok (Some Response_replay.Reasoning)
        | Some "function_call" -> Ok (Some Response_replay.Function_call)
        | Some _ | None -> Ok None in
      let groups_rev = match kind, blocks with
        | Some (Response_replay.Message _ as kind), _
        | Some kind, (_ :: _) -> {Response_replay.kind; content_count=List.length blocks} :: groups_rev
        | Some (Reasoning | Function_call), [] | None, _ -> groups_rev in
      loop (blocks :: content_rev) groups_rev rest
  in
  loop [] [] output
;;

let usage_of_response_json json =
  match json_assoc_opt "usage" json with
  | Some (`Assoc fields) ->
    let member_int key = opt_bind (List.assoc_opt key fields) json_int_opt in
    let input_tokens = member_int "input_tokens" |> Option.value ~default:0 in
    let output_tokens = member_int "output_tokens" |> Option.value ~default:0 in
    let cached_tokens =
      match List.assoc_opt "input_tokens_details" fields with
      | Some (`Assoc detail_fields) ->
        opt_bind (List.assoc_opt "cached_tokens" detail_fields) json_int_opt
        |> Option.value ~default:0
      | Some (`List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null)
      | None -> 0
    in
    Some
      { input_tokens
      ; output_tokens
      ; cache_creation_input_tokens = 0
      ; cache_read_input_tokens = cached_tokens
      ; cost_usd = None
      }
  | Some (`List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null) | None ->
    None
;;

let telemetry_of_response_json json =
  match json_assoc_opt "usage" json with
  | Some (`Assoc fields) ->
    let reasoning_tokens =
      match List.assoc_opt "output_tokens_details" fields with
      | Some (`Assoc detail_fields) ->
        opt_bind (List.assoc_opt "reasoning_tokens" detail_fields) json_int_opt
      | Some (`List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null)
      | None -> None
    in
    Some { Types.default_inference_telemetry with reasoning_tokens }
  | Some (`List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null) | None ->
    None
;;

let response_status json = opt_bind (json_assoc_opt "status" json) json_string_opt

let response_incomplete_reason json =
  match json_assoc_opt "incomplete_details" json with
  | Some details -> opt_bind (json_assoc_opt "reason" details) json_string_opt
  | None -> None
;;

let response_failed_message json =
  match json_assoc_opt "error" json with
  | Some error -> opt_bind (json_assoc_opt "message" error) json_string_opt
  | None -> None
;;

let stop_reason_of_response_json ~has_tool_calls json =
  match
    Responses_stop_reason.of_status
      ~status:(response_status json)
      ~incomplete_reason:(response_incomplete_reason json)
      ~failed_message:(response_failed_message json)
      ~has_tool_calls
  with
  | Some stop_reason ->
    Ok (Stop_reason_wire.with_refusal
          ~has_refusal:(Responses_stop_reason.has_refusal json) stop_reason)
  | None -> Error "malformed_openai_responses:missing_status"
;;

let parse_response_result json_str =
  try
    let json = Yojson.Safe.from_string json_str in
    match json_assoc_opt "error" json with
    | Some (`Assoc fields) ->
      let message =
        opt_bind (List.assoc_opt "message" fields) json_string_opt
        |> Option.value ~default:"Unknown API error"
      in
      Error message
    | Some (`String message) -> Error message
    | Some (`List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null) | None ->
      let output =
        match json_assoc_opt "output" json with
        | Some (`List items) -> items
        | Some (`Assoc _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null)
        | None -> []
      in
      (* Terminal [incomplete]/[failed] responses may carry a partial [function_call]
         item; do not expose it as a dangling ToolUse that the pipeline would try to
         execute or repair. Drop such blocks so the stop reason dominates. *)
      let status =
        opt_bind (json_assoc_opt "status" json) json_string_opt
        |> Option.value ~default:""
      in
      let drop_function_call =
        match String.lowercase_ascii status with
        | "incomplete" | "failed" -> true
        | _ -> false
      in
      let* content, replay = content_and_replay_of_output ~drop_function_call output in
      let has_tool_calls =
        List.exists
          (function
            | ToolUse _ -> true
            | Text _
            | Thinking _
            | ReasoningDetails _
            | RedactedThinking _
            | ToolResult _
            | Image _
            | Document _
            | Audio _ -> false)
          content
      in
      let* stop_reason = stop_reason_of_response_json ~has_tool_calls json in
      let model = opt_bind (json_assoc_opt "model" json) json_string_opt |> Option.value ~default:"" in
      Ok
        { id =
            opt_bind (json_assoc_opt "id" json) json_string_opt
            |> Option.value ~default:""
        ; model
        ; stop_reason
        ; content
        ; usage = usage_of_response_json json
        ; telemetry = Some
            { (Types.with_reported_model ~model
                 (telemetry_of_response_json json)) with response_replay = Some replay }
        }
  with
  | Yojson.Json_error msg -> Error ("JSON parse error: " ^ msg)
;;
