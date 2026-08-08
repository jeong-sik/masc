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
  | `Assoc fields when List.mem_assoc "unpriced_model" fields ->
    Error
      (Error.Serialization
         (JsonParseError
            { detail = "Checkpoint.usage_of_json: legacy unpriced_model is not supported"
            }))
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

let rec checkpoint_content_block_to_json block =
  let wire_json =
    match block with
    | ToolResult { content_blocks = Some blocks; _ } ->
      (match Llm_provider.Api_common.content_block_to_json block with
       | `Assoc fields ->
         `Assoc
           (List.map
              (fun (name, value) ->
                 if String.equal name "content"
                 then name, `List (List.map checkpoint_content_block_to_json blocks)
                 else name, value)
              fields)
       | non_object -> non_object)
    | ToolResult { content_blocks = None; _ }
    | Text _
    | Thinking _
    | ReasoningDetails _
    | RedactedThinking _
    | ToolUse _
    | Image _
    | Document _
    | Audio _ -> Llm_provider.Api_common.content_block_to_json block
  in
  match block, wire_json with
  | ToolResult { outcome; _ }, `Assoc fields ->
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
    `Assoc (fields @ provenance)
  | ( ( Text _
      | Thinking _
      | ReasoningDetails _
      | RedactedThinking _
      | ToolUse _
      | Image _
      | Document _
      | Audio _ )
    , _ ) -> wire_json
  | ToolResult _, non_object ->
    invalid_arg
      (Printf.sprintf
         "Checkpoint ToolResult serializer invariant failed: expected object, got %s"
         (Yojson.Safe.to_string non_object))
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
    match Llm_provider.Api_common.content_block_of_json json with
    | Some
        (ToolResult
           { tool_use_id
           ; content
           ; outcome = wire_outcome
           ; json = parsed_json
           ; content_blocks = _
           }) ->
      let* fields = tool_result_fields json in
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
        (ToolResult { tool_use_id; content; outcome; json = parsed_json; content_blocks })
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
    | Some block -> Ok block
    | None ->
      let open Yojson.Safe.Util in
      let block_type =
        json |> member "type" |> to_string_option |> Option.value ~default:"<missing>"
      in
      Error
        (Error.Serialization
           (JsonParseError
              { detail = Printf.sprintf "Unknown content block type: %s" block_type }))
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

let message_to_json (msg : Types.message) =
  let base_fields =
    [ "role", `String (Types.role_to_string msg.role)
    ; "content", `List (List.map checkpoint_content_block_to_json msg.content)
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

let checkpoint_to_json cp =
  `Assoc
    [ "version", `Int cp.version
    ; "session_id", `String cp.session_id
    ; "agent_name", `String cp.agent_name
    ; "model", model_to_yojson cp.model
    ; "system_prompt", Util.json_of_string_opt cp.system_prompt
    ; "messages", `List (List.map message_to_json cp.messages)
    ; "usage", usage_to_json cp.usage
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
    ; "thinking_budget", Util.json_of_int_opt cp.thinking_budget
    ; "reasoning_effort", reasoning_effort_option_to_json cp.reasoning_effort
    ; "disable_parallel_tool_use", `Bool cp.disable_parallel_tool_use
    ; "cache_system_prompt", `Bool cp.cache_system_prompt
    ; "context", Context.to_json cp.context
    ; "mcp_sessions", Mcp_session.info_list_to_json cp.mcp_sessions
    ; "working_context", Option.value ~default:`Null cp.working_context
    ]
;;

let validate_checkpoint cp =
  Checkpoint_v10_contract.validate_v10_json (checkpoint_to_json cp)
;;

let validated_checkpoint_json_exn ~scope cp =
  let json = checkpoint_to_json cp in
  match Checkpoint_v10_contract.validate_v10_json json with
  | Ok () -> json
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
        ; "thinking_budget", Util.json_of_int_opt patch.thinking_budget
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
        ; thinking_budget = op_json |> member "thinking_budget" |> to_int_option
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

let decode_current_json json =
  try
    let open Yojson.Safe.Util in
    let* () = Checkpoint_v10_contract.validate_v10_json json in
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
      match json |> member "context" with
      | `Assoc _ as value -> Ok (Context.of_json value)
      | _ ->
        Error
          (Error.Serialization
             (JsonParseError
                { detail = "Checkpoint.of_json: context must be a JSON object" }))
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
      ; thinking_budget = json |> member "thinking_budget" |> to_int_option
      ; reasoning_effort
      ; cache_system_prompt = json |> member "cache_system_prompt" |> to_bool
      ; context
      ; mcp_sessions
      ; working_context
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
