(** Exact validator for the current checkpoint-v10 persistence schema. *)

open Result_syntax

let target_version = Checkpoint_types.checkpoint_version
let checkpoint_scope = Printf.sprintf "Checkpoint v%d" target_version

let json_errorf format =
  Printf.ksprintf
    (fun detail -> Error (Error.Serialization (JsonParseError { detail })))
    format
;;

let result_all items =
  List.fold_left
    (fun acc item ->
       let* values = acc in
       let* value = item in
       Ok (value :: values))
    (Ok [])
    items
  |> Result.map List.rev
;;

let duplicate_names names =
  names
  |> List.sort String.compare
  |> List.fold_left
       (fun (previous, duplicates) name ->
          match previous with
          | Some previous when String.equal previous name -> Some name, name :: duplicates
          | Some _ | None -> Some name, duplicates)
       (None, [])
  |> snd
  |> List.sort_uniq String.compare
;;

let validate_object_shape ~scope ~required ~optional = function
  | `Assoc fields ->
    let names = List.map fst fields in
    let duplicates = duplicate_names names in
    let missing = List.filter (fun name -> not (List.mem name names)) required in
    let expected = required @ optional in
    let unknown = List.filter (fun name -> not (List.mem name expected)) names in
    if duplicates = [] && missing = [] && unknown = []
    then Ok fields
    else
      json_errorf
        "%s schema mismatch (missing=[%s], unknown=[%s], duplicate=[%s])"
        scope
        (String.concat "," missing)
        (String.concat "," unknown)
        (String.concat "," duplicates)
  | _ -> json_errorf "%s must be a JSON object" scope
;;

let required_field ~scope name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> json_errorf "%s is missing field %s" scope name
;;

let validate_string ~scope = function
  | `String _ -> Ok ()
  | _ -> json_errorf "%s must be a string" scope
;;

let validate_bool ~scope = function
  | `Bool _ -> Ok ()
  | _ -> json_errorf "%s must be a boolean" scope
;;

let validate_int ~scope = function
  | `Int _ -> Ok ()
  | _ -> json_errorf "%s must be an integer" scope
;;

let validate_float ~scope = function
  | `Float _ -> Ok ()
  | _ -> json_errorf "%s must be a float" scope
;;

let validate_optional ~scope validate = function
  | `Null -> Ok ()
  | value -> validate ~scope value
;;

let validate_string_value ~scope ~allowed = function
  | `String value when List.mem value allowed -> Ok ()
  | `String value -> json_errorf "%s has unsupported value %S" scope value
  | _ -> json_errorf "%s must be a string" scope
;;

let validate_list ~scope validate = function
  | `List values ->
    values
    |> List.mapi (fun index value ->
      validate ~scope:(Printf.sprintf "%s[%d]" scope index) value)
    |> result_all
    |> Result.map (fun _ -> ())
  | _ -> json_errorf "%s must be an array" scope
;;

let validate_unique_object ~scope = function
  | `Assoc fields ->
    let duplicates = duplicate_names (List.map fst fields) in
    if duplicates = []
    then Ok ()
    else json_errorf "%s duplicates fields [%s]" scope (String.concat "," duplicates)
  | _ -> json_errorf "%s must be a JSON object" scope
;;

let validate_env_pair ~scope json =
  let* fields =
    validate_object_shape ~scope ~required:[ "key"; "value" ] ~optional:[] json
  in
  let* key = required_field ~scope "key" fields in
  let* value = required_field ~scope "value" fields in
  let* () = validate_string ~scope:(scope ^ ".key") key in
  validate_string ~scope:(scope ^ ".value") value
;;

let validate_tool_param ~scope json =
  let* fields =
    validate_object_shape
      ~scope
      ~required:[ "name"; "description"; "param_type"; "required" ]
      ~optional:[]
      json
  in
  let* name = required_field ~scope "name" fields in
  let* description = required_field ~scope "description" fields in
  let* param_type = required_field ~scope "param_type" fields in
  let* required = required_field ~scope "required" fields in
  let* () = validate_string ~scope:(scope ^ ".name") name in
  let* () = validate_string ~scope:(scope ^ ".description") description in
  let* () =
    validate_string_value
      ~scope:(scope ^ ".param_type")
      ~allowed:[ "string"; "integer"; "number"; "boolean"; "array"; "object" ]
      param_type
  in
  validate_bool ~scope:(scope ^ ".required") required
;;

let validate_tool_schema ~scope json =
  let* fields =
    validate_object_shape
      ~scope
      ~required:[ "name"; "description"; "parameters" ]
      ~optional:[ "strict"; "input_schema" ]
      json
  in
  let* name = required_field ~scope "name" fields in
  let* description = required_field ~scope "description" fields in
  let* parameters = required_field ~scope "parameters" fields in
  let* () = validate_string ~scope:(scope ^ ".name") name in
  let* () = validate_string ~scope:(scope ^ ".description") description in
  let* () = validate_list ~scope:(scope ^ ".parameters") validate_tool_param parameters in
  let* () =
    match List.assoc_opt "strict" fields with
    | None -> Ok ()
    | Some strict -> validate_bool ~scope:(scope ^ ".strict") strict
  in
  (* The authoritative tool argument schema is carried verbatim; only its
     outer shape is contracted here, since its body is provider JSON Schema. *)
  match List.assoc_opt "input_schema" fields with
  | None -> Ok ()
  | Some input_schema ->
    validate_unique_object ~scope:(scope ^ ".input_schema") input_schema
;;

let validate_tool_choice ~scope = function
  | `Null -> Ok ()
  | `Assoc fields as json ->
    let type_values =
      List.filter_map
        (fun (name, value) -> if String.equal name "type" then Some value else None)
        fields
    in
    (match type_values with
     | [ `String "auto" ] | [ `String "any" ] | [ `String "none" ] ->
       validate_object_shape ~scope ~required:[ "type" ] ~optional:[] json
       |> Result.map (fun _ -> ())
     | [ `String "tool" ] ->
       let* fields =
         validate_object_shape ~scope ~required:[ "type"; "name" ] ~optional:[] json
       in
       let* name = required_field ~scope "name" fields in
       validate_string ~scope:(scope ^ ".name") name
     | [ `String value ] -> json_errorf "%s has unsupported type %S" scope value
     | [ _ ] -> json_errorf "%s.type must be a string" scope
     | [] -> json_errorf "%s is missing field type" scope
     | _ -> json_errorf "%s duplicates field type" scope)
  | _ -> json_errorf "%s must be null or a JSON object" scope
;;

let validate_response_format ~scope = function
  | `Assoc fields as json ->
    let type_values =
      List.filter_map
        (fun (name, value) -> if String.equal name "type" then Some value else None)
        fields
    in
    (match type_values with
     | [ `String "off" ] | [ `String "json_mode" ] ->
       validate_object_shape ~scope ~required:[ "type" ] ~optional:[] json
       |> Result.map (fun _ -> ())
     | [ `String "json_schema" ] ->
       let* fields =
         validate_object_shape ~scope ~required:[ "type"; "schema" ] ~optional:[] json
       in
       let* schema = required_field ~scope "schema" fields in
       (match schema with
        | `Null -> json_errorf "%s.schema must not be null" scope
        | _ -> Ok ())
     | [ `String value ] -> json_errorf "%s has unsupported type %S" scope value
     | [ _ ] -> json_errorf "%s.type must be a string" scope
     | [] -> json_errorf "%s is missing field type" scope
     | _ -> json_errorf "%s duplicates field type" scope)
  | _ -> json_errorf "%s must be a JSON object" scope
;;

let current_checkpoint_fields =
  [ "version"
  ; "session_id"
  ; "agent_name"
  ; "model"
  ; "system_prompt"
  ; "messages"
  ; "usage"
  ; "turn_count"
  ; "created_at"
  ; "tools"
  ; "tool_choice"
  ; "temperature"
  ; "top_p"
  ; "top_k"
  ; "min_p"
  ; "enable_thinking"
  ; "preserve_thinking"
  ; "response_format"
  ; "thinking_budget"
  ; "reasoning_effort"
  ; "disable_parallel_tool_use"
  ; "cache_system_prompt"
  ; "context"
  ; "mcp_sessions"
  ; "working_context"
  ]
;;

let usage_number_fields =
  [ "total_input_tokens"
  ; "total_output_tokens"
  ; "total_cache_creation_input_tokens"
  ; "total_cache_read_input_tokens"
  ; "api_calls"
  ; "estimated_cost_usd"
  ]
;;

let current_usage_fields = "pricing_gap" :: usage_number_fields

let validate_usage_numbers ~scope fields =
  let* total_input_tokens = required_field ~scope "total_input_tokens" fields in
  let* total_output_tokens = required_field ~scope "total_output_tokens" fields in
  let* total_cache_creation_input_tokens =
    required_field ~scope "total_cache_creation_input_tokens" fields
  in
  let* total_cache_read_input_tokens =
    required_field ~scope "total_cache_read_input_tokens" fields
  in
  let* api_calls = required_field ~scope "api_calls" fields in
  let* estimated_cost_usd = required_field ~scope "estimated_cost_usd" fields in
  let* () = validate_int ~scope:(scope ^ ".total_input_tokens") total_input_tokens in
  let* () = validate_int ~scope:(scope ^ ".total_output_tokens") total_output_tokens in
  let* () =
    validate_int
      ~scope:(scope ^ ".total_cache_creation_input_tokens")
      total_cache_creation_input_tokens
  in
  let* () =
    validate_int
      ~scope:(scope ^ ".total_cache_read_input_tokens")
      total_cache_read_input_tokens
  in
  let* () = validate_int ~scope:(scope ^ ".api_calls") api_calls in
  validate_float ~scope:(scope ^ ".estimated_cost_usd") estimated_cost_usd
;;

let validate_pricing_gap ~scope = function
  | `Null -> Ok ()
  | `Assoc fields as json ->
    let kinds =
      List.filter_map
        (fun (name, value) -> if String.equal name "kind" then Some value else None)
        fields
    in
    (match kinds with
     | [ `String "model_identity_unavailable" ] ->
       validate_object_shape ~scope ~required:[ "kind" ] ~optional:[] json
       |> Result.map (fun _ -> ())
     | [ `String "pricing_unavailable" ] ->
       let* fields =
         validate_object_shape ~scope ~required:[ "kind"; "model_id" ] ~optional:[] json
       in
       let* model_id = required_field ~scope "model_id" fields in
       (match model_id with
        | `String "" -> json_errorf "%s.model_id must not be empty" scope
        | `String _ -> Ok ()
        | _ -> json_errorf "%s.model_id must be a string" scope)
     | [ `String value ] -> json_errorf "%s has unsupported kind %S" scope value
     | [ _ ] -> json_errorf "%s.kind must be a string" scope
     | [] -> json_errorf "%s is missing field kind" scope
     | _ -> json_errorf "%s duplicates field kind" scope)
  | _ -> json_errorf "%s must be null or a JSON object" scope
;;

let validate_current_usage json =
  let scope = checkpoint_scope ^ " usage" in
  let* fields =
    validate_object_shape ~scope ~required:current_usage_fields ~optional:[] json
  in
  let* () = validate_usage_numbers ~scope fields in
  let* pricing_gap = required_field ~scope "pricing_gap" fields in
  validate_pricing_gap ~scope:(scope ^ ".pricing_gap") pricing_gap
;;

let rec validate_tool_result ~scope json =
  let* fields =
    validate_object_shape
      ~scope
      ~required:[ "type"; "tool_use_id"; "content"; "is_error" ]
      ~optional:[ "failure_kind"; "error_class" ]
      json
  in
  let* type_value = required_field ~scope "type" fields in
  let* tool_use_id = required_field ~scope "tool_use_id" fields in
  let* content = required_field ~scope "content" fields in
  let* is_error = required_field ~scope "is_error" fields in
  let* () =
    match type_value with
    | `String "tool_result" -> Ok ()
    | `String value -> json_errorf "%s.type must be tool_result, got %S" scope value
    | _ -> json_errorf "%s.type must be a string" scope
  in
  let* () = validate_string ~scope:(scope ^ ".tool_use_id") tool_use_id in
  let* () =
    match content with
    | `String _ -> Ok ()
    | `List blocks ->
      blocks
      |> List.mapi (fun index block ->
        validate_content_block ~scope:(Printf.sprintf "%s.content[%d]" scope index) block)
      |> result_all
      |> Result.map (fun _ -> ())
    | _ -> json_errorf "%s.content must be a string or an array" scope
  in
  let failure_kind = List.assoc_opt "failure_kind" fields in
  let error_class = List.assoc_opt "error_class" fields in
  let* () =
    match failure_kind with
    | None -> Ok ()
    | Some value ->
      (match Types.tool_failure_kind_of_yojson value with
       | Ok
           ( Types.Validation_error
           | Types.Recoverable_tool_error
           | Types.Non_retryable_tool_error
           | Types.Reported_tool_error
           | Types.Unattributed_tool_error ) -> Ok ()
       | Error _ -> json_errorf "%s.failure_kind is not a supported value" scope)
  in
  let* () =
    match error_class with
    | None -> Ok ()
    | Some value ->
      (match Types.tool_error_class_of_yojson value with
       | Ok (Types.Transient | Types.Deterministic | Types.Unknown) -> Ok ()
       | Error _ -> json_errorf "%s.error_class is not a supported value" scope)
  in
  match is_error, failure_kind, error_class with
  | `Bool true, None, None ->
    json_errorf "%s failure is missing failure_kind provenance" scope
  | `Bool true, Some _, _ -> Ok json
  | `Bool true, None, Some _ ->
    json_errorf "%s has error_class without failure_kind" scope
  | `Bool false, None, None -> Ok json
  | `Bool false, Some _, _ | `Bool false, None, Some _ ->
    json_errorf "%s marks success but contains failure provenance" scope
  | _, _, _ -> json_errorf "%s is_error must be boolean" scope

and validate_content_block ~scope json =
  match json with
  | `Assoc fields ->
    let type_values =
      List.filter_map
        (fun (name, value) -> if String.equal name "type" then Some value else None)
        fields
    in
    (match type_values with
     | [ `String "tool_result" ] -> validate_tool_result ~scope json
     | [ `String "text" ] ->
       let* fields =
         validate_object_shape ~scope ~required:[ "type"; "text" ] ~optional:[] json
       in
       let* text = required_field ~scope "text" fields in
       let+ () = validate_string ~scope:(scope ^ ".text") text in
       json
     | [ `String "thinking" ] ->
       let* fields =
         validate_object_shape
           ~scope
           ~required:[ "type"; "thinking" ]
           ~optional:[ "signature" ]
           json
       in
       let* thinking = required_field ~scope "thinking" fields in
       let* () = validate_string ~scope:(scope ^ ".thinking") thinking in
       let* () =
         match List.assoc_opt "signature" fields with
         | None -> Ok ()
         | Some signature -> validate_string ~scope:(scope ^ ".signature") signature
       in
       Ok json
     | [ `String "reasoning_details" ] ->
       let* fields =
         validate_object_shape
           ~scope
           ~required:[ "type"; "details" ]
           ~optional:[ "reasoning_content" ]
           json
       in
       let* details = required_field ~scope "details" fields in
       let* () =
         validate_list ~scope:(scope ^ ".details") validate_unique_object details
       in
       let* () =
         match List.assoc_opt "reasoning_content" fields with
         | None -> Ok ()
         | Some (`String _) -> Ok ()
         | Some _ -> json_errorf "%s.reasoning_content must be a string" scope
       in
       Ok json
     | [ `String "redacted_thinking" ] ->
       let* fields =
         validate_object_shape ~scope ~required:[ "type"; "data" ] ~optional:[] json
       in
       let* data = required_field ~scope "data" fields in
       let+ () = validate_string ~scope:(scope ^ ".data") data in
       json
     | [ `String "tool_use" ] ->
       let* fields =
         validate_object_shape
           ~scope
           ~required:[ "type"; "id"; "name"; "input" ]
           ~optional:[]
           json
       in
       let* id = required_field ~scope "id" fields in
       let* name = required_field ~scope "name" fields in
       let* () = validate_string ~scope:(scope ^ ".id") id in
       let+ () = validate_string ~scope:(scope ^ ".name") name in
       json
     | [ `String ("image" | "document" | "audio") ] ->
       let* fields =
         validate_object_shape ~scope ~required:[ "type"; "source" ] ~optional:[] json
       in
       let* source = required_field ~scope "source" fields in
       let* source_fields =
         validate_object_shape
           ~scope:(scope ^ ".source")
           ~required:[ "type"; "media_type"; "data" ]
           ~optional:[]
           source
       in
       let* source_type =
         required_field ~scope:(scope ^ ".source") "type" source_fields
       in
       let* media_type =
         required_field ~scope:(scope ^ ".source") "media_type" source_fields
       in
       let* data = required_field ~scope:(scope ^ ".source") "data" source_fields in
       let* () =
         validate_string_value
           ~scope:(scope ^ ".source.type")
           ~allowed:[ "base64"; "url"; "file_id" ]
           source_type
       in
       let* () = validate_string ~scope:(scope ^ ".source.media_type") media_type in
       let+ () = validate_string ~scope:(scope ^ ".source.data") data in
       json
     | [ `String value ] -> json_errorf "%s has unsupported type %S" scope value
     | [ _ ] -> json_errorf "%s type must be a string" scope
     | [] -> json_errorf "%s is missing field type" scope
     | _ -> json_errorf "%s duplicates field type" scope)
  | _ -> json_errorf "%s must be a JSON object" scope
;;

let validate_message index json =
  let scope = Printf.sprintf "%s message[%d]" checkpoint_scope index in
  let* fields =
    validate_object_shape
      ~scope
      ~required:[ "role"; "content" ]
      ~optional:[ "name"; "tool_call_id"; "metadata" ]
      json
  in
  let* role = required_field ~scope "role" fields in
  let* content = required_field ~scope "content" fields in
  let* role =
    match role with
    | `String (("system" | "user" | "assistant" | "tool") as role) -> Ok role
    | `String role -> json_errorf "%s.role has unsupported value %S" scope role
    | _ -> json_errorf "%s.role must be a string" scope
  in
  let* () =
    match List.assoc_opt "name" fields with
    | None -> Ok ()
    | Some name -> validate_string ~scope:(scope ^ ".name") name
  in
  let* () =
    match List.assoc_opt "tool_call_id" fields with
    | None -> Ok ()
    | Some tool_call_id -> validate_string ~scope:(scope ^ ".tool_call_id") tool_call_id
  in
  let* () =
    match List.assoc_opt "metadata" fields with
    | None -> Ok ()
    | Some (`Assoc []) ->
      json_errorf "%s.metadata must be omitted when it has no fields" scope
    | Some metadata -> validate_unique_object ~scope:(scope ^ ".metadata") metadata
  in
  match content with
  | `List blocks ->
    let is_tool_result = function
      | `Assoc fields ->
        List.exists
          (fun (name, value) -> String.equal name "type" && value = `String "tool_result")
          fields
      | _ -> false
    in
    let has_tool_result = List.exists is_tool_result blocks in
    let* () =
      match role, blocks, has_tool_result with
      | "tool", [], _ -> json_errorf "%s role tool requires at least one ToolResult" scope
      | "tool", _, true when List.for_all is_tool_result blocks -> Ok ()
      | "tool", _, _ ->
        json_errorf "%s role tool may contain only ToolResult blocks" scope
      | ("system" | "user" | "assistant"), _, true ->
        json_errorf "%s ToolResult requires role tool" scope
      | ("system" | "user" | "assistant"), _, false -> Ok ()
      | _ -> json_errorf "%s has an unsupported role/content combination" scope
    in
    let* _ =
      blocks
      |> List.mapi (fun block_index block ->
        validate_content_block
          ~scope:(Printf.sprintf "%s content[%d]" scope block_index)
          block)
      |> result_all
    in
    Ok json
  | _ -> json_errorf "%s content must be an array" scope
;;

let validate_messages = function
  | `List messages -> messages |> List.mapi validate_message |> result_all
  | _ -> json_errorf "%s messages must be an array" checkpoint_scope
;;

let mcp_session_common_fields =
  [ "server_name"; "command"; "args"; "env"; "tool_schemas"; "transport_kind" ]
;;

let mcp_session_http_fields =
  "http_base_url" :: "http_headers" :: mcp_session_common_fields
;;

let transport_kind_of_json ~scope = function
  | `String "stdio" -> Ok `Stdio
  | `String "http" -> Ok `Http
  | `String value -> json_errorf "%s has unsupported value %S" scope value
  | _ -> json_errorf "%s must be a string" scope
;;

let validate_mcp_session index json =
  let scope = Printf.sprintf "%s mcp_sessions[%d]" checkpoint_scope index in
  let* fields =
    validate_object_shape ~scope ~required:mcp_session_http_fields ~optional:[] json
  in
  let* server_name = required_field ~scope "server_name" fields in
  let* command = required_field ~scope "command" fields in
  let* args = required_field ~scope "args" fields in
  let* env = required_field ~scope "env" fields in
  let* tool_schemas = required_field ~scope "tool_schemas" fields in
  let* transport_kind = required_field ~scope "transport_kind" fields in
  let* () = validate_string ~scope:(scope ^ ".server_name") server_name in
  let* () = validate_string ~scope:(scope ^ ".command") command in
  let* () = validate_list ~scope:(scope ^ ".args") validate_string args in
  let* () = validate_list ~scope:(scope ^ ".env") validate_env_pair env in
  let* () =
    validate_list ~scope:(scope ^ ".tool_schemas") validate_tool_schema tool_schemas
  in
  let* transport_kind =
    transport_kind_of_json ~scope:(scope ^ ".transport_kind") transport_kind
  in
  let* http_base_url = required_field ~scope "http_base_url" fields in
  let* http_headers = required_field ~scope "http_headers" fields in
  let* () =
    validate_optional ~scope:(scope ^ ".http_base_url") validate_string http_base_url
  in
  let* () =
    validate_list ~scope:(scope ^ ".http_headers") validate_env_pair http_headers
  in
  match transport_kind, http_base_url with
  | `Http, `Null -> json_errorf "%s HTTP transport requires http_base_url" scope
  | (`Http | `Stdio), _ -> Ok json
;;

let validate_mcp_sessions = function
  | `List sessions -> sessions |> List.mapi validate_mcp_session |> result_all
  | _ -> json_errorf "%s mcp_sessions must be an array" checkpoint_scope
;;

let validate_common_checkpoint_fields ~scope fields =
  let* session_id = required_field ~scope "session_id" fields in
  let* agent_name = required_field ~scope "agent_name" fields in
  let* model = required_field ~scope "model" fields in
  let* system_prompt = required_field ~scope "system_prompt" fields in
  let* turn_count = required_field ~scope "turn_count" fields in
  let* created_at = required_field ~scope "created_at" fields in
  let* tools = required_field ~scope "tools" fields in
  let* tool_choice = required_field ~scope "tool_choice" fields in
  let* temperature = required_field ~scope "temperature" fields in
  let* top_p = required_field ~scope "top_p" fields in
  let* top_k = required_field ~scope "top_k" fields in
  let* min_p = required_field ~scope "min_p" fields in
  let* enable_thinking = required_field ~scope "enable_thinking" fields in
  let* preserve_thinking = required_field ~scope "preserve_thinking" fields in
  let* response_format = required_field ~scope "response_format" fields in
  let* thinking_budget = required_field ~scope "thinking_budget" fields in
  let* disable_parallel_tool_use =
    required_field ~scope "disable_parallel_tool_use" fields
  in
  let* cache_system_prompt = required_field ~scope "cache_system_prompt" fields in
  let* context = required_field ~scope "context" fields in
  let* () = validate_string ~scope:(scope ^ ".session_id") session_id in
  let* () = validate_string ~scope:(scope ^ ".agent_name") agent_name in
  let* () = validate_string ~scope:(scope ^ ".model") model in
  let* () =
    validate_optional ~scope:(scope ^ ".system_prompt") validate_string system_prompt
  in
  let* () = validate_int ~scope:(scope ^ ".turn_count") turn_count in
  let* () = validate_float ~scope:(scope ^ ".created_at") created_at in
  let* () = validate_list ~scope:(scope ^ ".tools") validate_tool_schema tools in
  let* () = validate_tool_choice ~scope:(scope ^ ".tool_choice") tool_choice in
  let* () =
    validate_optional ~scope:(scope ^ ".temperature") validate_float temperature
  in
  let* () = validate_optional ~scope:(scope ^ ".top_p") validate_float top_p in
  let* () = validate_optional ~scope:(scope ^ ".top_k") validate_int top_k in
  let* () = validate_optional ~scope:(scope ^ ".min_p") validate_float min_p in
  let* () =
    validate_optional ~scope:(scope ^ ".enable_thinking") validate_bool enable_thinking
  in
  let* () =
    validate_optional
      ~scope:(scope ^ ".preserve_thinking")
      validate_bool
      preserve_thinking
  in
  let* () =
    validate_response_format ~scope:(scope ^ ".response_format") response_format
  in
  let* () =
    validate_optional ~scope:(scope ^ ".thinking_budget") validate_int thinking_budget
  in
  let* () =
    validate_bool ~scope:(scope ^ ".disable_parallel_tool_use") disable_parallel_tool_use
  in
  let* () = validate_bool ~scope:(scope ^ ".cache_system_prompt") cache_system_prompt in
  validate_unique_object ~scope:(scope ^ ".context") context
;;

let validate_v10_json json =
  let scope = checkpoint_scope in
  let* fields =
    validate_object_shape ~scope ~required:current_checkpoint_fields ~optional:[] json
  in
  let* version = required_field ~scope "version" fields in
  let* () =
    match version with
    | `Int version when version = target_version -> Ok ()
    | `Int version ->
      json_errorf "%s has version %d, expected %d" scope version target_version
    | _ -> json_errorf "%s version must be an integer" scope
  in
  let* () = validate_common_checkpoint_fields ~scope fields in
  let* usage = required_field ~scope "usage" fields in
  let* () = validate_current_usage usage in
  let* messages = required_field ~scope "messages" fields in
  let* _ = validate_messages messages in
  let* mcp_sessions = required_field ~scope "mcp_sessions" fields in
  let* _ = validate_mcp_sessions mcp_sessions in
  let* reasoning_effort = required_field ~scope "reasoning_effort" fields in
  validate_optional
    ~scope:(scope ^ ".reasoning_effort")
    (validate_string_value ~allowed:Llm_provider.Reasoning_effort.all_wire_values)
    reasoning_effort
;;
