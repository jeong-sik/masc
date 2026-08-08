(** OpenAI-compatible request serialization.

    Converts agent_sdk Types (content blocks, messages, tools) into
    Openai Chat Completions API JSON format.

    @since 0.92.0 extracted from Backend_openai *)

open Types

(* oas#2483 — chat-template thinking-token injection (SSOT for both backends).

   The chat-template thinking token is pure system-prompt content, not a
   provider-native request field. Ollama and the OpenAI-compat wire both build
   their system message from [config.system_prompt], so the token is injected
   here once. Before this was shared, [backend_ollama] injected the token while
   the OpenAI-compat request builder silently dropped it: the same catalog row
   toggled thinking on Ollama but not on the OpenAI-compat wire, so the model
   could return a blank-content 200 that parsed as an empty turn (the empty-turn
   storm downstream). Keeping the injection in one place stops the two backends
   from diverging again. *)
let with_chat_template_thinking_token ~token = function
  | Some prompt when not (Api_common.string_is_blank prompt) ->
    let trimmed = String.trim prompt in
    if String.starts_with ~prefix:token trimmed then trimmed else token ^ "\n" ^ trimmed
  | _ -> token
;;

(* Resolve explicit request intent without reading backend-specific environment
   state.  Each backend supplies its own default at the call site. *)
let thinking_requested ~default (config : Provider_config.t) =
  match config.enable_thinking with
  | Some true -> true
  | Some false -> false
  | None -> default
;;

let%test "explicit thinking flag wins the backend default" =
  let disabled =
    Provider_config.make
      ~kind:Provider_config.Ollama
      ~model_id:"m"
      ~base_url:"u"
      ~enable_thinking:false
      ()
  in
  let enabled = { disabled with enable_thinking = Some true } in
  (not (thinking_requested ~default:true disabled))
  && thinking_requested ~default:false enabled
;;

let%test "absent thinking flag uses only the caller default" =
  let config =
    Provider_config.make ~kind:Provider_config.Ollama ~model_id:"m" ~base_url:"u" ()
  in
  thinking_requested ~default:true config
  && not (thinking_requested ~default:false config)
;;

(* [true] when the resolved capabilities declare a [Chat_template_token] and
   thinking is requested — i.e. the token must be injected into the system turn.
   Ollama also uses this to omit the native [think] field for these rows. *)
let chat_template_thinking_active ~thinking_requested ~(caps : Capabilities.capabilities) =
  thinking_requested
  && Option.is_some
       (Capability_vocab.token_of_thinking_control_format caps.thinking_control_format)
;;

(* [config.system_prompt] with the chat-template thinking token prepended when
   [chat_template_thinking_active]; otherwise unchanged. When there is no prior
   system prompt the token becomes the system turn on its own. *)
let system_prompt_with_thinking_token
      ~thinking_requested
      ~(config : Provider_config.t)
      ~(caps : Capabilities.capabilities)
  =
  match
    Capability_vocab.token_of_thinking_control_format caps.thinking_control_format
  with
  | Some token when thinking_requested ->
    Some (with_chat_template_thinking_token ~token config.system_prompt)
  | Some _ | None -> config.system_prompt
;;

let%test
    "oas#2483: Chat_template_token + enable_thinking injects the token on the \
     OpenAI-compat side"
  =
  let caps =
    { Capabilities.ollama_capabilities with
      thinking_control_format = Capabilities.Chat_template_token "<THINK>"
    }
  in
  let config =
    Provider_config.make
      ~kind:Provider_config.OpenAI_compat
      ~model_id:"m"
      ~base_url:"u"
      ~system_prompt:"Base prompt."
      ~enable_thinking:true
      ~model_capabilities_override:caps
      ()
  in
  match system_prompt_with_thinking_token ~thinking_requested:true ~config ~caps with
  | Some s -> String.starts_with ~prefix:"<THINK>" s
  | None -> false
;;

let%test "oas#2483: a non-token model leaves the system prompt byte-identical" =
  let config =
    Provider_config.make
      ~kind:Provider_config.OpenAI_compat
      ~model_id:"m"
      ~base_url:"u"
      ~system_prompt:"Base prompt."
      ~enable_thinking:true
      ()
  in
  (* Ollama_think is not a token format, so no injection. *)
  system_prompt_with_thinking_token
    ~thinking_requested:true
    ~config
    ~caps:Capabilities.ollama_capabilities
  = Some "Base prompt."
;;

let%test "oas#2483: enable_thinking=false does not inject the token" =
  let caps =
    { Capabilities.ollama_capabilities with
      thinking_control_format = Capabilities.Chat_template_token "<THINK>"
    }
  in
  let config =
    Provider_config.make
      ~kind:Provider_config.OpenAI_compat
      ~model_id:"m"
      ~base_url:"u"
      ~system_prompt:"Base prompt."
      ~enable_thinking:false
      ~model_capabilities_override:caps
      ()
  in
  system_prompt_with_thinking_token ~thinking_requested:false ~config ~caps
  = Some "Base prompt."
;;

let%test "oas#2488 follow-up: OpenAI-compatible default stays provider-local" =
  let caps =
    { Capabilities.ollama_capabilities with
      thinking_control_format = Capabilities.Chat_template_token "<THINK>"
    }
  in
  let config =
    Provider_config.make
      ~kind:Provider_config.OpenAI_compat
      ~model_id:"m"
      ~base_url:"u"
      ~system_prompt:"Base prompt."
      ~model_capabilities_override:caps
      ()
  in
  let requested = thinking_requested ~default:false config in
  system_prompt_with_thinking_token ~thinking_requested:requested ~config ~caps
  = Some "Base prompt."
;;

let tool_calls_to_openai_json blocks =
  blocks
  |> List.filter_map (function
    | ToolUse { id; name; input } ->
      Some
        (`Assoc
            [ "id", `String id
            ; "type", `String "function"
            ; ( "function"
              , `Assoc
                  [ "name", `String name
                  ; "arguments", `String (Yojson.Safe.to_string input)
                  ] )
            ])
    | Text _
    | Thinking _
    | ReasoningDetails _
    | RedactedThinking _
    | ToolResult _
    | Image _
    | Document _
    | Audio _ -> None)
;;

(** Ollama variant: arguments as raw JSON object, not string.
    Ollama's yyjson parser treats a stringified object as literal text
    and fails with "can't find closing '}' symbol" on subsequent turns. *)
let tool_calls_to_ollama_json blocks =
  blocks
  |> List.filter_map (function
    | ToolUse { id; name; input } ->
      Some
        (`Assoc
            [ "id", `String id
            ; "type", `String "function"
            ; "function", `Assoc [ "name", `String name; "arguments", input ]
            ])
    | Text _
    | Thinking _
    | ReasoningDetails _
    | RedactedThinking _
    | ToolResult _
    | Image _
    | Document _
    | Audio _ -> None)
;;

let openai_content_parts_of_blocks blocks =
  blocks
  |> List.filter_map (function
    | Text s ->
      Some (`Assoc [ "type", `String "text"; "text", `String (Utf8_sanitize.sanitize s) ])
    | Image { media_type; data; source_type } ->
      let url =
        Api_common.base64_media_data_url
          ~backend:"openai_chat"
          ~block:"image"
          ~media_type
          ~data
          source_type
      in
      Some
        (`Assoc
            [ "type", `String "image_url"; "image_url", `Assoc [ "url", `String url ] ])
    | Document { media_type; data; source_type } ->
      (* oas#2744 — a document is not an image. This arm used to emit an
         [image_url] part, so a PDF reached the model as a picture and no layer
         reported the substitution. Chat Completions carries a document in its
         own [file] part; the payload is the same base64 data URL the sibling
         Responses serializer puts in [input_file.file_data], and like that
         serializer no [filename] is sent because a [Document] block carries no
         name. Rows that cannot carry a document are stopped earlier by
         [Api_common.admit_document_blocks], so there is one native form here
         and no fallback. *)
      let file_data =
        Api_common.base64_media_data_url
          ~backend:"openai_chat"
          ~block:"document"
          ~media_type
          ~data
          source_type
      in
      Some
        (`Assoc
            [ "type", `String "file"; "file", `Assoc [ "file_data", `String file_data ] ])
    | Audio { media_type; data; source_type } ->
      let data =
        Api_common.base64_media_payload
          ~backend:"openai_chat"
          ~block:"audio"
          ~data
          source_type
      in
      Some
        (`Assoc
            [ "type", `String "input_audio"
            ; "input_audio", `Assoc [ "data", `String data; "format", `String media_type ]
            ])
    | Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolUse _ | ToolResult _ ->
      None)
;;

let assistant_text_content_of_blocks blocks =
  blocks
  |> List.filter_map (function
    | Text s -> Some (Utf8_sanitize.sanitize s)
    | Thinking _
    | ReasoningDetails _
    | RedactedThinking _
    | ToolUse _
    | ToolResult _
    | Image _
    | Document _
    | Audio _ -> None)
  |> String.concat "\n"
;;

let assistant_reasoning_content_of_blocks blocks =
  blocks
  |> List.filter_map (function
    | Thinking { content; _ } when not (Api_common.string_is_blank content) ->
      Some (Utf8_sanitize.sanitize content)
    | Thinking _ -> None
    | ReasoningDetails { reasoning_content; details } ->
      let text = reasoning_details_text ~reasoning_content ~details in
      if Api_common.string_is_blank text then None else Some (Utf8_sanitize.sanitize text)
    | Text _
    | RedactedThinking _
    | ToolUse _
    | ToolResult _
    | Image _
    | Document _
    | Audio _ -> None)
  |> String.concat ""
;;

let assistant_reasoning_details_of_blocks blocks =
  let details =
    blocks
    |> List.concat_map (function
      | ReasoningDetails { details; _ } ->
        List.map (fun (detail : reasoning_detail) -> detail.raw) details
      | Text _
      | Thinking _
      | RedactedThinking _
      | ToolUse _
      | ToolResult _
      | Image _
      | Document _
      | Audio _ -> [])
  in
  match details with
  | [] -> None
  | _ :: _ -> Some details
;;

let tool_result_content_string ~content ~content_blocks =
  match content_blocks with
  | Some blocks ->
    (* Both OpenAI and Ollama tool messages accept scalar string content.
       Preserve structured canonical results as a JSON string rather than
       dropping their blocks at either wire boundary. *)
    Yojson.Safe.to_string (`List (List.map Api_common.content_block_to_json blocks))
  | None -> Utf8_sanitize.sanitize content
;;

let openai_tool_message_of_result ~tool_use_id ~content ~content_blocks =
  let content_str = tool_result_content_string ~content ~content_blocks in
  `Assoc
    [ "role", `String "tool"
    ; "tool_call_id", `String tool_use_id
    ; "content", `String content_str
    ]
;;

let openai_tool_messages_of_blocks blocks =
  blocks
  |> List.filter_map (function
    | ToolResult { tool_use_id; content; content_blocks; _ } ->
      Some (openai_tool_message_of_result ~tool_use_id ~content ~content_blocks)
    | Text _
    | Thinking _
    | ReasoningDetails _
    | RedactedThinking _
    | ToolUse _
    | Image _
    | Document _
    | Audio _ -> None)
;;

let validate_tool_result_role (msg : message) =
  let has_tool_result =
    List.exists
      (function
        | ToolResult _ -> true
        | Text _
        | Thinking _
        | ReasoningDetails _
        | RedactedThinking _
        | ToolUse _
        | Image _
        | Document _
        | Audio _ -> false)
      msg.content
  in
  match msg.role, has_tool_result, msg.content with
  | Tool, true, content
    when List.for_all
           (function
             | ToolResult _ -> true
             | Text _
             | Thinking _
             | ReasoningDetails _
             | RedactedThinking _
             | ToolUse _
             | Image _
             | Document _
             | Audio _ -> false)
           content -> ()
  | Tool, _, _ ->
    invalid_arg
      "Backend_openai_serialize.openai_messages_of_message: role tool requires one or \
       more ToolResult blocks and no other content"
  | (User | Assistant | System), true, _ ->
    invalid_arg
      "Backend_openai_serialize.openai_messages_of_message: ToolResult requires role tool"
  | (User | Assistant | System), false, _ -> ()
;;

let messages_of_message_with
      ?(tool_calls_fn = tool_calls_to_openai_json)
      ?(tool_messages_fn = openai_tool_messages_of_blocks)
      ?(include_reasoning_content = false)
      ?(include_reasoning_details = false)
      ?(assistant_tool_content_format = Capability_vocab.Assistant_tool_content_null)
      ?(modality_priority = Modality.Preserve_input_order)
      (msg : message)
  : Yojson.Safe.t list
  =
  validate_tool_result_role msg;
  match msg.role with
  | User ->
    (* Apply modality reordering policy before flattening into JSON parts.
       For [Preserve_input_order] (default) this is a no-op; for
       [Visual_first] image/audio/document blocks move ahead of text.
       has_multimodal inspects the input list (pre-reorder) — the boolean
       is invariant under reordering, so either input is correct. *)
    let ordered_content = Modality.reorder modality_priority msg.content in
    let content_parts = openai_content_parts_of_blocks ordered_content in
    let has_multimodal =
      List.exists
        (function
          | Image _ | Document _ | Audio _ -> true
          | Text _
          | Thinking _
          | ReasoningDetails _
          | RedactedThinking _
          | ToolUse _
          | ToolResult _ -> false)
        msg.content
    in
    let user_msgs =
      if content_parts = []
      then []
      else if has_multimodal
      then [ `Assoc [ "role", `String "user"; "content", `List content_parts ] ]
      else (
        let text_content = Api_common.text_blocks_to_string msg.content in
        [ `Assoc [ "role", `String "user"; "content", `String text_content ] ])
    in
    user_msgs
  | Assistant ->
    let text_content = assistant_text_content_of_blocks msg.content in
    let reasoning_content =
      if include_reasoning_content
      then assistant_reasoning_content_of_blocks msg.content
      else ""
    in
    let reasoning_details =
      if include_reasoning_details
      then assistant_reasoning_details_of_blocks msg.content
      else None
    in
    let tool_calls = tool_calls_fn msg.content in
    let assistant_content =
      if Api_common.string_is_blank text_content && tool_calls <> []
      then (
        match assistant_tool_content_format with
        | Capability_vocab.Assistant_tool_content_null -> `Null
        | Capability_vocab.Assistant_tool_content_empty_string -> `String text_content)
      else `String text_content
    in
    let fields = [ "role", `String "assistant"; "content", assistant_content ] in
    let fields =
      match reasoning_details with
      | Some details -> ("reasoning_details", `List details) :: fields
      | None
        when include_reasoning_content
             && not (Api_common.string_is_blank reasoning_content) ->
        ("reasoning_content", `String reasoning_content) :: fields
      | None -> fields
    in
    let fields =
      if
        include_reasoning_content
        && reasoning_details <> None
        && not (Api_common.string_is_blank reasoning_content)
      then ("reasoning_content", `String reasoning_content) :: fields
      else fields
    in
    let fields =
      if tool_calls = [] then fields else ("tool_calls", `List tool_calls) :: fields
    in
    [ `Assoc fields ]
  | System ->
    let text = Api_common.text_blocks_to_string msg.content in
    [ `Assoc [ "role", `String "system"; "content", `String text ] ]
  | Tool ->
    msg.content
    |> tool_messages_fn
    |> (function
     | [] ->
       invalid_arg
         "Backend_openai_serialize.openai_messages_of_message: tool message projection \
          produced no results"
     | tool_msgs -> tool_msgs)
;;

let openai_messages_of_message msg =
  messages_of_message_with ~tool_calls_fn:tool_calls_to_openai_json msg
;;

type history_projection =
  { messages : Yojson.Safe.t list
  ; reasoning_replay_drops : Reasoning_history_projection.reasoning_replay_drop list
  ; removed_empty_assistant_indices : int list
  }
[@@deriving show]

let content_has_reasoning =
  List.exists (function
    | Thinking _ | ReasoningDetails _ | RedactedThinking _ -> true
    | Text _ | ToolUse _ | ToolResult _ | Image _ | Document _ | Audio _ -> false)
;;

let content_has_tool_use =
  List.exists (function
    | ToolUse _ -> true
    | Text _
    | Thinking _
    | ReasoningDetails _
    | RedactedThinking _
    | ToolResult _
    | Image _
    | Document _
    | Audio _ -> false)
;;

let content_has_visible_assistant_text =
  List.exists (function
    | Text text -> not (Api_common.string_is_blank text)
    | Thinking _
    | ReasoningDetails _
    | RedactedThinking _
    | ToolUse _
    | ToolResult _
    | Image _
    | Document _
    | Audio _ -> false)
;;

let openai_assistant_has_wire_payload (dialect : Reasoning_dialect.t) content =
  let reasoning_content = assistant_reasoning_content_of_blocks content in
  let reasoning_details = assistant_reasoning_details_of_blocks content in
  let include_reasoning_details =
    match dialect.output_wire with
    | Reasoning_dialect.Reasoning_split -> true
    | Reasoning_dialect.No_output_control -> false
  in
  content_has_visible_assistant_text content
  || content_has_tool_use content
  || (not (Api_common.string_is_blank reasoning_content))
  || (include_reasoning_details && reasoning_details <> None)
;;

let typed_history_projection ~replay_capability dialect messages =
  Reasoning_history_projection.project
    ~assistant_has_payload:(openai_assistant_has_wire_payload dialect)
    ~reasoning_block_supported:(function
      | Thinking _ | ReasoningDetails _ -> true
      | RedactedThinking _
      | Text _
      | ToolUse _
      | ToolResult _
      | Image _
      | Document _
      | Audio _ -> false)
    ~replay_capability
    messages
;;

let render_history_projection
      ?(assistant_tool_content_format = Capability_vocab.Assistant_tool_content_null)
      dialect
      (projection : Reasoning_history_projection.t)
  =
  let projected_messages =
    List.fold_left
      (fun projected (msg : Types.message) ->
         let tool_calls = tool_calls_to_openai_json msg.content in
         let include_reasoning = content_has_reasoning msg.content in
         let include_reasoning_details =
           include_reasoning
           &&
           match dialect.Reasoning_dialect.output_wire with
           | Reasoning_dialect.Reasoning_split -> true
           | Reasoning_dialect.No_output_control -> false
         in
         let rendered =
           messages_of_message_with
             ~tool_calls_fn:(fun _ -> tool_calls)
             ~include_reasoning_content:include_reasoning
             ~include_reasoning_details
             ~assistant_tool_content_format
             msg
         in
         List.rev_append rendered projected)
      []
      projection.messages
    |> List.rev
  in
  { messages = projected_messages
  ; reasoning_replay_drops = projection.reasoning_replay_drops
  ; removed_empty_assistant_indices = projection.removed_empty_assistant_indices
  }
;;

let dialect_history_projection
      ?assistant_tool_content_format
      ~replay_capability
      dialect
      messages
  =
  match typed_history_projection ~replay_capability dialect messages with
  | Error _ as error -> error
  | Ok projection ->
    Ok (render_history_projection ?assistant_tool_content_format dialect projection)
;;

let dialect_messages_of_history
      ?assistant_tool_content_format
      ~replay_capability
      dialect
      messages
  =
  match typed_history_projection ~replay_capability dialect messages with
  | Error _ as error -> error
  | Ok projection ->
    Reasoning_history_projection.observe ~component:"backend_openai" projection;
    let rendered =
      render_history_projection ?assistant_tool_content_format dialect projection
    in
    Ok rendered.messages
;;

(** Ollama native [/api/chat] user message serialization.
    Unlike OpenAI-compatible endpoints where [content] may be a string or an
    array of content parts, Ollama's native chat API requires [content] to be a
    plain string and carries image payloads in a separate [images] array of
    base64-encoded strings. Audio is not supported by the native endpoint and
    fails closed instead of being silently dropped.

    Returns [None] when the message carries no representable user content (e.g.
    an orphaned-tool-result message), so callers do not emit an empty
    [content:""] placeholder on the wire. *)
let ollama_native_user_message ~modality_priority content : Yojson.Safe.t option =
  let ordered_content = Modality.reorder modality_priority content in
  let text_parts, images =
    List.fold_left
      (fun (texts, images) block ->
         match block with
         | Text s -> Utf8_sanitize.sanitize s :: texts, images
         | Image { data; source_type = Base64; _ } ->
           (* Ollama native /api/chat accepts base64 image payloads in the
              images field. *)
           texts, data :: images
         | Image { source_type; _ } ->
           Api_common.unsupported_media_source
             ~backend:"ollama_native"
             ~block:"image"
             source_type
         | Document { media_type; _ } ->
           (* oas#2744 — documents used to be appended to [images] "so vision
              models can attempt to process them as pages". The server has no
              way to tell the two apart, so that was a silent modality change.
              [ollama_messages_of_history] rejects documents at admission
              because the native wire declares [Document_unrepresentable];
              reaching this arm means a caller bypassed admission. *)
           invalid_arg
             (Printf.sprintf
                "Backend_openai_serialize.ollama_native_user_message: document block \
                 (media_type %S) reached serialization; %s"
                media_type
                (Api_common.document_admission_error_to_string
                   (Api_common.Document_wire_has_no_representation
                      { wire_form = Api_common.Document_unrepresentable; media_type })))
         | Audio { source_type; _ } ->
           Api_common.unsupported_media_source
             ~backend:"ollama_native"
             ~block:"audio"
             source_type
         | Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolUse _ | ToolResult _
           -> texts, images)
      ([], [])
      ordered_content
  in
  let text_content =
    match List.rev text_parts with
    | [] -> ""
    | parts -> String.concat "\n" parts
  in
  match List.rev images with
  | [] when text_content = "" -> None
  | [] -> Some (`Assoc [ "role", `String "user"; "content", `String text_content ])
  | imgs ->
    Some
      (`Assoc
          [ "role", `String "user"
          ; "content", `String text_content
          ; "images", `List (List.map (fun img -> `String img) imgs)
          ])
;;

let ollama_tool_messages_of_blocks blocks =
  let rec loop messages = function
    | [] -> Ok (List.rev messages)
    | (ToolResult { content; content_blocks; _ }, Some tool_name) :: rest ->
      let content = tool_result_content_string ~content ~content_blocks in
      let message =
        `Assoc
          [ "role", `String "tool"
          ; "tool_name", `String tool_name
          ; "content", `String content
          ]
      in
      loop (message :: messages) rest
    | (ToolResult { tool_use_id; _ }, None) :: _ ->
      Error
        (Printf.sprintf
           "Ollama native ToolResult identity %S has no resolved tool name"
           tool_use_id)
    | ( ( Text _
        | Thinking _
        | ReasoningDetails _
        | RedactedThinking _
        | ToolUse _
        | Image _
        | Document _
        | Audio _ )
      , None )
      :: rest -> loop messages rest
    | (_, Some _) :: _ ->
      Error "Ollama native correlation annotated a non-ToolResult content block"
  in
  loop [] blocks
;;

let ollama_tool_block_role_contract (message : message) =
  let rec classify has_tool_use has_tool_result has_other = function
    | [] -> has_tool_use, has_tool_result, has_other
    | ToolUse _ :: rest -> classify true has_tool_result has_other rest
    | ToolResult _ :: rest -> classify has_tool_use true has_other rest
    | ( Text _
      | Thinking _
      | ReasoningDetails _
      | RedactedThinking _
      | Image _
      | Document _
      | Audio _ )
      :: rest -> classify has_tool_use has_tool_result true rest
  in
  let has_tool_use, has_tool_result, has_other =
    classify false false false message.content
  in
  match message.role, message.content with
  | Tool, [] -> Error "Ollama native role Tool requires at least one ToolResult"
  | Tool, _ ->
    if has_tool_use || has_other
    then Error "Ollama native role Tool accepts only ToolResult blocks"
    else if not has_tool_result
    then Error "Ollama native role Tool requires at least one ToolResult"
    else Ok ()
  | (User | System | Assistant), _ ->
    if has_tool_result
    then
      Error
        (Printf.sprintf
           "Ollama native ToolResult must use role Tool, got role %s"
           (Types.role_to_string message.role))
    else if has_tool_use && message.role <> Assistant
    then
      Error
        (Printf.sprintf
           "Ollama native ToolUse must use role Assistant, got role %s"
           (Types.role_to_string message.role))
    else Ok ()
;;

let ollama_messages_of_history
      ~modality_priority
      ~supports_image_input
      ~supports_document_input
      messages
  =
  let rec validate_content = function
    | [] -> Ok ()
    | Image _ :: _ when not supports_image_input ->
      Error "Ollama native image input is not declared by the frozen capability snapshot"
    | Document _ :: _ when not supports_document_input ->
      Error
        "Ollama native document input is not declared by the frozen capability snapshot"
    | Document _ :: _ -> Error "Ollama native wire cannot represent document input"
    | ToolResult { content_blocks = Some blocks; _ } :: rest ->
      (match validate_content blocks with
       | Error _ as error -> error
       | Ok () -> validate_content rest)
    | _ :: rest -> validate_content rest
  in
  let rec validate = function
    | [] -> Ok ()
    | (message : Types.message) :: rest ->
      (match validate_content message.content with
       | Error _ as error -> error
       | Ok () ->
         (match ollama_tool_block_role_contract message with
          | Error _ as error -> error
          | Ok () -> validate rest))
  in
  match validate messages with
  | Error _ as error -> error
  | Ok () ->
    (match Tool_result_projection.of_messages messages with
     | Error error -> Error (Tool_result_projection.error_to_string error)
     | Ok projection ->
       let modality_priority = modality_priority in
       let rec render rendered = function
         | [] -> Ok (List.rev rendered |> List.concat)
         | resolved_message :: rest ->
           let msg = Tool_result_projection.original_message resolved_message in
           (match
              Tool_result_projection.content resolved_message
              |> ollama_tool_messages_of_blocks
            with
            | Error _ as error -> error
            | Ok tool_messages ->
              let wire_messages =
                match msg.role with
                | User ->
                  (* Native /api/chat: content is scalar; images are separate. *)
                  (match ollama_native_user_message ~modality_priority msg.content with
                   | None -> tool_messages
                   | Some user_message -> tool_messages @ [ user_message ])
                | Assistant ->
                  let thinking = assistant_reasoning_content_of_blocks msg.content in
                  messages_of_message_with
                    ~tool_calls_fn:tool_calls_to_ollama_json
                    ~tool_messages_fn:(fun _ -> tool_messages)
                    ~modality_priority
                    msg
                  |> List.map (function
                    | `Assoc fields when not (Api_common.string_is_blank thinking) ->
                      `Assoc (("thinking", `String thinking) :: fields)
                    | message -> message)
                | System | Tool ->
                  messages_of_message_with
                    ~tool_calls_fn:tool_calls_to_ollama_json
                    ~tool_messages_fn:(fun _ -> tool_messages)
                    ~modality_priority
                    msg
              in
              render (wire_messages :: rendered) rest)
       in
       render [] (Tool_result_projection.messages projection))
;;

let tool_choice_to_openai_json = function
  | Auto -> `String "auto"
  | Any -> `String "required"
  | Tool name ->
    `Assoc [ "type", `String "function"; "function", `Assoc [ "name", `String name ] ]
  | None_ -> `String "none"
;;

(* Single source of truth for the OpenAI-compatible parallel-tool-call control.
   Two layers decide *whether* to disable parallel calls (low-level
   [Backend_openai_request] guards on [tools <> []]; agent-state-aware
   [Api_openai] guards on [capabilities.supports_tools]); both serialize the
   field through here so the wire shape lives in one place. OpenAI defaults to
   parallel calls, so the field is emitted only to turn them off. *)
let parallel_tool_calls_fields ~disable_parallel ~tools_present
  : (string * Yojson.Safe.t) list
  =
  if disable_parallel && tools_present then [ "parallel_tool_calls", `Bool false ] else []
;;

type tool_definition =
  { name : string
  ; description : string
  ; parameters : Yojson.Safe.t
  ; strict : bool option
  }

let invalid_tool_definition format =
  Printf.ksprintf
    (fun detail ->
       invalid_arg ("Backend_openai_serialize.tool_definition_of_json: " ^ detail))
    format
;;

let tool_definition_of_json = function
  | `Assoc fields ->
    let allowed = [ "name"; "description"; "input_schema"; "parameters"; "strict" ] in
    let names = List.map fst fields in
    let duplicate =
      List.find_opt
        (fun name -> List.length (List.filter (String.equal name) names) > 1)
        names
    in
    (match duplicate with
     | Some name -> invalid_tool_definition "duplicate field %S" name
     | None -> ());
    (match List.find_opt (fun name -> not (List.mem name allowed)) names with
     | Some name -> invalid_tool_definition "unknown field %S" name
     | None -> ());
    let name =
      match List.assoc_opt "name" fields with
      | Some (`String name) when not (String.equal (String.trim name) "") -> name
      | Some (`String _) -> invalid_tool_definition "name must not be empty"
      | Some _ -> invalid_tool_definition "name must be a string"
      | None -> invalid_tool_definition "missing field \"name\""
    in
    let description =
      match List.assoc_opt "description" fields with
      | Some (`String description) -> description
      | Some _ -> invalid_tool_definition "description must be a string"
      | None -> invalid_tool_definition "missing field \"description\""
    in
    let parameters =
      match List.assoc_opt "input_schema" fields, List.assoc_opt "parameters" fields with
      | Some (`Assoc _ as schema), None | None, Some (`Assoc _ as schema) -> schema
      | Some _, None -> invalid_tool_definition "input_schema must be a JSON object"
      | None, Some _ -> invalid_tool_definition "parameters must be a JSON object"
      | Some _, Some _ ->
        invalid_tool_definition "input_schema and parameters are mutually exclusive"
      | None, None ->
        invalid_tool_definition "missing field \"input_schema\" or \"parameters\""
    in
    let strict =
      match List.assoc_opt "strict" fields with
      | Some (`Bool strict) -> Some strict
      | Some _ -> invalid_tool_definition "strict must be a boolean"
      | None -> None
    in
    { name; description; parameters; strict }
  | _ -> invalid_tool_definition "tool must be a JSON object"
;;

let tool_definition_fields definition =
  [ "name", `String definition.name
  ; "description", `String definition.description
  ; "parameters", definition.parameters
  ]
  @
  match definition.strict with
  | Some strict -> [ "strict", `Bool strict ]
  | None -> []
;;

let build_openai_tool_json tool =
  let definition = tool_definition_of_json tool in
  `Assoc
    [ "type", `String "function"; "function", `Assoc (tool_definition_fields definition) ]
;;
