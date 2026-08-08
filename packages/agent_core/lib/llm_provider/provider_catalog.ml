(** External provider catalog overlay. *)

module Result_syntax = struct
  let ( let* ) = Result.bind
end

open Result_syntax

type auth_mode =
  | No_auth
  | Api_key_env of string
  | Setup_token_env of string
[@@deriving show]

type entry =
  { id : string
  ; aliases : string list
  ; kind : Provider_config.provider_kind
  ; base_url : string
  ; request_path : string
  ; api_key_env : string
  ; auth : auth_mode
  ; default_model : string option
  ; max_context : int option
  ; capabilities : Capabilities.capabilities
  ; credential_scope : string option
  }

type t = entry list

let entries t = t
let normalize_id value = String.lowercase_ascii (String.trim value)

let validate_exact_non_empty ~provider_id ~field value =
  let trimmed = String.trim value in
  if trimmed = ""
  then Error (Printf.sprintf "provider %S field %S must not be empty" provider_id field)
  else if value <> trimmed
  then
    Error
      (Printf.sprintf
         "provider %S field %S must not have leading or trailing whitespace"
         provider_id
         field)
  else Ok ()
;;

let validate_typed_entry (entry : entry) =
  let* () =
    validate_exact_non_empty ~provider_id:entry.id ~field:"base_url" entry.base_url
  in
  let* () =
    let trimmed = String.trim entry.request_path in
    if entry.request_path <> trimmed
    then
      Error
        (Printf.sprintf
           "provider %S field %S must not have leading or trailing whitespace"
           entry.id
           "request_path")
    else if trimmed = "" && entry.kind <> Provider_config.Gemini
    then
      Error
        (Printf.sprintf "provider %S field %S must not be empty" entry.id "request_path")
    else Ok ()
  in
  let* () =
    match entry.default_model with
    | None -> Ok ()
    | Some model ->
      validate_exact_non_empty ~provider_id:entry.id ~field:"default_model" model
  in
  let* () =
    match entry.max_context with
    | Some value when value <= 0 ->
      Error (Printf.sprintf "provider %S max_context must be positive" entry.id)
    | Some _ | None -> Ok ()
  in
  let validate_positive_capability field = function
    | Some value when value <= 0 ->
      Error (Printf.sprintf "provider %S capability %S must be positive" entry.id field)
    | Some _ | None -> Ok ()
  in
  let* () =
    validate_positive_capability
      "max_context_tokens"
      entry.capabilities.max_context_tokens
  in
  let* () =
    validate_positive_capability "max_output_tokens" entry.capabilities.max_output_tokens
  in
  let* () =
    validate_positive_capability
      "prompt_cache_alignment"
      entry.capabilities.prompt_cache_alignment
  in
  let* () =
    match entry.capabilities.supported_models with
    | None -> Ok ()
    | Some models ->
      List.fold_left
        (fun result model ->
           let* () = result in
           validate_exact_non_empty
             ~provider_id:entry.id
             ~field:"capabilities.supported_models"
             model)
        (Ok ())
        models
  in
  let* () =
    match entry.credential_scope with
    | None -> Ok ()
    | Some scope ->
      validate_exact_non_empty ~provider_id:entry.id ~field:"credential_scope" scope
  in
  let declared_env =
    match entry.auth with
    | Api_key_env env | Setup_token_env env -> env
    | No_auth -> ""
  in
  let* () =
    match entry.auth with
    | No_auth ->
      if entry.api_key_env = ""
      then Ok ()
      else
        Error
          (Printf.sprintf "provider %S auth=none requires an empty api_key_env" entry.id)
    | Api_key_env env | Setup_token_env env ->
      let* () = validate_exact_non_empty ~provider_id:entry.id ~field:"auth.env" env in
      if String.equal entry.api_key_env declared_env
      then Ok ()
      else
        Error
          (Printf.sprintf
             "provider %S api_key_env must equal the typed auth env %S"
             entry.id
             declared_env)
  in
  if
    (entry.capabilities.supports_required_tool_choice
     || entry.capabilities.supports_named_tool_choice)
    && not entry.capabilities.supports_tool_choice
  then
    Error
      (Printf.sprintf
         "provider %S required/named tool choice requires supports_tool_choice=true"
         entry.id)
  else Ok ()
;;

let of_entries entries =
  let add_identity ~owner seen raw =
    let identity = normalize_id raw in
    if identity = ""
    then Error (Printf.sprintf "provider %S contains an empty id or alias" owner)
    else if raw <> String.trim raw
    then
      Error
        (Printf.sprintf
           "provider %S identity %S must not have leading or trailing whitespace"
           owner
           raw)
    else (
      match List.assoc_opt identity seen with
      | Some previous_owner ->
        Error
          (Printf.sprintf
             "provider identity %S is declared by both %S and %S"
             identity
             previous_owner
             owner)
      | None -> Ok ((identity, owner) :: seen))
  in
  let add_entry seen (entry : entry) =
    let* () = validate_typed_entry entry in
    let* seen = add_identity ~owner:entry.id seen entry.id in
    List.fold_left
      (fun result alias ->
         let* seen = result in
         add_identity ~owner:entry.id seen alias)
      (Ok seen)
      entry.aliases
  in
  let* _ =
    List.fold_left
      (fun result entry -> Result.bind result (fun seen -> add_entry seen entry))
      (Ok [])
      entries
  in
  Ok entries
;;

let json_kind = function
  | `Null -> "null"
  | `Bool _ -> "bool"
  | `Int _ -> "int"
  | `Intlit _ -> "intlit"
  | `Float _ -> "float"
  | `String _ -> "string"
  | `Assoc _ -> "object"
  | `List _ -> "array"
  | `Tuple _ -> "tuple"
  | `Variant _ -> "variant"
;;

let member key json = Yojson.Safe.Util.member key json

let member_present key = function
  | `Assoc fields -> List.exists (fun (name, _) -> String.equal name key) fields
  | _ -> false
;;

let validate_object_fields ~scope ~known = function
  | `Assoc fields ->
    let rec loop seen = function
      | [] -> Ok ()
      | (key, _) :: rest ->
        if List.mem key seen
        then Error (Printf.sprintf "%s contains duplicate field %S" scope key)
        else if not (List.mem key known)
        then Error (Printf.sprintf "%s contains unknown field %S" scope key)
        else loop (key :: seen) rest
    in
    loop [] fields
  | actual -> Error (Printf.sprintf "%s expected object, got %s" scope (json_kind actual))
;;

let member_string key json =
  match member key json with
  | `String s -> Ok (Some s)
  | `Null -> Ok None
  | actual ->
    Error (Printf.sprintf "field %S expected string, got %s" key (json_kind actual))
;;

let member_string_default key ~default json =
  let* value = member_string key json in
  Ok (Option.value value ~default)
;;

let member_exact_non_empty_string_strict key json =
  match member_string key json with
  | Error _ as error -> error
  | Ok None -> Ok None
  | Ok (Some raw) ->
    let trimmed = String.trim raw in
    if trimmed = ""
    then Error (Printf.sprintf "field %S must not be empty" key)
    else if raw <> trimmed
    then
      Error (Printf.sprintf "field %S must not have leading or trailing whitespace" key)
    else Ok (Some raw)
;;

let member_bool key json =
  match member key json with
  | `Bool b -> Ok (Some b)
  | `Null -> Ok None
  | actual ->
    Error (Printf.sprintf "field %S expected bool, got %s" key (json_kind actual))
;;

let member_int key json =
  match member key json with
  | `Int n -> Ok (Some n)
  | `Intlit s ->
    (match int_of_string_opt s with
     | Some n -> Ok (Some n)
     | None -> Error (Printf.sprintf "field %S integer is out of range" key))
  | `Null -> Ok None
  | actual ->
    Error (Printf.sprintf "field %S expected int, got %s" key (json_kind actual))
;;

let member_positive_int key json =
  let* value = member_int key json in
  match value with
  | Some value when value <= 0 ->
    Error (Printf.sprintf "field %S must be a positive integer" key)
  | value -> Ok value
;;

let member_string_list key json =
  match member key json with
  | `List items ->
    let rec loop index acc = function
      | [] -> Ok (Some (List.rev acc))
      | `String raw :: rest ->
        let trimmed = String.trim raw in
        if String.equal trimmed ""
        then Error (Printf.sprintf "field %S item %d must not be empty" key index)
        else if not (String.equal raw trimmed)
        then
          Error
            (Printf.sprintf
               "field %S item %d must not have leading or trailing whitespace"
               key
               index)
        else loop (index + 1) (raw :: acc) rest
      | actual :: _ ->
        Error
          (Printf.sprintf
             "field %S item %d expected string, got %s"
             key
             index
             (json_kind actual))
    in
    loop 0 [] items
  | `Null -> Ok None
  | actual ->
    Error (Printf.sprintf "field %S expected string array, got %s" key (json_kind actual))
;;

let catalog_fields = [ "schema_version"; "providers" ]

let provider_fields =
  [ "id"
  ; "aliases"
  ; "kind"
  ; "base_url"
  ; "request_path"
  ; "auth"
  ; "default_model"
  ; "max_context"
  ; "capabilities_base"
  ; "capabilities"
  ; "credential_scope"
  ; "api_key_env"
  ; "base"
  ]
;;

let auth_fields = [ "type"; "env"; "key"; "path"; "command" ]

let auth_env = function
  | Api_key_env env | Setup_token_env env -> env
  | No_auth -> ""
;;

let parse_auth json =
  match member "auth" json with
  | `Assoc _ as auth_json ->
    let* () =
      validate_object_fields ~scope:"provider catalog auth" ~known:auth_fields auth_json
    in
    if member_present "key" auth_json
    then Error "removed provider catalog auth field \"key\"; use auth.env"
    else
      let* auth_type = member_string_default "type" ~default:"none" auth_json in
      let validate_active_fields () =
        match
          List.find_opt (fun key -> member_present key auth_json) [ "path"; "command" ]
        with
        | None -> Ok ()
        | Some field ->
          Error (Printf.sprintf "removed provider catalog auth field %S" field)
      in
      let parse_without_env auth =
        let* () = validate_active_fields () in
        let* env = member_exact_non_empty_string_strict "env" auth_json in
        match env with
        | None -> Ok auth
        | Some _ ->
          Error (Printf.sprintf "auth type %S does not accept field \"env\"" auth_type)
      in
      let parse_with_env make_auth =
        let* () = validate_active_fields () in
        let* env = member_exact_non_empty_string_strict "env" auth_json in
        match env with
        | Some env -> Ok (make_auth env)
        | None ->
          Error (Printf.sprintf "auth type %S requires non-empty field \"env\"" auth_type)
      in
      (match auth_type with
       | "file" ->
         Error
           "removed provider catalog auth type \"file\"; use api_key_env, \
            setup_token_env, or none"
       | "exec" ->
         Error
           "removed provider catalog auth type \"exec\"; use api_key_env, \
            setup_token_env, or none"
       | "oauth_cached_login" ->
         Error
           "removed provider catalog auth type \"oauth_cached_login\"; inject a typed \
            transport that implements its own authentication"
       | "none" -> parse_without_env No_auth
       | "api_key_env" -> parse_with_env (fun env -> Api_key_env env)
       | "setup_token_env" -> parse_with_env (fun env -> Setup_token_env env)
       | other ->
         Error
           (Printf.sprintf
              "unknown auth type %S (canonical: none, api_key_env, setup_token_env)"
              other))
  | `Null -> Ok No_auth
  | actual ->
    Error
      (Printf.sprintf
         "provider catalog auth expected object or null, got %s"
         (json_kind actual))
;;

let parse_optional_capability_value ~field ~canonical parse = function
  | None -> Ok None
  | Some raw ->
    let normalized = String.lowercase_ascii (String.trim raw) in
    (match parse normalized with
     | Some value -> Ok (Some value)
     | None ->
       Error (Printf.sprintf "unknown %s %S (canonical: %s)" field normalized canonical))
;;

let parse_preserve_thinking_control_format =
  parse_optional_capability_value
    ~field:"preserve_thinking_control_format"
    ~canonical:
      (String.concat ", " Capability_vocab.preserve_thinking_control_format_values)
    Capability_vocab.preserve_thinking_control_format_of_string
;;

let parse_reasoning_replay = function
  | None -> Ok None
  | Some raw ->
    (match Capability_vocab.reasoning_replay_override_of_string raw with
     | Some policy -> Ok (Some policy)
     | None ->
       Error
         (Printf.sprintf
            "unknown reasoning_replay %S (canonical: %s)"
            (String.lowercase_ascii (String.trim raw))
            (String.concat ", " Capability_vocab.reasoning_replay_values)))
;;

let parse_assistant_tool_content_format = function
  | None -> Ok None
  | Some raw ->
    (match Capability_vocab.assistant_tool_content_format_of_string raw with
     | Some format -> Ok (Some format)
     | None ->
       Error
         (Printf.sprintf
            "unknown assistant_tool_content_format %S (canonical: %s)"
            (String.lowercase_ascii (String.trim raw))
            (String.concat ", " Capability_vocab.assistant_tool_content_format_values)))
;;

let parse_reasoning_output_format = function
  | None -> Ok None
  | Some raw ->
    (match Capability_vocab.reasoning_output_format_of_string raw with
     | Some format -> Ok (Some format)
     | None ->
       Error
         (Printf.sprintf
            "unknown reasoning_output_format %S (canonical: %s)"
            (String.lowercase_ascii (String.trim raw))
            (String.concat ", " Capability_vocab.reasoning_output_format_values)))
;;

let parse_reasoning_streaming_format = function
  | None -> Ok None
  | Some raw ->
    (match Capability_vocab.reasoning_streaming_format_of_string raw with
     | Some format -> Ok (Some format)
     | None ->
       Error
         (Printf.sprintf
            "unknown reasoning_streaming_format %S (canonical: %s)"
            (String.lowercase_ascii (String.trim raw))
            Capability_vocab.reasoning_streaming_format_syntax))
;;

let parse_modality_priority = function
  | None -> Ok None
  | Some raw ->
    let normalized = String.lowercase_ascii (String.trim raw) in
    (match normalized with
     | "preserve_input_order" | "preserve-input-order" | "preserve" ->
       Ok (Some Modality.Preserve_input_order)
     | "visual_first" | "visual-first" -> Ok (Some Modality.Visual_first)
     | other ->
       Error
         (Printf.sprintf
            "unknown modality_priority %S (canonical: %s)"
            other
            (String.concat ", " Capability_vocab.modality_priority_values)))
;;

let parse_accepted_reasoning_efforts = function
  | None -> Ok None
  | Some values ->
    let rec loop acc = function
      | [] -> Ok (Some (List.rev acc))
      | raw :: rest ->
        let normalized = String.lowercase_ascii (String.trim raw) in
        (match Reasoning_effort.of_string normalized with
         | Some effort -> loop (effort :: acc) rest
         | None ->
           Error
             (Printf.sprintf
                "unknown accepted_reasoning_efforts value %S (canonical: %s)"
                normalized
                (String.concat ", " Reasoning_effort.all_wire_values)))
    in
    loop [] values
;;

let parse_ignored_sampling_parameters = function
  | None -> Ok None
  | Some values ->
    let rec loop acc = function
      | [] -> Ok (Some (List.rev acc))
      | raw :: rest ->
        let normalized = String.lowercase_ascii (String.trim raw) in
        (match Capability_vocab.sampling_parameter_of_string normalized with
         | Some parameter -> loop (parameter :: acc) rest
         | None ->
           Error
             (Printf.sprintf
                "unknown ignored_sampling_parameters value %S (canonical: %s)"
                normalized
                (String.concat ", " Capability_vocab.sampling_parameter_values)))
    in
    loop [] values
;;

let capability_base json =
  if member_present "base" json
  then Error "removed provider catalog field \"base\"; use \"capabilities_base\""
  else
    let* label = member_exact_non_empty_string_strict "capabilities_base" json in
    match label with
    | None -> Ok Capabilities.default_capabilities
    | Some raw ->
      (match Capabilities.capabilities_for_provider_label raw with
       | Some caps -> Ok caps
       | None ->
         Error
           (Printf.sprintf
              "unknown capabilities_base %S (see \
               Capabilities.capabilities_for_provider_label for valid presets)"
              raw))
;;

let override value caps f =
  match value with
  | Some value -> f caps value
  | None -> caps
;;

let parse_capabilities provider_json =
  let* cap_json =
    match member "capabilities" provider_json with
    | `Null -> Ok (`Assoc [])
    | `Assoc _ as cap_json ->
      let* () =
        validate_object_fields
          ~scope:"provider catalog capabilities"
          ~known:Capability_vocab.capability_fields
          cap_json
      in
      Ok cap_json
    | actual ->
      Error
        (Printf.sprintf
           "provider catalog capabilities expected object or null, got %s"
           (json_kind actual))
  in
  let* () =
    match
      List.find_opt
        (fun field -> member_present field cap_json)
        [ "supports_runtime_mcp_tools"; "supports_runtime_tool_events" ]
    with
    | None -> Ok ()
    | Some field ->
      Error
        (Printf.sprintf
           "removed provider catalog capability %S; runtime tool transport is not a \
            model/provider capability"
           field)
  in
  let* base = capability_base provider_json in
  let* thinking_control_format =
    (* Provider-level presets declare the same [thinking_control_format] /
       [thinking_control_token] key pair; join them so a chat_template_token
       preset without a token — or a token without that format — fails closed. *)
    let* raw = member_string "thinking_control_format" cap_json in
    let* token = member_string "thinking_control_token" cap_json in
    Capability_vocab.decode_optional_thinking_control_format ~label:raw ~token
    |> Result.map_error Capability_vocab.thinking_control_format_codec_error_to_string
  in
  let* preserve_thinking_control_format =
    let* raw = member_string "preserve_thinking_control_format" cap_json in
    parse_preserve_thinking_control_format raw
  in
  let* reasoning_replay =
    let* raw = member_string "reasoning_replay" cap_json in
    parse_reasoning_replay raw
  in
  let* assistant_tool_content_format =
    let* raw = member_string "assistant_tool_content_format" cap_json in
    parse_assistant_tool_content_format raw
  in
  let* reasoning_output_format =
    let* raw = member_string "reasoning_output_format" cap_json in
    parse_reasoning_output_format raw
  in
  let* reasoning_streaming_format =
    let* raw = member_string "reasoning_streaming_format" cap_json in
    parse_reasoning_streaming_format raw
  in
  let* modality_priority =
    let* raw = member_string "modality_priority" cap_json in
    parse_modality_priority raw
  in
  let* accepted_reasoning_efforts_raw =
    member_string_list "accepted_reasoning_efforts" cap_json
  in
  let* accepted_reasoning_efforts =
    parse_accepted_reasoning_efforts accepted_reasoning_efforts_raw
  in
  let* ignored_sampling_parameters_raw =
    member_string_list "ignored_sampling_parameters" cap_json
  in
  let* ignored_sampling_parameters =
    parse_ignored_sampling_parameters ignored_sampling_parameters_raw
  in
  let* supported_models = member_string_list "supported_models" cap_json in
  let* max_context_tokens = member_positive_int "max_context_tokens" cap_json in
  let* max_output_tokens = member_positive_int "max_output_tokens" cap_json in
  let* prompt_cache_alignment = member_positive_int "prompt_cache_alignment" cap_json in
  let* supports_tools = member_bool "supports_tools" cap_json in
  let* supports_tool_choice = member_bool "supports_tool_choice" cap_json in
  let* supports_required_tool_choice =
    member_bool "supports_required_tool_choice" cap_json
  in
  let* supports_named_tool_choice = member_bool "supports_named_tool_choice" cap_json in
  let* supports_parallel_tool_calls =
    member_bool "supports_parallel_tool_calls" cap_json
  in
  let* supports_reasoning = member_bool "supports_reasoning" cap_json in
  let* supports_extended_thinking = member_bool "supports_extended_thinking" cap_json in
  let* supports_reasoning_budget = member_bool "supports_reasoning_budget" cap_json in
  let* supports_response_format_json =
    member_bool "supports_response_format_json" cap_json
  in
  let* supports_structured_output = member_bool "supports_structured_output" cap_json in
  let* supports_multimodal_inputs = member_bool "supports_multimodal_inputs" cap_json in
  let* supports_image_input = member_bool "supports_image_input" cap_json in
  let* supports_audio_input = member_bool "supports_audio_input" cap_json in
  let* supports_video_input = member_bool "supports_video_input" cap_json in
  let* supports_document_input = member_bool "supports_document_input" cap_json in
  let* supports_native_streaming = member_bool "supports_native_streaming" cap_json in
  let* supports_system_prompt = member_bool "supports_system_prompt" cap_json in
  let* supports_caching = member_bool "supports_caching" cap_json in
  let* supports_prompt_caching = member_bool "supports_prompt_caching" cap_json in
  let* supports_top_k = member_bool "supports_top_k" cap_json in
  let* supports_min_p = member_bool "supports_min_p" cap_json in
  let* supports_seed = member_bool "supports_seed" cap_json in
  let* supports_seed_with_images = member_bool "supports_seed_with_images" cap_json in
  let* supports_computer_use = member_bool "supports_computer_use" cap_json in
  let* supports_code_execution = member_bool "supports_code_execution" cap_json in
  let* emits_usage_tokens = member_bool "emits_usage_tokens" cap_json in
  let caps =
    base
    |> fun caps ->
    override max_context_tokens caps (fun caps value ->
      { caps with Capabilities.max_context_tokens = Some value })
    |> fun caps ->
    override max_output_tokens caps (fun caps value ->
      { caps with Capabilities.max_output_tokens = Some value })
    |> fun caps ->
    override supports_tools caps (fun caps value ->
      { caps with Capabilities.supports_tools = value })
    |> fun caps ->
    override supports_tool_choice caps (fun caps value ->
      { caps with Capabilities.supports_tool_choice = value })
    |> fun caps ->
    override supports_required_tool_choice caps (fun caps value ->
      { caps with Capabilities.supports_required_tool_choice = value })
    |> fun caps ->
    override supports_named_tool_choice caps (fun caps value ->
      { caps with Capabilities.supports_named_tool_choice = value })
    |> fun caps ->
    override supports_parallel_tool_calls caps (fun caps value ->
      { caps with Capabilities.supports_parallel_tool_calls = value })
    |> fun caps ->
    (match assistant_tool_content_format with
     | Some assistant_tool_content_format ->
       { caps with Capabilities.assistant_tool_content_format }
     | None -> caps)
    |> fun caps ->
    (match reasoning_output_format with
     | Some reasoning_output_format -> { caps with Capabilities.reasoning_output_format }
     | None -> caps)
    |> fun caps ->
    (match reasoning_streaming_format with
     | Some reasoning_streaming_format ->
       { caps with Capabilities.reasoning_streaming_format }
     | None -> caps)
    |> fun caps ->
    override supports_reasoning caps (fun caps value ->
      { caps with Capabilities.supports_reasoning = value })
    |> fun caps ->
    override supports_extended_thinking caps (fun caps value ->
      { caps with Capabilities.supports_extended_thinking = value })
    |> fun caps ->
    override supports_reasoning_budget caps (fun caps value ->
      { caps with Capabilities.supports_reasoning_budget = value })
    |> fun caps ->
    override supports_response_format_json caps (fun caps value ->
      { caps with Capabilities.supports_response_format_json = value })
    |> fun caps ->
    override supports_structured_output caps (fun caps value ->
      { caps with Capabilities.supports_structured_output = value })
    |> fun caps ->
    override supports_multimodal_inputs caps (fun caps value ->
      { caps with Capabilities.supports_multimodal_inputs = value })
    |> fun caps ->
    override supports_image_input caps (fun caps value ->
      { caps with Capabilities.supports_image_input = value })
    |> fun caps ->
    override supports_audio_input caps (fun caps value ->
      { caps with Capabilities.supports_audio_input = value })
    |> fun caps ->
    override supports_video_input caps (fun caps value ->
      { caps with Capabilities.supports_video_input = value })
    |> fun caps ->
    override supports_document_input caps (fun caps value ->
      { caps with Capabilities.supports_document_input = value })
    |> fun caps ->
    (match modality_priority with
     | Some modality_priority -> { caps with Capabilities.modality_priority }
     | None -> caps)
    |> fun caps ->
    override supports_native_streaming caps (fun caps value ->
      { caps with Capabilities.supports_native_streaming = value })
    |> fun caps ->
    override supports_system_prompt caps (fun caps value ->
      { caps with Capabilities.supports_system_prompt = value })
    |> fun caps ->
    override supports_caching caps (fun caps value ->
      { caps with Capabilities.supports_caching = value })
    |> fun caps ->
    override supports_prompt_caching caps (fun caps value ->
      { caps with Capabilities.supports_prompt_caching = value })
    |> fun caps ->
    override prompt_cache_alignment caps (fun caps value ->
      { caps with Capabilities.prompt_cache_alignment = Some value })
    |> fun caps ->
    override supports_top_k caps (fun caps value ->
      { caps with Capabilities.supports_top_k = value })
    |> fun caps ->
    override supports_min_p caps (fun caps value ->
      { caps with Capabilities.supports_min_p = value })
    |> fun caps ->
    override supports_seed caps (fun caps value ->
      { caps with Capabilities.supports_seed = value })
    |> fun caps ->
    override supports_seed_with_images caps (fun caps value ->
      { caps with Capabilities.supports_seed_with_images = value })
    |> fun caps ->
    (match ignored_sampling_parameters with
     | Some ignored_sampling_parameters ->
       { caps with Capabilities.ignored_sampling_parameters }
     | None -> caps)
    |> fun caps ->
    override supports_computer_use caps (fun caps value ->
      { caps with Capabilities.supports_computer_use = value })
    |> fun caps ->
    override supports_code_execution caps (fun caps value ->
      { caps with Capabilities.supports_code_execution = value })
    |> fun caps ->
    override emits_usage_tokens caps (fun caps value ->
      { caps with Capabilities.emits_usage_tokens = value })
  in
  let caps =
    match thinking_control_format with
    | None -> caps
    | Some thinking_control_format -> { caps with Capabilities.thinking_control_format }
  in
  let caps =
    match preserve_thinking_control_format with
    | None -> caps
    | Some preserve_thinking_control_format ->
      { caps with Capabilities.preserve_thinking_control_format }
  in
  let caps =
    match reasoning_replay with
    | None -> caps
    | Some reasoning_replay_override ->
      { caps with Capabilities.reasoning_replay_override }
  in
  let caps =
    match supported_models with
    | Some models -> { caps with Capabilities.supported_models = Some models }
    | None -> caps
  in
  let caps =
    match accepted_reasoning_efforts with
    | Some accepted_reasoning_efforts ->
      { caps with
        Capabilities.accepted_reasoning_efforts = Some accepted_reasoning_efforts
      }
    | None -> caps
  in
  if
    (caps.supports_required_tool_choice || caps.supports_named_tool_choice)
    && not caps.supports_tool_choice
  then
    Error
      "supports_required_tool_choice/supports_named_tool_choice require \
       supports_tool_choice=true"
  else Ok caps
;;

let parse_entry json =
  let* () =
    validate_object_fields ~scope:"provider catalog entry" ~known:provider_fields json
  in
  let* id =
    match member_exact_non_empty_string_strict "id" json with
    | Error _ as error -> error
    | Ok None -> Error "provider entry missing required \"id\" field"
    | Ok (Some id) -> Ok id
  in
  let prefix_id message = Printf.sprintf "provider %S: %s" id message in
  let with_id result = Result.map_error prefix_id result in
  let* () =
    if member_present "api_key_env" json
    then
      Error
        (prefix_id
           "removed provider catalog field \"api_key_env\"; use auth.type=api_key_env \
            with auth.env")
    else Ok ()
  in
  let* kind_raw = with_id (member_string_default "kind" ~default:"openai_compat" json) in
  let* kind =
    match Provider_kind.of_string kind_raw with
    | Some kind -> Ok kind
    | None -> Error (Printf.sprintf "provider %S has unknown kind %S" id kind_raw)
  in
  let* auth = with_id (parse_auth json) in
  let* capabilities = with_id (parse_capabilities json) in
  let* aliases = with_id (member_string_list "aliases" json) in
  let* base_url = with_id (member_string_default "base_url" ~default:"" json) in
  let* request_path =
    with_id
      (member_string_default
         "request_path"
         ~default:(Provider_config.request_path_default_for_kind kind)
         json)
  in
  let* default_model = with_id (member_string "default_model" json) in
  let* max_context_override = with_id (member_positive_int "max_context" json) in
  let* credential_scope = with_id (member_string "credential_scope" json) in
  let max_context =
    match max_context_override with
    | Some _ as max_context -> max_context
    | None -> capabilities.Capabilities.max_context_tokens
  in
  Ok
    { id
    ; aliases = Option.value aliases ~default:[]
    ; kind
    ; base_url
    ; request_path
    ; api_key_env = auth_env auth
    ; auth
    ; default_model
    ; max_context
    ; capabilities
    ; credential_scope
    }
;;

let of_json = function
  | `Assoc _ as json ->
    let* () =
      validate_object_fields ~scope:"provider catalog" ~known:catalog_fields json
    in
    let* schema_version =
      match member "schema_version" json with
      | `Int n -> Ok n
      | actual ->
        Error
          (Printf.sprintf
             "provider catalog schema_version expected int, got %s"
             (json_kind actual))
    in
    if schema_version <> 1
    then
      Error
        (Printf.sprintf
           "unsupported provider catalog schema_version: %d (expected 1)"
           schema_version)
    else
      let* items =
        match member "providers" json with
        | `List items -> Ok items
        | actual ->
          Error
            (Printf.sprintf
               "provider catalog providers expected array, got %s"
               (json_kind actual))
      in
      let entries, errors =
        List.fold_left
          (fun (entries, errors) item ->
             match parse_entry item with
             | Ok entry -> entry :: entries, errors
             | Error error -> entries, error :: errors)
          ([], [])
          items
      in
      (match List.rev errors with
       | [] -> of_entries (List.rev entries)
       | errors -> Error (String.concat "; " errors))
  | actual ->
    Error (Printf.sprintf "provider catalog expected object, got %s" (json_kind actual))
;;

let load_file path =
  let* json =
    try Ok (Yojson.Safe.from_file path) with
    | Sys_error msg ->
      Error (Printf.sprintf "cannot read provider catalog %s: %s" path msg)
    | Yojson.Json_error msg ->
      Error (Printf.sprintf "provider catalog JSON parse error in %s: %s" path msg)
  in
  of_json json
;;

let lookup t provider_id =
  let needle = normalize_id provider_id in
  List.find_opt
    (fun entry ->
       normalize_id entry.id = needle
       || List.exists (fun alias -> normalize_id alias = needle) entry.aliases)
    t
;;

let default_model_for_provider t provider_id =
  match lookup t provider_id with
  | Some entry -> entry.default_model
  | None -> None
;;

let runtime_override : t option Atomic.t = Atomic.make None
let set_global t = Atomic.set runtime_override (Some t)
let clear_global () = Atomic.set runtime_override None
let global () = Atomic.get runtime_override
