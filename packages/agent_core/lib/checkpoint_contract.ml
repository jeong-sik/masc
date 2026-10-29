(** Exact validator for the current checkpoint persistence schema. All fields,
    including pending input ownership, are explicit; no converter or inferred
    empty pending state is admitted. *)

open Result_syntax

let target_version = Checkpoint_types.checkpoint_version

(* A scope names where a value sits, for an error message. Validation builds
   it as a chain of small nodes and spells it out only for a value that fails:
   a checkpoint carrying a reasoning block's token-sized details holds hundreds
   of thousands of elements, and a scope string for each of them was much of
   what decoding one allocated. *)
type scope =
  | Root of string
  | Suffix of scope * string
  | Index of scope * string * int

let rec scope_to_string = function
  | Root name -> name
  | Suffix (parent, suffix) -> scope_to_string parent ^ suffix
  | Index (parent, label, index) ->
    Printf.sprintf "%s%s[%d]" (scope_to_string parent) label index
;;

let checkpoint_scope = Root (Printf.sprintf "Checkpoint v%d" target_version)

(* The error names the scope, then says what is wrong with the value there. *)
let scope_errorf scope format =
  Printf.ksprintf
    (fun rest ->
       Error
         (Error.Serialization (JsonParseError { detail = scope_to_string scope ^ rest })))
    format
;;

(* The first element that fails ends the walk, as the per-element results
   folded together did, without building a result list. *)
let validate_each ~scope ~label validate values =
  let rec loop index = function
    | [] -> Ok ()
    | value :: rest ->
      let* _ = validate ~scope:(Index (scope, label, index)) value in
      loop (index + 1) rest
  in
  loop 0 values
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

(* Objects this small are checked for a repeated name pair by pair, which
   allocates nothing; a larger one sorts its names. *)
let pairwise_duplicate_scan_limit = 16

let has_duplicate_name fields =
  let rec pairwise = function
    | [] -> false
    | (name, _) :: rest ->
      List.exists (fun (other, _) -> String.equal name other) rest || pairwise rest
  in
  if List.compare_length_with fields pairwise_duplicate_scan_limit <= 0
  then pairwise fields
  else not (List.is_empty (duplicate_names (List.map fst fields)))
;;

(* The mismatch lists are built only for an object that has one. *)
let object_shape_holds ~required ~optional fields =
  List.for_all (fun name -> List.mem_assoc name fields) required
  && List.for_all
       (fun (name, _) -> List.mem name required || List.mem name optional)
       fields
  && not (has_duplicate_name fields)
;;

let validate_object_shape ~scope ~required ~optional = function
  | `Assoc fields when object_shape_holds ~required ~optional fields -> Ok fields
  | `Assoc fields ->
    let names = List.map fst fields in
    let duplicates = duplicate_names names in
    let missing = List.filter (fun name -> not (List.mem name names)) required in
    let expected = required @ optional in
    let unknown = List.filter (fun name -> not (List.mem name expected)) names in
    if duplicates = [] && missing = [] && unknown = []
    then Ok fields
    else
      scope_errorf
        scope
        " schema mismatch (missing=[%s], unknown=[%s], duplicate=[%s])"
        (String.concat "," missing)
        (String.concat "," unknown)
        (String.concat "," duplicates)
  | _ -> scope_errorf scope " must be a JSON object"
;;

let required_field ~scope name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> scope_errorf scope " is missing field %s" name
;;

let validate_string ~scope = function
  | `String _ -> Ok ()
  | _ -> scope_errorf scope " must be a string"
;;

let validate_bool ~scope = function
  | `Bool _ -> Ok ()
  | _ -> scope_errorf scope " must be a boolean"
;;

let validate_int ~scope = function
  | `Int _ -> Ok ()
  | _ -> scope_errorf scope " must be an integer"
;;

let validate_float ~scope = function
  | `Float _ -> Ok ()
  | _ -> scope_errorf scope " must be a float"
;;

let validate_optional ~scope validate = function
  | `Null -> Ok ()
  | value -> validate ~scope value
;;

let validate_string_value ~scope ~allowed = function
  | `String value when List.mem value allowed -> Ok ()
  | `String value -> scope_errorf scope " has unsupported value %S" value
  | _ -> scope_errorf scope " must be a string"
;;

let validate_list ~scope validate = function
  | `List values ->
    validate_each ~scope ~label:"" validate values
  | _ -> scope_errorf scope " must be an array"
;;

let validate_unique_object ~scope = function
  | `Assoc fields when not (has_duplicate_name fields) -> Ok ()
  | `Assoc fields ->
    let duplicates = duplicate_names (List.map fst fields) in
    if duplicates = []
    then Ok ()
    else scope_errorf scope " duplicates fields [%s]" (String.concat "," duplicates)
  | _ -> scope_errorf scope " must be a JSON object"
;;

let validate_env_pair ~scope json =
  let* fields =
    validate_object_shape ~scope ~required:[ "key"; "value" ] ~optional:[] json
  in
  let* key = required_field ~scope "key" fields in
  let* value = required_field ~scope "value" fields in
  let* () = validate_string ~scope:(Suffix (scope, ".key")) key in
  validate_string ~scope:(Suffix (scope, ".value")) value
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
  let* () = validate_string ~scope:(Suffix (scope, ".name")) name in
  let* () = validate_string ~scope:(Suffix (scope, ".description")) description in
  let* () =
    validate_string_value
      ~scope:(Suffix (scope, ".param_type"))
      ~allowed:[ "string"; "integer"; "number"; "boolean"; "array"; "object" ]
      param_type
  in
  validate_bool ~scope:(Suffix (scope, ".required")) required
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
  let* () = validate_string ~scope:(Suffix (scope, ".name")) name in
  let* () = validate_string ~scope:(Suffix (scope, ".description")) description in
  let* () =
    validate_list ~scope:(Suffix (scope, ".parameters")) validate_tool_param parameters
  in
  let* () =
    match List.assoc_opt "strict" fields with
    | None -> Ok ()
    | Some strict -> validate_bool ~scope:(Suffix (scope, ".strict")) strict
  in
  (* The authoritative tool argument schema is carried verbatim; only its
     outer shape is contracted here, since its body is provider JSON Schema. *)
  match List.assoc_opt "input_schema" fields with
  | None -> Ok ()
  | Some input_schema ->
    validate_unique_object ~scope:(Suffix (scope, ".input_schema")) input_schema
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
       validate_string ~scope:(Suffix (scope, ".name")) name
     | [ `String value ] -> scope_errorf scope " has unsupported type %S" value
     | [ _ ] -> scope_errorf scope ".type must be a string"
     | [] -> scope_errorf scope " is missing field type"
     | _ -> scope_errorf scope " duplicates field type")
  | _ -> scope_errorf scope " must be null or a JSON object"
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
        | `Null -> scope_errorf scope ".schema must not be null"
        | _ -> Ok ())
     | [ `String value ] -> scope_errorf scope " has unsupported type %S" value
     | [ _ ] -> scope_errorf scope ".type must be a string"
     | [] -> scope_errorf scope " is missing field type"
     | _ -> scope_errorf scope " duplicates field type")
  | _ -> scope_errorf scope " must be a JSON object"
;;

let current_checkpoint_fields =
  [ "version"
  ; "session_id"
  ; "agent_name"
  ; "model"
  ; "provider_binding"
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
  ; "reasoning_effort"
  ; "disable_parallel_tool_use"
  ; "cache_system_prompt"
  ; "context"
  ; "mcp_sessions"
  ; "working_context"
  ; "pending_input"
  ]
;;

let usage_number_fields =
  [ "total_input_tokens"
  ; "total_output_tokens"
  ; "total_cache_creation_input_tokens"
  ; "total_cache_read_input_tokens"
  ; "api_calls"
  ; "missing_usage_responses"
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
  let* () =
    validate_int ~scope:(Suffix (scope, ".total_input_tokens")) total_input_tokens
  in
  let* () =
    validate_int ~scope:(Suffix (scope, ".total_output_tokens")) total_output_tokens
  in
  let* () =
    validate_int
      ~scope:(Suffix (scope, ".total_cache_creation_input_tokens"))
      total_cache_creation_input_tokens
  in
  let* () =
    validate_int
      ~scope:(Suffix (scope, ".total_cache_read_input_tokens"))
      total_cache_read_input_tokens
  in
  let* () = validate_int ~scope:(Suffix (scope, ".api_calls")) api_calls in
  validate_float ~scope:(Suffix (scope, ".estimated_cost_usd")) estimated_cost_usd
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
     | [ `String "usage_not_reported" ]
     | [ `String "model_identity_unavailable" ] ->
       validate_object_shape ~scope ~required:[ "kind" ] ~optional:[] json
       |> Result.map (fun _ -> ())
     | [ `String "pricing_unavailable" ] ->
       let* fields =
         validate_object_shape ~scope ~required:[ "kind"; "model_id" ] ~optional:[] json
       in
       let* model_id = required_field ~scope "model_id" fields in
       (match model_id with
        | `String "" -> scope_errorf scope ".model_id must not be empty"
        | `String _ -> Ok ()
        | _ -> scope_errorf scope ".model_id must be a string")
     | [ `String value ] -> scope_errorf scope " has unsupported kind %S" value
     | [ _ ] -> scope_errorf scope ".kind must be a string"
     | [] -> scope_errorf scope " is missing field kind"
     | _ -> scope_errorf scope " duplicates field kind")
  | _ -> scope_errorf scope " must be null or a JSON object"
;;

let validate_current_usage json =
  let scope = Suffix (checkpoint_scope, " usage") in
  let* fields =
    validate_object_shape ~scope ~required:current_usage_fields ~optional:[] json
  in
  let* () = validate_usage_numbers ~scope fields in
  let* pricing_gap = required_field ~scope "pricing_gap" fields in
  let* () = validate_pricing_gap ~scope:(Suffix (scope, ".pricing_gap")) pricing_gap in
  let* api_calls = required_field ~scope "api_calls" fields in
  let* missing = required_field ~scope "missing_usage_responses" fields in
  match api_calls, missing with
  | `Int total, `Int missing when total >= 0 && missing >= 0 && missing <= total ->
    if missing > 0 && pricing_gap = `Null then
      scope_errorf scope " missing usage responses require a cost-gap diagnostic"
    else Ok ()
  | `Int _, `Int _ ->
    scope_errorf scope " requires 0 <= missing_usage_responses <= api_calls"
  | _, _ -> scope_errorf scope " response coverage counts must be integers"
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
  | `String value -> scope_errorf scope " has unsupported value %S" value
  | _ -> scope_errorf scope " must be a string"
;;

let validate_mcp_session ~scope json =
  let* fields =
    validate_object_shape ~scope ~required:mcp_session_http_fields ~optional:[] json
  in
  let* server_name = required_field ~scope "server_name" fields in
  let* command = required_field ~scope "command" fields in
  let* args = required_field ~scope "args" fields in
  let* env = required_field ~scope "env" fields in
  let* tool_schemas = required_field ~scope "tool_schemas" fields in
  let* transport_kind = required_field ~scope "transport_kind" fields in
  let* () = validate_string ~scope:(Suffix (scope, ".server_name")) server_name in
  let* () = validate_string ~scope:(Suffix (scope, ".command")) command in
  let* () = validate_list ~scope:(Suffix (scope, ".args")) validate_string args in
  let* () = validate_list ~scope:(Suffix (scope, ".env")) validate_env_pair env in
  let* () =
    validate_list
      ~scope:(Suffix (scope, ".tool_schemas"))
      validate_tool_schema tool_schemas
  in
  let* transport_kind =
    transport_kind_of_json ~scope:(Suffix (scope, ".transport_kind")) transport_kind
  in
  let* http_base_url = required_field ~scope "http_base_url" fields in
  let* http_headers = required_field ~scope "http_headers" fields in
  let* () =
    validate_optional
      ~scope:(Suffix (scope, ".http_base_url"))
      validate_string http_base_url
  in
  let* () =
    validate_list ~scope:(Suffix (scope, ".http_headers")) validate_env_pair http_headers
  in
  match transport_kind, http_base_url with
  | `Http, `Null -> scope_errorf scope " HTTP transport requires http_base_url"
  | (`Http | `Stdio), _ -> Ok json
;;

let validate_mcp_sessions = function
  | `List sessions ->
    validate_each
      ~scope:checkpoint_scope
      ~label:" mcp_sessions"
      validate_mcp_session
      sessions
  | _ -> scope_errorf checkpoint_scope " mcp_sessions must be an array"
;;

let validate_common_checkpoint_fields ~scope fields =
  let* session_id = required_field ~scope "session_id" fields in
  let* agent_name = required_field ~scope "agent_name" fields in
  let* model = required_field ~scope "model" fields in
  let* provider_binding = required_field ~scope "provider_binding" fields in
  let* () = match provider_binding with
    | `Null -> Ok ()
    | value -> (match Llm_provider.Types.Reasoning_source.of_yojson value with
      | Ok _ -> Ok ()
      | Error detail -> scope_errorf scope ".provider_binding: %s" detail)
  in
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
  let* disable_parallel_tool_use =
    required_field ~scope "disable_parallel_tool_use" fields
  in
  let* cache_system_prompt = required_field ~scope "cache_system_prompt" fields in
  let* context = required_field ~scope "context" fields in
  let* () = validate_string ~scope:(Suffix (scope, ".session_id")) session_id in
  let* () = validate_string ~scope:(Suffix (scope, ".agent_name")) agent_name in
  let* () = validate_string ~scope:(Suffix (scope, ".model")) model in
  let* () =
    validate_optional
      ~scope:(Suffix (scope, ".system_prompt"))
      validate_string system_prompt
  in
  let* () = validate_int ~scope:(Suffix (scope, ".turn_count")) turn_count in
  let* () = validate_float ~scope:(Suffix (scope, ".created_at")) created_at in
  let* () = validate_list ~scope:(Suffix (scope, ".tools")) validate_tool_schema tools in
  let* () = validate_tool_choice ~scope:(Suffix (scope, ".tool_choice")) tool_choice in
  let* () =
    validate_optional ~scope:(Suffix (scope, ".temperature")) validate_float temperature
  in
  let* () = validate_optional ~scope:(Suffix (scope, ".top_p")) validate_float top_p in
  let* () = validate_optional ~scope:(Suffix (scope, ".top_k")) validate_int top_k in
  let* () = validate_optional ~scope:(Suffix (scope, ".min_p")) validate_float min_p in
  let* () =
    validate_optional
      ~scope:(Suffix (scope, ".enable_thinking"))
      validate_bool enable_thinking
  in
  let* () =
    validate_optional
      ~scope:(Suffix (scope, ".preserve_thinking"))
      validate_bool
      preserve_thinking
  in
  let* () =
    validate_response_format ~scope:(Suffix (scope, ".response_format")) response_format
  in
  let* () =
    validate_bool
      ~scope:(Suffix (scope, ".disable_parallel_tool_use"))
      disable_parallel_tool_use
  in
  let* () =
    validate_bool ~scope:(Suffix (scope, ".cache_system_prompt")) cache_system_prompt
  in
  validate_unique_object ~scope:(Suffix (scope, ".context")) context
;;

let validate_json json =
  let scope = checkpoint_scope in
  let* fields =
    validate_object_shape ~scope ~required:current_checkpoint_fields ~optional:[] json
  in
  let* version = required_field ~scope "version" fields in
  let* () =
    match version with
    | `Int version when version = target_version -> Ok ()
    | `Int version ->
      scope_errorf scope " has version %d, expected %d" version target_version
    | _ -> scope_errorf scope " version must be an integer"
  in
  let* () = validate_common_checkpoint_fields ~scope fields in
  let* usage = required_field ~scope "usage" fields in
  let* () = validate_current_usage usage in
  let* mcp_sessions = required_field ~scope "mcp_sessions" fields in
  let* _ = validate_mcp_sessions mcp_sessions in
  let* pending_input = required_field ~scope "pending_input" fields in
  let* () = match pending_input with
    | `Null -> Ok ()
    | json -> (match Agent_input_request.pending_of_json json with
       | Ok _ -> Ok ()
       | Error detail -> scope_errorf scope ".pending_input: %s" detail)
  in
  let* reasoning_effort = required_field ~scope "reasoning_effort" fields in
  validate_optional
    ~scope:(Suffix (scope, ".reasoning_effort"))
    (validate_string_value ~allowed:Llm_provider.Reasoning_effort.all_wire_values)
    reasoning_effort
;;
