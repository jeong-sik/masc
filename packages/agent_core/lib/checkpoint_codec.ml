open Types
open Checkpoint_types
open Result_syntax

let checkpoint_version = Checkpoint_types.checkpoint_version

let reasoning_effort_option_to_json = function
  | Some effort -> `String (Llm_provider.Reasoning_effort.to_string effort)
  | None -> `Null
;;

let reasoning_effort_option_of_json ~scope = function
  | `Null -> Ok None
  | `String value ->
    (match Llm_provider.Reasoning_effort.of_string value with
     | Some effort -> Ok (Some effort)
     | None ->
       Error
         (Error.Serialization
            (JsonParseError
               { detail = Printf.sprintf "%s: unsupported reasoning_effort %S" scope value
               })))
  | _ ->
    Error
      (Error.Serialization
         (JsonParseError { detail = scope ^ ": reasoning_effort must be string or null" }))
;;

let validate_exact_object_fields ~scope ~expected = function
  | `Assoc fields ->
    let names = List.map fst fields in
    let duplicates =
      names
      |> List.sort String.compare
      |> List.fold_left
           (fun (previous, duplicates) name ->
              match previous with
              | Some previous when String.equal previous name ->
                Some name, name :: duplicates
              | Some _ | None -> Some name, duplicates)
           (None, [])
      |> snd
      |> List.sort_uniq String.compare
    in
    let missing = List.filter (fun name -> not (List.mem name names)) expected in
    let unknown = List.filter (fun name -> not (List.mem name expected)) names in
    if duplicates = [] && missing = [] && unknown = []
    then Ok ()
    else
      Error
        (Error.Serialization
           (JsonParseError
              { detail =
                  Printf.sprintf
                    "%s schema mismatch (missing=[%s], unknown=[%s], duplicate=[%s])"
                    scope
                    (String.concat "," missing)
                    (String.concat "," unknown)
                    (String.concat "," duplicates)
              }))
  | _ ->
    Error
      (Error.Serialization (JsonParseError { detail = scope ^ " must be a JSON object" }))
;;

let pricing_gap_to_json = function
  | Model_identity_unavailable -> `Assoc [ "kind", `String "model_identity_unavailable" ]
  | Pricing_unavailable model_id ->
    `Assoc [ "kind", `String "pricing_unavailable"; "model_id", `String model_id ]
;;

let pricing_gap_of_json json =
  let open Yojson.Safe.Util in
  match json with
  | `Null -> Ok None
  | `Assoc [ ("kind", `String "model_identity_unavailable") ] ->
    Ok (Some Model_identity_unavailable)
  | `Assoc fields ->
    (match List.assoc_opt "kind" fields, List.assoc_opt "model_id" fields with
     | Some (`String "pricing_unavailable"), Some (`String model_id)
       when List.length fields = 2 && model_id <> "" ->
       Ok (Some (Pricing_unavailable model_id))
     | _ ->
       Error
         (Error.Serialization
            (JsonParseError
               { detail = "Checkpoint.usage_of_json: invalid pricing_gap object" })))
  | _ ->
    Error
      (Error.Serialization
         (JsonParseError
            { detail = "Checkpoint.usage_of_json: pricing_gap must be null or object" }))
;;

let usage_to_json u =
  `Assoc
    [ "total_input_tokens", `Int u.total_input_tokens
    ; "total_output_tokens", `Int u.total_output_tokens
    ; "total_cache_creation_input_tokens", `Int u.total_cache_creation_input_tokens
    ; "total_cache_read_input_tokens", `Int u.total_cache_read_input_tokens
    ; "api_calls", `Int u.api_calls
    ; "estimated_cost_usd", `Float u.estimated_cost_usd
    ; ( "pricing_gap"
      , match u.pricing_gap with
        | Some gap -> pricing_gap_to_json gap
        | None -> `Null )
    ]
;;

let usage_of_json json =
  let open Yojson.Safe.Util in
  match json with
  | `Assoc _ ->
    let* () =
      validate_exact_object_fields
        ~scope:"Checkpoint.usage"
        ~expected:
          [ "total_input_tokens"
          ; "total_output_tokens"
          ; "total_cache_creation_input_tokens"
          ; "total_cache_read_input_tokens"
          ; "api_calls"
          ; "estimated_cost_usd"
          ; "pricing_gap"
          ]
        json
    in
    (try
       let* pricing_gap = json |> member "pricing_gap" |> pricing_gap_of_json in
       Ok
         { total_input_tokens = json |> member "total_input_tokens" |> to_int
         ; total_output_tokens = json |> member "total_output_tokens" |> to_int
         ; total_cache_creation_input_tokens =
             json |> member "total_cache_creation_input_tokens" |> to_int
         ; total_cache_read_input_tokens =
             json |> member "total_cache_read_input_tokens" |> to_int
         ; api_calls = json |> member "api_calls" |> to_int
         ; estimated_cost_usd = json |> member "estimated_cost_usd" |> to_float
         ; pricing_gap
         }
     with
     | Yojson.Safe.Util.Type_error (detail, _) ->
       Error
         (Error.Serialization
            (JsonParseError { detail = "Checkpoint.usage_of_json: " ^ detail })))
  | _ ->
    Error
      (Error.Serialization
         (JsonParseError { detail = "Checkpoint.usage_of_json: expected object" }))
;;

let tool_schema_to_json = Types.tool_schema_to_json

let map_str_err r =
  Result.map_error
    (fun s ->
       Error.Serialization (UnknownVariant { type_name = "param_type"; value = s }))
    r
;;

let tool_schema_of_json json = map_str_err (Types.tool_schema_of_json json)

let result_all items =
  List.fold_left
    (fun acc item ->
       let* acc = acc in
       let* item = item in
       Ok (item :: acc))
    (Ok [])
    items
  |> Result.map List.rev
;;

let checkpoint_tool_result_to_json ~tool_use_id ~content ~outcome content_override =
  let fields =
    Llm_provider.Api_common.tool_result_wire_fields ~tool_use_id ~content ~outcome
  in
  let fields =
    match content_override with
    | None -> fields
    | Some content ->
      List.map
        (fun (name, value) ->
           if String.equal name "content" then name, content else name, value)
        fields
  in
  let provenance =
    match outcome with
    | Tool_succeeded -> []
    | Tool_failed { failure_kind; error_class } ->
      [ "failure_kind", Types.tool_failure_kind_to_yojson failure_kind ]
      @
        (match error_class with
        | Some error_class ->
          [ "error_class", Types.tool_error_class_to_yojson error_class ]
        | None -> [])
  in
  `Assoc
    (fields @ provenance
     @ match content_override with
       | None -> []
       | Some _ -> [ "text_content", `String content ])
;;

(* Total: every arm builds JSON from typed fields and raises nothing.
   Callers rely on that and do not catch around it, so an arm that can fail
   must change the return type instead of raising. *)
let rec checkpoint_content_block_to_json block =
  match block with
  | ToolResult { tool_use_id; content; outcome; json = _; content_blocks } ->
    let content_override =
      Option.map
        (fun blocks -> `List (List.map checkpoint_content_block_to_json blocks))
        content_blocks
    in
    checkpoint_tool_result_to_json ~tool_use_id ~content ~outcome content_override
  | Text _
  | Thinking _
  | ReasoningDetails _
  | RedactedThinking _
  | ToolUse _
  | Image _
  | Document _
  | Audio _ -> Llm_provider.Api_common.content_block_to_json block
;;

let checkpoint_json_validation_error error =
  Error.Serialization
    (JsonParseError { detail = Execution_json.validation_error_to_string error })
;;

let validate_checkpoint_json ~context json =
  Execution_json.validate ~context json
  |> Result.map_error checkpoint_json_validation_error
;;

let unique_optional_field ~field fields =
  match
    List.filter_map
      (fun (name, value) -> if String.equal name field then Some value else None)
      fields
  with
  | [] -> Ok None
  | [ value ] -> Ok (Some value)
  | _ ->
    Error
      (Error.Serialization
         (JsonParseError
            { detail = Printf.sprintf "Checkpoint ToolResult duplicates field %s" field }))
;;

let optional_typed_field ~field ~type_name ~decode fields =
  let* value = unique_optional_field ~field fields in
  match value with
  | None -> Ok None
  | Some value ->
    decode value
    |> Result.map Option.some
    |> Result.map_error (fun detail ->
      Error.Serialization
        (JsonParseError
           { detail =
               Printf.sprintf
                 "Checkpoint ToolResult field %s has invalid %s: %s"
                 field
                 type_name
                 detail
           }))
;;

let tool_result_fields json =
  match json with
  | `Assoc fields -> Ok fields
  | non_object ->
    Error
      (Error.Serialization
         (JsonParseError
            { detail =
                Printf.sprintf
                  "Checkpoint ToolResult must be an object, got %s"
                  (Yojson.Safe.to_string non_object)
            }))
;;

let rec content_block_of_json_strict json =
  try
    match
      Llm_provider.Api_common.content_block_of_json
        ~parse_tool_result_json:false
        json
    with
    | Some
        (ToolResult
           { tool_use_id
           ; content
           ; outcome = wire_outcome
           ; json = _
           ; content_blocks = _
           }) ->
      let* fields = tool_result_fields json in
      let* text_content = unique_optional_field ~field:"text_content" fields in
      let* content =
        match text_content with
        | None -> Ok content
        | Some (`String text) -> Ok text
        | Some _ ->
          Error
            (Error.Serialization
               (JsonParseError
                  { detail = "Checkpoint ToolResult text_content must be a string" }))
      in
      let* content_blocks =
        match List.assoc_opt "content" fields with
        | Some (`String _) -> Ok None
        | Some (`List blocks) ->
          let+ blocks = List.map content_block_of_json_strict blocks |> result_all in
          Some blocks
        | Some _ ->
          Error
            (Error.Serialization
               (JsonParseError
                  { detail = "Checkpoint ToolResult content must be a string or an array"
                  }))
        | None ->
          Error
            (Error.Serialization
               (JsonParseError { detail = "Checkpoint ToolResult is missing content" }))
      in
      let* failure_kind =
        optional_typed_field
          ~field:"failure_kind"
          ~type_name:"tool_failure_kind"
          ~decode:Types.tool_failure_kind_of_yojson
          fields
      and* error_class =
        optional_typed_field
          ~field:"error_class"
          ~type_name:"tool_error_class"
          ~decode:Types.tool_error_class_of_yojson
          fields
      in
      let* outcome =
        match wire_outcome, failure_kind, error_class with
        | Tool_succeeded, None, None -> Ok Tool_succeeded
        | Tool_succeeded, _, _ ->
          Error
            (Error.Serialization
               (JsonParseError
                  { detail =
                      "Checkpoint ToolResult marks success but contains failure \
                       provenance"
                  }))
        | Tool_failed _, Some failure_kind, error_class ->
          Ok (Tool_failed { failure_kind; error_class })
        | Tool_failed _, None, None ->
          Error
            (Error.Serialization
               (JsonParseError
                  { detail =
                      "Checkpoint ToolResult failure is missing failure_kind provenance"
                  }))
        | Tool_failed _, None, Some _ ->
          Error
            (Error.Serialization
               (JsonParseError
                  { detail = "Checkpoint ToolResult has error_class without failure_kind"
                  }))
      in
      Ok
        (ToolResult { tool_use_id; content; outcome; json = None; content_blocks })
    | Some (ReasoningDetails { details; _ }) ->
      let* fields =
        match json with
        | `Assoc fields -> Ok fields
        | _ ->
          Error
            (Error.Serialization
               (JsonParseError
                  { detail = "Checkpoint ReasoningDetails must be a JSON object" }))
      in
      let* reasoning_content = unique_optional_field ~field:"reasoning_content" fields in
      (match reasoning_content with
       | None -> Ok (ReasoningDetails { reasoning_content = None; details })
       | Some (`String reasoning_content) ->
         Ok (ReasoningDetails { reasoning_content = Some reasoning_content; details })
       | Some _ ->
         Error
           (Error.Serialization
              (JsonParseError
                 { detail =
                     "Checkpoint ReasoningDetails reasoning_content must be a string"
                 })))
    | Some
        (( Text _ | Thinking _ | RedactedThinking _ | ToolUse _ | Image _ | Document _
         | Audio _ ) as block) -> Ok block
    | None ->
      (* The option-returning decoder collapses every refusal into [None], and
         reading the block's own "type" back out of the JSON described the
         wrong thing: a [tool_use] block with a blank id is refused for the id,
         not for being an unknown type, and the message said "Unknown content
         block type: tool_use" about a type the decoder knows perfectly well.
         The result-returning decoder next to it already names the field it
         refused, so the reason travels instead of being guessed. *)
      let detail =
        match
          Llm_provider.Api_common.content_block_of_json_result
            ~parse_tool_result_json:false
            json
        with
        | Ok _ ->
          (* [content_block_of_json] is [content_block_of_json_result] with the
             error dropped, so the two cannot disagree; this arm exists because
             the type does not say so. *)
          "Checkpoint content block was refused without a reason"
        | Error error ->
          Llm_provider.Api_common.content_block_decode_error_to_string error
      in
      Error (Error.Serialization (JsonParseError { detail }))
  with
  | Yojson.Safe.Util.Type_error (msg, _) ->
    Error
      (Error.Serialization
         (JsonParseError { detail = Printf.sprintf "Invalid content block: %s" msg }))
  | Yojson.Json_error msg ->
    Error
      (Error.Serialization
         (JsonParseError { detail = Printf.sprintf "Invalid content block: %s" msg }))
  | Failure msg ->
    Error
      (Error.Serialization
         (JsonParseError { detail = Printf.sprintf "Invalid content block: %s" msg }))
;;

let metadata_of_json json =
  let open Yojson.Safe.Util in
  match json |> member "metadata" with
  | `Null -> Ok []
  | `Assoc fields -> Ok fields
  | other ->
    Error
      (Error.Serialization
         (JsonParseError
            { detail =
                Printf.sprintf
                  "Checkpoint.message metadata must be an object, got %s"
                  (Yojson.Safe.to_string other)
            }))
;;

let message_json (msg : Types.message) content =
  let base_fields =
    [ "role", `String (Types.role_to_string msg.role)
    ; "content", `List content
    ]
  in
  let optional_fields =
    (match msg.name with
     | Some name -> [ "name", `String name ]
     | None -> [])
    @ (match msg.tool_call_id with
       | Some tool_call_id -> [ "tool_call_id", `String tool_call_id ]
       | None -> [])
    @ if msg.metadata = [] then [] else [ "metadata", `Assoc msg.metadata ]
  in
  `Assoc (base_fields @ optional_fields)
;;

let message_to_json (msg : Types.message) =
  message_json msg (List.map checkpoint_content_block_to_json msg.content)
;;

let message_of_json json =
  let open Yojson.Safe.Util in
  let role_str = json |> member "role" |> to_string in
  let role =
    match Types.role_of_string role_str with
    | Some role -> Ok role
    | None ->
      Error
        (Error.Serialization (UnknownVariant { type_name = "role"; value = role_str }))
  in
  let content =
    json
    |> member "content"
    |> to_list
    |> List.map content_block_of_json_strict
    |> result_all
  in
  let metadata = metadata_of_json json in
  let* role = role
  and* content = content
  and* metadata = metadata in
  Ok
    { role
    ; content
    ; name = json |> member "name" |> to_string_option
    ; tool_call_id = json |> member "tool_call_id" |> to_string_option
    ; metadata
    }
;;

let messages_field = "messages"

(* The checkpoint object with its message array cut out, as the fields before
   and after it. [checkpoint_json_with_messages] puts the array back as a JSON
   tree; [to_pieces_with_encoding_memo] writes already encoded messages between
   the two halves. *)
let checkpoint_fields_around_messages cp =
  ( [ "version", `Int cp.version
    ; "session_id", `String cp.session_id
    ; "agent_name", `String cp.agent_name
    ; "model", model_to_yojson cp.model
    ; "system_prompt", Util.json_of_string_opt cp.system_prompt
    ]
  , [ "usage", usage_to_json cp.usage
    ; "turn_count", `Int cp.turn_count
    ; "created_at", `Float cp.created_at
    ; "tools", `List (List.map tool_schema_to_json cp.tools)
    ; ( "tool_choice"
      , match cp.tool_choice with
        | Some tc -> tool_choice_to_json tc
        | None -> `Null )
    ; "temperature", Util.json_of_float_opt cp.temperature
    ; "top_p", Util.json_of_float_opt cp.top_p
    ; "top_k", Util.json_of_int_opt cp.top_k
    ; "min_p", Util.json_of_float_opt cp.min_p
    ; "enable_thinking", Util.json_of_bool_opt cp.enable_thinking
    ; "preserve_thinking", Util.json_of_bool_opt cp.preserve_thinking
    ; "response_format", response_format_to_json cp.response_format
    ; "reasoning_effort", reasoning_effort_option_to_json cp.reasoning_effort
    ; "disable_parallel_tool_use", `Bool cp.disable_parallel_tool_use
    ; "cache_system_prompt", `Bool cp.cache_system_prompt
    ; "context", Context.to_json cp.context
    ; "mcp_sessions", Mcp_session.info_list_to_json cp.mcp_sessions
    ; "pending_input", (match cp.pending_input with None -> `Null | Some p -> Agent_input_request.pending_to_json p)
    ; ( "working_context"
      , match cp.working_context with
        | Some working_context -> working_context
        | None -> `Null )
    ] )
;;

let checkpoint_json_with_messages cp messages =
  let before_messages, after_messages = checkpoint_fields_around_messages cp in
  `Assoc (before_messages @ ((messages_field, `List messages) :: after_messages))
;;

let decode_current_json json =
  try
    let open Yojson.Safe.Util in
    let* () = Checkpoint_contract.validate_json json in
    let* tool_choice =
      match json |> member "tool_choice" with
      | `Null -> Ok None
      | tc ->
        let+ tc = tool_choice_of_json tc in
        Some tc
    in
    let* model =
      model_of_yojson (json |> member "model")
      |> Result.map_error (fun e -> Error.Serialization (JsonParseError { detail = e }))
    and* messages =
      json |> member "messages" |> to_list |> List.map message_of_json |> result_all
    and* tools =
      json |> member "tools" |> to_list |> List.map tool_schema_of_json |> result_all
    and* context =
      Context.of_json (json |> member "context")
      |> Result.map_error (fun error ->
        Error.Serialization
          (JsonParseError
             { detail =
                 Printf.sprintf
                   "Checkpoint.of_json: %s"
                   (Context.decode_error_to_string error)
             }))
    and* mcp_sessions =
      match json |> member "mcp_sessions" with
      | `List _ as lst -> Mcp_session.info_list_of_json lst
      | _ ->
        Error
          (Error.Serialization
             (JsonParseError
                { detail = "Checkpoint.of_json: mcp_sessions must be a JSON array or null"
                }))
    and* response_format = response_format_of_json (json |> member "response_format") in
    let* reasoning_effort =
      reasoning_effort_option_of_json
        ~scope:"Checkpoint"
        (json |> member "reasoning_effort")
    in
    let* usage = json |> member "usage" |> usage_of_json in
    let* pending_input =
      match json |> member "pending_input" with
      | `Null -> Ok None
      | value -> Agent_input_request.pending_of_json value
          |> Result.map Option.some
          |> Result.map_error (fun detail -> Error.Serialization (JsonParseError {detail}))
    in
    let working_context =
      match json |> member "working_context" with
      | `Null -> None
      | v -> Some v
    in
    Ok
      { version = checkpoint_version
      ; session_id = json |> member "session_id" |> to_string
      ; agent_name = json |> member "agent_name" |> to_string
      ; model
      ; system_prompt = json |> member "system_prompt" |> to_string_option
      ; messages
      ; usage
      ; turn_count = json |> member "turn_count" |> to_int
      ; created_at = json |> member "created_at" |> to_float
      ; tools
      ; tool_choice
      ; disable_parallel_tool_use = json |> member "disable_parallel_tool_use" |> to_bool
      ; temperature = json |> member "temperature" |> to_float_option
      ; top_p = json |> member "top_p" |> to_float_option
      ; top_k = json |> member "top_k" |> to_int_option
      ; min_p = json |> member "min_p" |> to_float_option
      ; enable_thinking = json |> member "enable_thinking" |> to_bool_option
      ; preserve_thinking = json |> member "preserve_thinking" |> to_bool_option
      ; response_format
      ; reasoning_effort
      ; cache_system_prompt = json |> member "cache_system_prompt" |> to_bool
      ; context
      ; mcp_sessions
      ; working_context
      ; pending_input
      }
  with
  | Yojson.Safe.Util.Type_error (msg, _) ->
    Error
      (Error.Serialization
         (JsonParseError { detail = Printf.sprintf "Checkpoint.of_json: %s" msg }))
  | Yojson.Json_error msg ->
    Error
      (Error.Serialization
         (JsonParseError { detail = Printf.sprintf "Checkpoint.of_json: %s" msg }))
  | Failure msg ->
    Error
      (Error.Serialization
         (JsonParseError { detail = Printf.sprintf "Checkpoint.of_json: %s" msg }))
;;

let checkpoint_json_result cp =
  let json = checkpoint_json_with_messages cp (List.map message_to_json cp.messages) in
  let* () = validate_checkpoint_json ~context:"Checkpoint v12" json in
  let+ _ = decode_current_json json in
  json
;;

let validate_checkpoint cp = Result.map ignore (checkpoint_json_result cp)
let to_json_result = checkpoint_json_result

(* #31677: one provider-authored unencodable payload — a duplicate object key
   or a non-finite float anywhere a message carries raw json — poisons the
   in-memory checkpoint forever, because [to_json] validates the whole tree
   on every encode and the sink refuses the write, so the keeper dies at the
   same stage of every later turn. The codec keeps rejecting (that is the
   public contract); this is the named recovery operation the durable write
   applies to a COPY: every json payload that cannot be canonically encoded
   is removed, and the text around it stays. A required payload field
   ([ToolUse.input], a reasoning detail's [raw]) becomes an empty object
   rather than losing its block. [None] means nothing was droppable — the
   refusal is not a payload problem, so the caller keeps the original
   error instead of retrying. *)
let encodable_json json =
  match Execution_json.validate ~context:"Checkpoint v12 drop" json with
  | Ok () -> true
  | Error _ -> false
;;

let rec drop_unencodable_block (dropped : int ref) block =
  let empty_object = `Assoc [] in
  match block with
  | ToolUse { id; name; input } ->
    if encodable_json input then block
    else (
      incr dropped;
      ToolUse { id; name; input = empty_object })
  | ToolResult { tool_use_id; content; outcome; json; content_blocks } ->
    let content_blocks =
      match content_blocks with
      | None -> None
      | Some blocks ->
        Some (List.map (drop_unencodable_block dropped) blocks)
    in
    ToolResult { tool_use_id; content; outcome; json; content_blocks }
  | ReasoningDetails { reasoning_content; details } ->
    let details =
      details
      |> List.map (fun (detail : Types.reasoning_detail) ->
             if encodable_json detail.Types.raw then detail
             else (
               incr dropped;
               { detail with Types.raw = empty_object }))
    in
    ReasoningDetails { reasoning_content; details }
  | Text _ | Thinking _ | RedactedThinking _ | Image _ | Document _ | Audio _ ->
    block
;;

let drop_unencodable_json cp =
  match to_json_result cp with
  | Ok _ -> None
  | Error _ ->
    let dropped = ref 0 in
    let drop_metadata (name, value) =
      if encodable_json value then Some (name, value)
      else (
        incr dropped;
        None)
    in
    let messages =
      cp.messages
      |> List.map (fun (message : Types.message) ->
             { message with
               Types.metadata = List.filter_map drop_metadata message.Types.metadata
             ; Types.content =
                 List.map (drop_unencodable_block dropped) message.Types.content
             })
    in
    let working_context =
      match cp.working_context with
      | Some payload when not (encodable_json payload) ->
        incr dropped;
        None
      | working_context -> working_context
    in
    if !dropped = 0 then None
    else Some { cp with messages; working_context }
;;

let validated_checkpoint_json_exn ~scope cp =
  match to_json_result cp with
  | Ok json -> json
  | Error error -> invalid_arg (scope ^ ": " ^ Error.to_string error)
;;

let checkpoint_hash cp =
  Digest.string
    (Yojson.Safe.to_string
       (validated_checkpoint_json_exn ~scope:"Checkpoint.checkpoint_hash" cp))
  |> Digest.to_hex
;;

let context_diff_to_json (diff : Context.diff) =
  let kv_pairs name pairs =
    ( name
    , `List
        (List.map
           (fun (key, value) -> `Assoc [ "key", `String key; "value", value ])
           pairs) )
  in
  `Assoc
    [ kv_pairs "added" diff.added
    ; "removed", Util.json_of_string_list diff.removed
    ; kv_pairs "changed" diff.changed
    ]
;;

let context_diff_of_json json =
  let open Yojson.Safe.Util in
  let parse_kvs name =
    json
    |> member name
    |> to_list
    |> List.map (fun item ->
      try Ok (item |> member "key" |> to_string, item |> member "value") with
      | Type_error (msg, _) ->
        Error
          (Error.Serialization
             (JsonParseError
                { detail = Printf.sprintf "Checkpoint.delta context diff %s: %s" name msg
                })))
    |> result_all
  in
  let parse_removed () =
    try Ok (json |> member "removed" |> to_list |> List.map to_string) with
    | Type_error (msg, _) ->
      Error
        (Error.Serialization
           (JsonParseError
              { detail = Printf.sprintf "Checkpoint.delta context diff removed: %s" msg }))
  in
  let* added = parse_kvs "added"
  and* changed = parse_kvs "changed"
  and* removed = parse_removed () in
  Ok { Context.added; removed; changed }
;;

let delta_to_json (delta : delta) =
  let op_to_json = function
    | Replace_identity patch ->
      `Assoc
        [ "kind", `String "replace_identity"
        ; "session_id", `String patch.session_id
        ; "agent_name", `String patch.agent_name
        ; "model", model_to_yojson patch.model
        ; "created_at", `Float patch.created_at
        ]
    | Replace_system_prompt prompt ->
      `Assoc
        [ "kind", `String "replace_system_prompt"
        ; ( "system_prompt"
          , match prompt with
            | Some value -> `String value
            | None -> `Null )
        ]
    | Splice_messages splice ->
      `Assoc
        [ "kind", `String "splice_messages"
        ; "start_index", `Int splice.start_index
        ; "delete_count", `Int splice.delete_count
        ; "insert", `List (List.map message_to_json splice.insert)
        ]
    | Replace_usage usage ->
      `Assoc [ "kind", `String "replace_usage"; "usage", usage_to_json usage ]
    | Replace_turn_count turn_count ->
      `Assoc [ "kind", `String "replace_turn_count"; "turn_count", `Int turn_count ]
    | Replace_tools tools ->
      `Assoc
        [ "kind", `String "replace_tools"
        ; "tools", `List (List.map tool_schema_to_json tools)
        ]
    | Replace_tool_choice tool_choice ->
      `Assoc
        [ "kind", `String "replace_tool_choice"
        ; ( "tool_choice"
          , match tool_choice with
            | Some choice -> tool_choice_to_json choice
            | None -> `Null )
        ]
    | Replace_sampling patch ->
      `Assoc
        [ "kind", `String "replace_sampling"
        ; "temperature", Util.json_of_float_opt patch.temperature
        ; "top_p", Util.json_of_float_opt patch.top_p
        ; "top_k", Util.json_of_int_opt patch.top_k
        ; "min_p", Util.json_of_float_opt patch.min_p
        ; "enable_thinking", Util.json_of_bool_opt patch.enable_thinking
        ; "preserve_thinking", Util.json_of_bool_opt patch.preserve_thinking
        ; "reasoning_effort", reasoning_effort_option_to_json patch.reasoning_effort
        ]
    | Replace_limits patch ->
      `Assoc
        [ "kind", `String "replace_limits"
        ; "disable_parallel_tool_use", `Bool patch.disable_parallel_tool_use
        ; "response_format", response_format_to_json patch.response_format
        ; "cache_system_prompt", `Bool patch.cache_system_prompt
        ]
    | Patch_context diff ->
      `Assoc [ "kind", `String "patch_context"; "diff", context_diff_to_json diff ]
    | Replace_mcp_sessions sessions ->
      `Assoc
        [ "kind", `String "replace_mcp_sessions"
        ; "mcp_sessions", Mcp_session.info_list_to_json sessions
        ]
    | Replace_pending_input pending_input ->
      `Assoc ["kind", `String "replace_pending_input"; "pending_input",
        (match pending_input with None -> `Null | Some p -> Agent_input_request.pending_to_json p)]
    | Replace_working_context working_context ->
      `Assoc
        [ "kind", `String "replace_working_context"
        ; "working_context", Option.value ~default:`Null working_context
        ]
  in
  `Assoc
    [ "delta_version", `Int delta.delta_version
    ; "base_checkpoint_version", `Int delta.base_checkpoint_version
    ; "base_checkpoint_hash", `String delta.base_checkpoint_hash
    ; "result_checkpoint_hash", `String delta.result_checkpoint_hash
    ; "created_at", `Float delta.created_at
    ; "operations", `List (List.map op_to_json delta.operations)
    ]
;;

let delta_of_json json =
  let open Yojson.Safe.Util in
  let op_of_json op_json =
    let kind = op_json |> member "kind" |> to_string in
    match kind with
    | "replace_identity" ->
      let+ model =
        model_of_yojson (op_json |> member "model")
        |> Result.map_error (fun e -> Error.Serialization (JsonParseError { detail = e }))
      in
      Replace_identity
        { session_id = op_json |> member "session_id" |> to_string
        ; agent_name = op_json |> member "agent_name" |> to_string
        ; model
        ; created_at = op_json |> member "created_at" |> to_float
        }
    | "replace_system_prompt" ->
      Ok (Replace_system_prompt (op_json |> member "system_prompt" |> to_string_option))
    | "splice_messages" ->
      let+ insert =
        op_json |> member "insert" |> to_list |> List.map message_of_json |> result_all
      in
      Splice_messages
        { start_index = op_json |> member "start_index" |> to_int
        ; delete_count = op_json |> member "delete_count" |> to_int
        ; insert
        }
    | "replace_usage" ->
      let+ usage = usage_of_json (op_json |> member "usage") in
      Replace_usage usage
    | "replace_turn_count" ->
      Ok (Replace_turn_count (op_json |> member "turn_count" |> to_int))
    | "replace_tools" ->
      let+ tools =
        op_json |> member "tools" |> to_list |> List.map tool_schema_of_json |> result_all
      in
      Replace_tools tools
    | "replace_tool_choice" ->
      (match op_json |> member "tool_choice" with
       | `Null -> Ok (Replace_tool_choice None)
       | value ->
         let+ value = tool_choice_of_json value in
         Replace_tool_choice (Some value))
    | "replace_sampling" ->
      let+ reasoning_effort =
        reasoning_effort_option_of_json
          ~scope:"Checkpoint.delta replace_sampling"
          (op_json |> member "reasoning_effort")
      in
      Replace_sampling
        { temperature = op_json |> member "temperature" |> to_float_option
        ; top_p = op_json |> member "top_p" |> to_float_option
        ; top_k = op_json |> member "top_k" |> to_int_option
        ; min_p = op_json |> member "min_p" |> to_float_option
        ; enable_thinking = op_json |> member "enable_thinking" |> to_bool_option
        ; preserve_thinking = op_json |> member "preserve_thinking" |> to_bool_option
        ; reasoning_effort
        }
    | "replace_limits" ->
      let* () =
        validate_exact_object_fields
          ~scope:"Checkpoint.delta replace_limits"
          ~expected:
            [ "kind"
            ; "disable_parallel_tool_use"
            ; "response_format"
            ; "cache_system_prompt"
            ]
          op_json
      in
      let+ response_format =
        response_format_of_json (op_json |> member "response_format")
      in
      Replace_limits
        { disable_parallel_tool_use =
            op_json |> member "disable_parallel_tool_use" |> to_bool
        ; response_format
        ; cache_system_prompt = op_json |> member "cache_system_prompt" |> to_bool
        }
    | "patch_context" ->
      let+ diff = context_diff_of_json (op_json |> member "diff") in
      Patch_context diff
    | "replace_mcp_sessions" ->
      let+ sessions = Mcp_session.info_list_of_json (op_json |> member "mcp_sessions") in
      Replace_mcp_sessions sessions
    | "replace_pending_input" ->
      let* () = validate_exact_object_fields ~scope:"Checkpoint.delta replace_pending_input"
        ~expected:["kind";"pending_input"] op_json in
      let* pending_input = match op_json |> member "pending_input" with
        | `Null -> Ok None
        | value -> Agent_input_request.pending_of_json value
            |> Result.map Option.some
            |> Result.map_error (fun detail -> Error.Serialization (JsonParseError {detail}))
      in
      Ok (Replace_pending_input pending_input)
    | "replace_working_context" ->
      Ok
        (Replace_working_context
           (match op_json |> member "working_context" with
            | `Null -> None
            | value -> Some value))
    | other ->
      Error
        (Error.Serialization
           (UnknownVariant { type_name = "Checkpoint.delta_op"; value = other }))
  in
  try
    let+ operations =
      json |> member "operations" |> to_list |> List.map op_of_json |> result_all
    in
    { delta_version = json |> member "delta_version" |> to_int
    ; base_checkpoint_version = json |> member "base_checkpoint_version" |> to_int
    ; base_checkpoint_hash = json |> member "base_checkpoint_hash" |> to_string
    ; result_checkpoint_hash = json |> member "result_checkpoint_hash" |> to_string
    ; created_at = json |> member "created_at" |> to_float
    ; operations
    }
  with
  | Yojson.Safe.Util.Type_error (msg, _) ->
    Error
      (Error.Serialization
         (JsonParseError { detail = Printf.sprintf "Checkpoint.delta_of_json: %s" msg }))
  | Yojson.Json_error msg ->
    Error
      (Error.Serialization
         (JsonParseError { detail = Printf.sprintf "Checkpoint.delta_of_json: %s" msg }))
;;

let to_json cp = validated_checkpoint_json_exn ~scope:"Checkpoint.to_json" cp

let checkpoint_json_version = function
  | `Assoc fields ->
    let versions =
      List.filter_map
        (fun (name, value) -> if String.equal name "version" then Some value else None)
        fields
    in
    (match versions with
     | [ `Int version ] -> Ok version
     | [ _ ] ->
       Error
         (Error.Serialization
            (JsonParseError { detail = "Checkpoint version must be an integer" }))
     | [] ->
       Error
         (Error.Serialization
            (JsonParseError { detail = "Checkpoint is missing version" }))
     | _ ->
       Error
         (Error.Serialization
            (JsonParseError { detail = "Checkpoint duplicates field version" })))
  | _ ->
    Error
      (Error.Serialization
         (JsonParseError { detail = "Checkpoint must be a JSON object" }))
;;

let of_json json =
  let* version = checkpoint_json_version json in
  if version = checkpoint_version
  then decode_current_json json
  else
    Error
      (Error.Serialization
         (VersionMismatch { expected = checkpoint_version; got = version }))
;;

let to_string cp = to_json cp |> Yojson.Safe.to_string

(* Saves of one checkpoint lineage write a growing message list whose records
   stay the same objects: [Agent_checkpoint.build_checkpoint] takes
   [state.messages] as is, and the pipeline appends with [Util.snoc]. The memo
   keeps each message's validated encoding under that physical identity, so a
   save encodes, validates, and round-trips only the messages the previous save
   did not write. Identity rather than [Types.Message_value.equal]: the bytes
   are durable, and value equality takes [0.0] and [-0.0] for one key. A record
   rebuilt elsewhere misses and is encoded again. *)
module Encoded_messages = Hashtbl.Make (struct
    type t = Types.message

    let equal = ( == )
    let hash = Types.Message_value.hash
  end)

(* The validated bytes one message is written as, and the message those bytes
   decode to. A load decodes the same bytes, so [decoded] is the record the
   load gives, which can differ from the record that was saved: the wire does
   not carry [ToolResult.json]. *)
type encoded_message =
  { bytes : string
  ; decoded : Types.message
  }

type encoding_memo = { mutable entries : encoded_message Encoded_messages.t }

let create_encoding_memo () = { entries = Encoded_messages.create 0 }

let decode_written_bytes ~decode bytes =
  try decode (Yojson.Safe.from_string bytes) with
  | Yojson.Safe.Util.Type_error (msg, _) | Yojson.Json_error msg | Failure msg ->
    Error
      (Error.Serialization
         (JsonParseError { detail = Printf.sprintf "Checkpoint.of_json: %s" msg }))
;;

(* The passes [checkpoint_json_result] runs over the whole checkpoint,
   restricted to one message: encode, [Execution_json.validate], the v12
   message contract, and a decode. None of them reads past the message's own
   subtree ([Checkpoint_contract.validate_messages] maps
   [validate_message] over the array; [Execution_json.validate] checks keys and
   numbers inside each object), so a message that passes here passes inside any
   checkpoint. The decode reads the written bytes, with the handlers of
   [decode_current_json]. *)
let validated_message_encoding ~message_index message =
  let json = message_to_json message in
  let* () = validate_checkpoint_json ~context:"Checkpoint v12" json in
  let* _ = Checkpoint_contract.validate_message message_index json in
  let bytes = Yojson.Safe.to_string json in
  let+ decoded = decode_written_bytes ~decode:message_of_json bytes in
  { bytes; decoded }
;;

(* The header passes: the checkpoint with an empty message array goes through
   the same whole-object validation as [checkpoint_json_result], and the decode
   reads the bytes the header is written as. *)
let validated_fields_around_messages cp =
  let before_messages, after_messages = checkpoint_fields_around_messages cp in
  let header =
    `Assoc (before_messages @ ((messages_field, `List []) :: after_messages))
  in
  let* () = validate_checkpoint_json ~context:"Checkpoint v12" header in
  let+ decoded_header =
    decode_written_bytes ~decode:decode_current_json (Yojson.Safe.to_string header)
  in
  (before_messages, after_messages), decoded_header
;;

let separated separator = function
  | [] -> []
  | first :: rest -> first :: List.concat_map (fun item -> [ separator; item ]) rest
;;

(* [Yojson.Safe.to_string] writes an object as [{"k":v,...}] and an array as
   [[v,...]] with no whitespace, so these pieces concatenate to [to_string cp].
   They stay a list: the live canonical checkpoints measured 2026-09-16 were
   111MB and 107MB, and the writer appends the pieces to the file in order, so
   joining them here would allocate that whole document a second time on every
   save. *)
let encoded_checkpoint_pieces ~before_messages ~after_messages messages =
  let key name = Yojson.Safe.to_string (`String name) in
  let field (name, value) = [ key name; ":"; Yojson.Safe.to_string value ] in
  let messages_member =
    (key messages_field :: ":[" :: separated "," messages) @ [ "]" ]
  in
  let members =
    List.map field before_messages @ (messages_member :: List.map field after_messages)
  in
  ("{" :: List.concat (separated [ "," ] members)) @ [ "}" ]
;;

(* The decoded checkpoint is what [of_string] gives for the concatenated
   pieces: the header decoded from its own bytes and each message from its
   own. [decode_current_json] decodes field by field and maps
   [message_of_json] over the array, so the parts decode as the whole document
   does. *)
let to_pieces_with_encoding_memo memo (cp : Checkpoint_types.t) =
  let next = Encoded_messages.create (List.length cp.messages) in
  let rec encode_messages message_index rev_encoded = function
    | [] -> Ok (List.rev rev_encoded)
    | message :: rest ->
      let encoding =
        match Encoded_messages.find_opt memo.entries message with
        | Some encoded -> Ok encoded
        | None -> validated_message_encoding ~message_index message
      in
      (match encoding with
       | Error _ as error -> error
       | Ok encoded ->
         Encoded_messages.replace next message encoded;
         (* A save that starts from the decoded checkpoint passes these. *)
         Encoded_messages.replace next encoded.decoded encoded;
         encode_messages (message_index + 1) (encoded :: rev_encoded) rest)
  in
  match
    let* fields = validated_fields_around_messages cp in
    let+ messages = encode_messages 0 [] cp.messages in
    fields, messages
  with
  | Ok (((before_messages, after_messages), decoded_header), messages) ->
    memo.entries <- next;
    ( encoded_checkpoint_pieces
        ~before_messages
        ~after_messages
        (List.map (fun encoded -> encoded.bytes) messages)
    , Some
        { decoded_header with
          messages = List.map (fun encoded -> encoded.decoded) messages
        } )
  | Error _ ->
    (* A refusal is reported by the whole-checkpoint encoder, whose message
       names the failing path inside the checkpoint. *)
    ( [ Yojson.Safe.to_string
          (validated_checkpoint_json_exn
             ~scope:"Checkpoint.to_pieces_with_encoding_memo"
             cp)
      ]
    , None )
;;

(* Two trees print to the same bytes when they are the same tree: floats by
   their bits, object fields in their order. Trees that print alike but differ
   here, an [`Intlit] and an [`Int] of one number, count as different. *)
let rec same_printed_json (left : Yojson.Safe.t) (right : Yojson.Safe.t) =
  match left, right with
  | `Null, `Null -> true
  | `Bool left, `Bool right -> Bool.equal left right
  | `Int left, `Int right -> Int.equal left right
  | `Intlit left, `Intlit right -> String.equal left right
  | `Float left, `Float right ->
    Int64.equal (Int64.bits_of_float left) (Int64.bits_of_float right)
  | `String left, `String right -> String.equal left right
  | `List left, `List right -> List.equal same_printed_json left right
  | `Assoc left, `Assoc right ->
    List.equal
      (fun (left_key, left_value) (right_key, right_value) ->
         String.equal left_key right_key && same_printed_json left_value right_value)
      left
      right
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _), _ ->
    false
;;

(* A read message is held only when the save's own encoding of it, with the
   save's checks, is the document's JSON for it. The held bytes are then what
   a save writes for the record, and [decoded] is what [of_string] gives for
   them. A document an older build or another writer produced can carry other
   bytes for the same message -- fields in another order, text the encoder
   sanitizes -- and such a message is left for the save to encode. *)
let held_read_message ~message_index message json =
  match
    let encoded = message_to_json message in
    let* () = validate_checkpoint_json ~context:"Checkpoint v12" encoded in
    let+ _ = Checkpoint_contract.validate_message message_index encoded in
    encoded
  with
  | Ok encoded when same_printed_json encoded json -> Some (Yojson.Safe.to_string encoded)
  | Ok _ | Error _ -> None
;;

(* [of_json] maps [message_of_json] over the [messages] array in order, so the
   decoded messages and the array's elements pair one to one. *)
let of_string_with_encoding_memo s =
  match Yojson.Safe.from_string s with
  | exception Yojson.Json_error msg ->
    Error
      (Error.Serialization
         (JsonParseError { detail = Printf.sprintf "Invalid JSON: %s" msg }))
  | json ->
    let+ cp = of_json json in
    let memo = create_encoding_memo () in
    let rec hold message_index messages message_jsons =
      match messages, message_jsons with
      | message :: messages, message_json :: message_jsons ->
        (match held_read_message ~message_index message message_json with
         | Some bytes ->
           Encoded_messages.replace memo.entries message { bytes; decoded = message }
         | None -> ());
        hold (message_index + 1) messages message_jsons
      | [], [] | [], _ :: _ | _ :: _, [] -> ()
    in
    (match Yojson.Safe.Util.member messages_field json with
     | `List message_jsons -> hold 0 cp.messages message_jsons
     | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ -> ());
    cp, memo
;;

let of_string s =
  try
    let json = Yojson.Safe.from_string s in
    of_json json
  with
  | Yojson.Json_error msg ->
    Error
      (Error.Serialization
         (JsonParseError { detail = Printf.sprintf "Invalid JSON: %s" msg }))
;;
