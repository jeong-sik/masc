(** Dynamic Model Catalog TOML loader. *)

module Result_syntax = struct
  let ( let* ) = Result.bind
end

open Result_syntax

type model_entry =
  { id_prefix : Model_identifiers.Id_prefix.t
  ; base_label : string option
  ; provider_name : string option
  ; max_context_tokens : int option
  ; serving_constraint : Serving_constraint.t option
  ; max_output_tokens : int option
  ; supports_tools : bool option
  ; supports_tool_choice : bool option
  ; supports_required_tool_choice : bool option
  ; supports_named_tool_choice : bool option
  ; supports_parallel_tool_calls : bool option
  ; assistant_tool_content_format : string option
  ; chat_output_budget_field : string option
  ; tool_schema_conformance : string option
  ; supports_reasoning : bool option
  ; accepted_reasoning_efforts : string list option
  ; supports_response_format_json : bool option
  ; supports_structured_output : bool option
  ; supports_multimodal_inputs : bool option
  ; supports_image_input : bool option
  ; supports_audio_input : bool option
  ; supports_video_input : bool option
  ; supports_document_input : bool option
  ; modality_priority : string option
  ; task : Capability_vocab.task option
  ; supported_models : string list option
  ; supports_native_streaming : bool option
  ; supports_system_prompt : bool option
  ; supports_prompt_caching : bool option
  ; supports_top_k : bool option
  ; supports_min_p : bool option
  ; supports_seed : bool option
  ; ignored_sampling_parameters : Capability_vocab.sampling_parameter list option
  ; thinking_control_format : Capability_vocab.thinking_control_format option
    (* Typed at the parse boundary (unlike the sibling string-valued format
       fields) because it carries the chat-template thinking token in its
       [Chat_template_token] constructor. The TOML still declares the
       [thinking_control_format] and [thinking_control_token] keys separately;
       [parse_entry] joins them so a [chat_template_token] row without a token —
       or a token without that format — fails closed here. *)
  ; anthropic_thinking_control : Capability_vocab.anthropic_thinking_control option
  ; preserve_thinking_control_format : string option
  ; content_inline_reasoning : string option
  ; reasoning_output_format : string option
  ; reasoning_streaming_format : string option
  ; reasoning_replay : string option
  ; input_per_million : float option
  ; output_per_million : float option
  ; cache_write_multiplier : float option
  ; cache_read_multiplier : float option
  }

type provider_entry = Model_provider_catalog.entry =
  { id : string
  ; aliases : string list
  ; kind : Provider_kind.t
  ; identity_kinds : Provider_kind.t list
  ; base_url : string
  ; base_url_env : string option
  ; request_path : string
  ; api_key_env : string
  ; default_model : string option
  ; capabilities_base : string option
  ; capabilities_base_by_identity_kind : (Provider_kind.t * string) list
  ; identity_hosts : string list
  ; supports_parallel_tool_suppression : bool
  }

type t =
  { models : model_entry list
  ; providers : provider_entry list
  }

exception Invalid_embedded_catalog of string

let empty = { models = []; providers = [] }
let of_model_entries models = { empty with models }
let model_entries t = t.models
let provider_entries t = t.providers

let find_string_field ~entry_id key toml =
  match Otoml.find_opt toml Otoml.get_string [ key ] with
  | Some s -> Ok (Some s)
  | None -> Ok None
  | exception Otoml.Type_error _ ->
    Error (Printf.sprintf "model entry %S field %S expected string" entry_id key)
;;

let non_empty_string_field ~entry_id key toml =
  match find_string_field ~entry_id key toml with
  | Error _ as error -> error
  | Ok None -> Ok None
  | Ok (Some raw) ->
    let trimmed = String.trim raw in
    if trimmed = ""
    then Error (Printf.sprintf "model entry %S field %S must not be empty" entry_id key)
    else if raw <> trimmed
    then
      Error
        (Printf.sprintf
           "model entry %S field %S must not have leading or trailing whitespace"
           entry_id
           key)
    else Ok (Some (String.lowercase_ascii raw))
;;

let canonical_string_opt ~entry_id key ~allowed toml =
  match find_string_field ~entry_id key toml with
  | Error _ as e -> e
  | Ok None -> Ok None
  | Ok (Some raw) ->
    let normalized = String.lowercase_ascii (String.trim raw) in
    if List.mem normalized allowed
    then Ok (Some raw)
    else
      Error
        (Printf.sprintf
           "model entry %S field %S has unknown value %S (canonical: %s)"
           entry_id
           key
           normalized
           (String.concat ", " allowed))
;;

let optional_field ~entry_id ~expected getter key toml =
  try Ok (Otoml.find_opt toml getter [ key ]) with
  | Otoml.Type_error _ ->
    Error (Printf.sprintf "model entry %S field %S expected %s" entry_id key expected)
;;

let bool_field ~entry_id = optional_field ~entry_id ~expected:"bool" Otoml.get_boolean
let int_field ~entry_id = optional_field ~entry_id ~expected:"integer" Otoml.get_integer
let float_field ~entry_id = optional_field ~entry_id ~expected:"float" Otoml.get_float

let string_list_field ~entry_id =
  optional_field ~entry_id ~expected:"string array" (Otoml.get_array Otoml.get_string)
;;

let exact_non_empty_string_list_opt ~entry_id key toml =
  match string_list_field ~entry_id key toml with
  | Error _ as error -> error
  | Ok None -> Ok None
  | Ok (Some []) ->
    Error
      (Printf.sprintf
         "model entry %S field %S must contain at least one value"
         entry_id
         key)
  | Ok (Some values) ->
    let rec validate seen = function
      | [] -> Ok (Some values)
      | raw :: rest ->
        let trimmed = String.trim raw in
        if trimmed = ""
        then
          Error
            (Printf.sprintf
               "model entry %S field %S values must not be empty"
               entry_id
               key)
        else if raw <> trimmed
        then
          Error
            (Printf.sprintf
               "model entry %S field %S values must not have leading or trailing \
                whitespace"
               entry_id
               key)
        else if List.mem raw seen
        then
          Error
            (Printf.sprintf
               "model entry %S field %S contains duplicate value %S"
               entry_id
               key
               raw)
        else validate (raw :: seen) rest
    in
    validate [] values
;;

let canonical_string_list_opt ~entry_id key ~allowed toml =
  match string_list_field ~entry_id key toml with
  | Error _ as error -> error
  | Ok None -> Ok None
  | Ok (Some values) ->
    let unknown =
      List.filter_map
        (fun raw ->
           let normalized = String.lowercase_ascii (String.trim raw) in
           if List.mem normalized allowed then None else Some normalized)
        values
    in
    (match unknown with
     | [] -> Ok (Some values)
     | values ->
       Error
         (Printf.sprintf
            "model entry %S field %S has unknown value(s) %s (canonical: %s)"
            entry_id
            key
            (String.concat ", " values)
            (String.concat ", " allowed)))
;;

let reasoning_streaming_format_opt ~entry_id key toml =
  match find_string_field ~entry_id key toml with
  | Error _ as e -> e
  | Ok None -> Ok None
  | Ok (Some raw) ->
    (match Capability_vocab.reasoning_streaming_format_of_string raw with
     | Some _ -> Ok (Some raw)
     | None ->
       let normalized = String.lowercase_ascii (String.trim raw) in
       Error
         (Printf.sprintf
            "model entry %S field %S has unknown value %S (canonical: %s)"
            entry_id
            key
            normalized
            Capability_vocab.reasoning_streaming_format_syntax))
;;

let sampling_parameters_opt ~entry_id key toml =
  match string_list_field ~entry_id key toml with
  | Error _ as error -> error
  | Ok None -> Ok None
  | Ok (Some values) ->
    let parsed, unknown =
      List.fold_right
        (fun raw (parsed, unknown) ->
           match Capability_vocab.sampling_parameter_of_string raw with
           | Some parameter -> parameter :: parsed, unknown
           | None -> parsed, String.lowercase_ascii (String.trim raw) :: unknown)
        values
        ([], [])
    in
    (match unknown with
     | [] -> Ok (Some parsed)
     | values ->
       Error
         (Printf.sprintf
            "model entry %S field %S has unknown value(s) %s (canonical: %s)"
            entry_id
            key
            (String.concat ", " values)
            (String.concat ", " Capability_vocab.sampling_parameter_values)))
;;

(* Typed at the parse boundary: an entry either declares a canonical task or
   fails the whole catalog load. Storing the raw string here would defer the
   unknown-value decision to a warn-and-keep-base fallback at capability
   application time. *)
let task_opt ~entry_id key toml =
  match find_string_field ~entry_id key toml with
  | Error e -> Error e
  | Ok None -> Ok None
  | Ok (Some raw) ->
    (match Capability_vocab.task_of_string raw with
     | Some _ as task -> Ok task
     | None ->
       Error
         (Printf.sprintf
            "model entry %S field %S has unknown value %S (canonical: %s)"
            entry_id
            key
            (String.lowercase_ascii (String.trim raw))
            (String.concat ", " Capability_vocab.task_values)))
;;

let anthropic_thinking_control_opt ~entry_id key toml =
  match
    canonical_string_opt
      ~entry_id
      key
      ~allowed:Capability_vocab.anthropic_thinking_control_values
      toml
  with
  | Error _ as error -> error
  | Ok None -> Ok None
  | Ok (Some raw) ->
    (match Capability_vocab.anthropic_thinking_control_of_string raw with
     | Some control -> Ok (Some control)
     | None ->
       Error
         (Printf.sprintf
            "model entry %S field %S has unknown value %S (canonical: %s)"
            entry_id
            key
            (String.lowercase_ascii (String.trim raw))
            (String.concat ", " Capability_vocab.anthropic_thinking_control_values)))
;;

(* Every field [parse_entry] reads below. A misspelled or stale key (e.g.
   [suports_tools]) would otherwise be silently ignored, leaving the capability
   at its default and hiding the misconfiguration. Enumerate the table keys and
   fail closed on anything unknown, mirroring
   [Capability_manifest.reject_unknown_keys]. Keep this list in sync with the
   record construction below. *)
let known_entry_keys =
  [ "id_prefix"
  ; "base"
  ; "provider_name"
  ; "max_context_tokens"
  ; "serving_constraint_source_kind"
  ; "serving_constraint_source"
  ; "serving_constraint_checked_at_unix_s"
  ; "serving_constraint_confidence"
  ; "serving_constraint_expires_at_unix_s"
  ; "serving_constraint_accepted_through_tokens"
  ; "serving_constraint_rejected_from_tokens"
  ; "max_output_tokens"
  ; "supports_tools"
  ; "supports_tool_choice"
  ; "supports_required_tool_choice"
  ; "supports_named_tool_choice"
  ; "supports_parallel_tool_calls"
  ; "assistant_tool_content_format"
  ; "chat_output_budget_field"
  ; "tool_schema_conformance"
  ; "supports_reasoning"
  ; "accepted_reasoning_efforts"
  ; "supports_response_format_json"
  ; "supports_structured_output"
  ; "supports_multimodal_inputs"
  ; "supports_image_input"
  ; "supports_audio_input"
  ; "supports_video_input"
  ; "supports_document_input"
  ; "modality_priority"
  ; "task"
  ; "supported_models"
  ; "supports_native_streaming"
  ; "supports_system_prompt"
  ; "supports_prompt_caching"
  ; "supports_top_k"
  ; "supports_min_p"
  ; "supports_seed"
  ; "ignored_sampling_parameters"
  ; "thinking_control_format"
  ; "thinking_control_token"
  ; "anthropic_thinking_control"
  ; "preserve_thinking_control_format"
  ; "content_inline_reasoning"
  ; "reasoning_output_format"
  ; "reasoning_streaming_format"
  ; "reasoning_replay"
  ; "input_per_million"
  ; "output_per_million"
  ; "cache_write_multiplier"
  ; "cache_read_multiplier"
  ]
;;

let reject_unknown_entry_keys ~entry_id entry_toml =
  match Otoml.list_table_keys_result entry_toml with
  | Error _ -> Ok () (* not a table; the id_prefix shape check already handled it *)
  | Ok keys ->
    (match List.filter (fun k -> not (List.mem k known_entry_keys)) keys with
     | [] -> Ok ()
     | unknown ->
       Error
         (Printf.sprintf
            "model entry %S contains unknown field(s): %s"
            entry_id
            (String.concat ", " unknown)))
;;

let parse_entry entry_toml =
  let* id_prefix =
    match find_string_field ~entry_id:"<unknown>" "id_prefix" entry_toml with
    | Error _ -> Error "model entry field \"id_prefix\" expected string"
    | Ok None -> Error "model entry missing required \"id_prefix\" field"
    | Ok (Some raw) ->
      let* id_prefix = Model_identifiers.Id_prefix.of_string raw in
      let* () =
        reject_unknown_entry_keys
          ~entry_id:(Model_identifiers.Id_prefix.to_string id_prefix)
          entry_toml
      in
      Ok id_prefix
  in
  let entry_id = Model_identifiers.Id_prefix.to_string id_prefix in
  let* base_label =
    canonical_string_opt
      ~entry_id
      "base"
      ~allowed:Capability_vocab.base_label_values
      entry_toml
  in
  let* provider_name =
    non_empty_string_field ~entry_id "provider_name" entry_toml
  in
  let* max_context_tokens =
    int_field ~entry_id "max_context_tokens" entry_toml
  in
  let* serving_constraint =
    Serving_constraint_catalog.parse ~entry_id entry_toml
  in
  let* max_output_tokens = int_field ~entry_id "max_output_tokens" entry_toml in
  let* supports_tools = bool_field ~entry_id "supports_tools" entry_toml in
  let* supports_tool_choice =
    bool_field ~entry_id "supports_tool_choice" entry_toml
  in
  let* supports_required_tool_choice =
    bool_field ~entry_id "supports_required_tool_choice" entry_toml
  in
  let* supports_named_tool_choice =
    bool_field ~entry_id "supports_named_tool_choice" entry_toml
  in
  let* supports_parallel_tool_calls =
    bool_field ~entry_id "supports_parallel_tool_calls" entry_toml
  in
  let* assistant_tool_content_format =
    canonical_string_opt
      ~entry_id
      "assistant_tool_content_format"
      ~allowed:Capability_vocab.assistant_tool_content_format_values
      entry_toml
  in
  let* chat_output_budget_field =
    canonical_string_opt
      ~entry_id
      "chat_output_budget_field"
      ~allowed:Capability_vocab.chat_output_budget_field_values
      entry_toml
  in
  let* tool_schema_conformance =
    canonical_string_opt
      ~entry_id
      "tool_schema_conformance"
      ~allowed:Capability_vocab.tool_schema_conformance_values
      entry_toml
  in
  let* supports_reasoning =
    bool_field ~entry_id "supports_reasoning" entry_toml
  in
  let* accepted_reasoning_efforts =
    canonical_string_list_opt
      ~entry_id
      "accepted_reasoning_efforts"
      ~allowed:Reasoning_effort.all_wire_values
      entry_toml
  in
  let* supports_response_format_json =
    bool_field ~entry_id "supports_response_format_json" entry_toml
  in
  let* supports_structured_output =
    bool_field ~entry_id "supports_structured_output" entry_toml
  in
  let* supports_multimodal_inputs =
    bool_field ~entry_id "supports_multimodal_inputs" entry_toml
  in
  let* supports_image_input =
    bool_field ~entry_id "supports_image_input" entry_toml
  in
  let* supports_audio_input =
    bool_field ~entry_id "supports_audio_input" entry_toml
  in
  let* supports_video_input =
    bool_field ~entry_id "supports_video_input" entry_toml
  in
  let* supports_document_input =
    bool_field ~entry_id "supports_document_input" entry_toml
  in
  let* modality_priority =
    canonical_string_opt
      ~entry_id
      "modality_priority"
      ~allowed:Capability_vocab.modality_priority_values
      entry_toml
  in
  let* task = task_opt ~entry_id "task" entry_toml in
  let* supported_models =
    exact_non_empty_string_list_opt ~entry_id "supported_models" entry_toml
  in
  let* supports_native_streaming =
    bool_field ~entry_id "supports_native_streaming" entry_toml
  in
  let* supports_system_prompt =
    bool_field ~entry_id "supports_system_prompt" entry_toml
  in
  let* supports_prompt_caching =
    bool_field ~entry_id "supports_prompt_caching" entry_toml
  in
  let* supports_top_k = bool_field ~entry_id "supports_top_k" entry_toml in
  let* supports_min_p = bool_field ~entry_id "supports_min_p" entry_toml in
  let* supports_seed = bool_field ~entry_id "supports_seed" entry_toml in
  let* ignored_sampling_parameters =
    sampling_parameters_opt ~entry_id "ignored_sampling_parameters" entry_toml
  in
  let* thinking_control_format_raw =
    find_string_field ~entry_id "thinking_control_format" entry_toml
  in
  let* thinking_control_token =
    find_string_field ~entry_id "thinking_control_token" entry_toml
  in
  let* thinking_control_format =
    Capability_vocab.decode_optional_thinking_control_format
      ~label:thinking_control_format_raw
      ~token:thinking_control_token
    |> Result.map_error (fun error ->
      Printf.sprintf
        "model entry %S %s"
        (Model_identifiers.Id_prefix.to_string id_prefix)
        (Capability_vocab.thinking_control_format_codec_error_to_string error))
  in
  let* anthropic_thinking_control =
    anthropic_thinking_control_opt
      ~entry_id
      "anthropic_thinking_control"
      entry_toml
  in
  let* preserve_thinking_control_format =
    canonical_string_opt
      ~entry_id
      "preserve_thinking_control_format"
      ~allowed:Capability_vocab.preserve_thinking_control_format_values
      entry_toml
  in
  let* content_inline_reasoning =
    canonical_string_opt
      ~entry_id
      "content_inline_reasoning"
      ~allowed:Capability_vocab.content_inline_reasoning_values
      entry_toml
  in
  let* reasoning_output_format =
    canonical_string_opt
      ~entry_id
      "reasoning_output_format"
      ~allowed:Capability_vocab.reasoning_output_format_values
      entry_toml
  in
  let* reasoning_streaming_format =
    reasoning_streaming_format_opt
      ~entry_id
      "reasoning_streaming_format"
      entry_toml
  in
  let* reasoning_replay =
    canonical_string_opt
      ~entry_id
      "reasoning_replay"
      ~allowed:Capability_vocab.reasoning_replay_values
      entry_toml
  in
  let* input_per_million =
    float_field ~entry_id "input_per_million" entry_toml
  in
  let* output_per_million =
    float_field ~entry_id "output_per_million" entry_toml
  in
  let* cache_write_multiplier =
    float_field ~entry_id "cache_write_multiplier" entry_toml
  in
  let* cache_read_multiplier =
    float_field ~entry_id "cache_read_multiplier" entry_toml
  in
  Ok
    { id_prefix
    ; base_label
    ; provider_name
    ; max_context_tokens
    ; serving_constraint
    ; max_output_tokens
    ; supports_tools
    ; supports_tool_choice
    ; supports_required_tool_choice
    ; supports_named_tool_choice
    ; supports_parallel_tool_calls
    ; assistant_tool_content_format
    ; chat_output_budget_field
    ; tool_schema_conformance
    ; supports_reasoning
    ; accepted_reasoning_efforts
    ; supports_response_format_json
    ; supports_structured_output
    ; supports_multimodal_inputs
    ; supports_image_input
    ; supports_audio_input
    ; supports_video_input
    ; supports_document_input
    ; modality_priority
    ; task
    ; supported_models
    ; supports_native_streaming
    ; supports_system_prompt
    ; supports_prompt_caching
    ; supports_top_k
    ; supports_min_p
    ; supports_seed
    ; ignored_sampling_parameters
    ; thinking_control_format
    ; anthropic_thinking_control
    ; preserve_thinking_control_format
    ; content_inline_reasoning
    ; reasoning_output_format
    ; reasoning_streaming_format
    ; reasoning_replay
    ; input_per_million
    ; output_per_million
    ; cache_write_multiplier
    ; cache_read_multiplier
    }
;;

let%test "parse_entry rejects an unknown/misspelled field, not silently dropped" =
  (* A typo like [suports_tools] must fail closed rather than leave
     supports_tools at its default with no signal (Agent Core contract silent-swallow). *)
  let entry = Otoml.Parser.from_string "id_prefix = \"m\"\nsuports_tools = true" in
  match parse_entry entry with
  | Error _ -> true
  | Ok _ -> false
;;

let%test "parse_entry accepts an entry whose fields are all known" =
  let entry = Otoml.Parser.from_string "id_prefix = \"m\"\nsupports_tools = true" in
  match parse_entry entry with
  | Ok _ -> true
  | Error _ -> false
;;

let%test "parse_entry rejects empty supported_models list" =
  let entry = Otoml.Parser.from_string "id_prefix = \"m\"\nsupported_models = []" in
  match parse_entry entry with
  | Error _ -> true
  | Ok _ -> false
;;

let%test "parse_entry rejects whitespace-only supported_models item" =
  let entry =
    Otoml.Parser.from_string "id_prefix = \"m\"\nsupported_models = [\"   \"]"
  in
  match parse_entry entry with
  | Error _ -> true
  | Ok _ -> false
;;

let%test "parse_entry rejects duplicate supported_models" =
  let entry =
    Otoml.Parser.from_string
      "id_prefix = \"m\"\nsupported_models = [\"model-a\", \"model-a\"]"
  in
  match parse_entry entry with
  | Error _ -> true
  | Ok _ -> false
;;

let%test "parse_entry parses a canonical task value into the closed variant" =
  let entry = Otoml.Parser.from_string "id_prefix = \"m\"\ntask = \"transcription\"" in
  match parse_entry entry with
  | Ok { task = Some Capability_vocab.Transcription; _ } -> true
  | Ok _ | Error _ -> false
;;

let%test "parse_entry rejects an unknown task value, not silently dropped" =
  let entry = Otoml.Parser.from_string "id_prefix = \"m\"\ntask = \"chat\"" in
  match parse_entry entry with
  | Error _ -> true
  | Ok _ -> false
;;

let%test "parse_entry leaves task undeclared as None" =
  let entry = Otoml.Parser.from_string "id_prefix = \"m\"" in
  match parse_entry entry with
  | Ok { task = None; _ } -> true
  | Ok _ | Error _ -> false
;;

let%test "parse_entry parses Anthropic thinking control as typed catalog data" =
  let entry =
    Otoml.Parser.from_string
      "id_prefix = \"thinking-control-parse-fixture\"\n\
       anthropic_thinking_control = \"adaptive_preferred\""
  in
  match parse_entry entry with
  | Ok { anthropic_thinking_control = Some Capability_vocab.Adaptive_preferred; _ } ->
    true
  | Ok _ | Error _ -> false
;;

let%test "parse_entry rejects unknown Anthropic thinking control" =
  let entry =
    Otoml.Parser.from_string
      "id_prefix = \"m\"\nanthropic_thinking_control = \"guessing\""
  in
  match parse_entry entry with
  | Error _ -> true
  | Ok _ -> false
;;

let%test "parse_entry parses ignored_sampling_parameters into closed variants" =
  let entry =
    Otoml.Parser.from_string
      "id_prefix = \"m\"\nignored_sampling_parameters = [\"temperature\", \"top_p\"]"
  in
  match parse_entry entry with
  | Ok
      { ignored_sampling_parameters =
          Some [ Capability_vocab.Temperature; Capability_vocab.Top_p ]
      ; _
      } -> true
  | Ok _ | Error _ -> false
;;

let%test "parse_entry rejects unknown ignored_sampling_parameters" =
  let entry =
    Otoml.Parser.from_string "id_prefix = \"m\"\nignored_sampling_parameters = [\"temp\"]"
  in
  match parse_entry entry with
  | Error _ -> true
  | Ok _ -> false
;;

let%test "parse_entry rejects an unknown base preset, not silent default" =
  (* An unknown [base] must fail closed here rather than resolve to
     [default_capabilities] downstream (Agent Core contract §2 rule 4). *)
  let entry = Otoml.Parser.from_string "id_prefix = \"m\"\nbase = \"not_a_preset\"" in
  match parse_entry entry with
  | Error _ -> true
  | Ok _ -> false
;;

let%test "parse_entry accepts a known base preset" =
  let entry = Otoml.Parser.from_string "id_prefix = \"m\"\nbase = \"openai_chat\"" in
  match parse_entry entry with
  | Ok _ -> true
  | Error _ -> false
;;

let parse_table_array toml key parse =
  match Otoml.find_opt toml (Otoml.get_array Fun.id) [ key ] with
  | None -> Ok []
  | Some items ->
    let results = List.map parse items in
    let errors =
      List.filter_map
        (function
          | Error e -> Some e
          | Ok _ -> None)
        results
    in
    if errors <> []
    then Error (String.concat "; " errors)
    else
      Ok
        (List.filter_map
           (function
             | Ok entry -> Some entry
             | Error _ -> None)
           results)
;;

let normalize_label value = String.lowercase_ascii (String.trim value)

let model_row_key (entry : model_entry) =
  Option.map normalize_label entry.provider_name,
  normalize_label (Model_identifiers.Id_prefix.to_string entry.id_prefix)
;;

let provider_entry_key (entry : provider_entry) = normalize_label entry.id

(* Two rows under one key make the winner a property of declaration order.
   They can disagree on any capability or price, so the catalog rejects the
   contradiction instead of silently choosing one. *)
let duplicate_model_label (entry : model_entry) =
  match entry.provider_name with
  | None ->
    Printf.sprintf
      "model row %S"
      (Model_identifiers.Id_prefix.to_string entry.id_prefix)
  | Some provider ->
    Printf.sprintf
      "model row %S for provider %S"
      (Model_identifiers.Id_prefix.to_string entry.id_prefix)
      provider
;;

let reject_duplicate_rows models providers =
  let rec first_dup seen = function
    | [] -> None
    | (key, label) :: rest ->
      if List.mem key seen then Some label else first_dup (key :: seen) rest
  in
  match
    first_dup [] (List.map (fun e -> model_row_key e, duplicate_model_label e) models)
  with
  | Some label -> Error (Printf.sprintf "model catalog declares %s twice" label)
  | None ->
    (match
       first_dup
         []
         (List.map
            (fun (e : provider_entry) ->
               provider_entry_key e, Printf.sprintf "provider row %S" e.id)
            providers)
     with
     | Some label -> Error (Printf.sprintf "model catalog declares %s twice" label)
     | None -> Ok ())
;;

let catalog_of_toml toml =
  match parse_table_array toml "models" parse_entry with
  | Error _ as e -> e
  | Ok models ->
    (match parse_table_array toml "providers" Model_provider_catalog.parse_entry with
     | Error _ as e -> e
     | Ok providers ->
       (match reject_duplicate_rows models providers with
        | Error _ as e -> e
        | Ok () -> Ok { models; providers }))
;;

let parse_catalog ~source parse =
  let parse_res =
    try Ok (parse ()) with
    | Sys_error msg ->
      Error (Printf.sprintf "cannot read model catalog %s: %s" source msg)
    | Otoml.Parse_error (_pos, msg) ->
      Error (Printf.sprintf "model catalog TOML parse error in %s: %s" source msg)
    | Otoml.Type_error _ ->
      Error (Printf.sprintf "model catalog TOML type error in %s" source)
  in
  match parse_res with
  | Error _ as e -> e
  | Ok toml -> catalog_of_toml toml
;;

let of_toml_string ~source contents =
  parse_catalog ~source (fun () -> Otoml.Parser.from_string contents)
;;

let load_file path = parse_catalog ~source:path (fun () -> Otoml.Parser.from_file path)

let load_default () =
  of_toml_string ~source:"embedded default model catalog" Model_catalog_embedded.contents
;;

type lookup_failure =
  | Malformed_model_id of string
  | No_such_row

let lookup_entries_result entries raw_model_id =
  match Model_identifiers.Model_id.of_string raw_model_id with
  | Error detail -> Error (Malformed_model_id detail)
  | Ok model_id ->
    let sorted_t =
      List.fast_sort
        (fun a b ->
           compare
             (String.length (Model_identifiers.Id_prefix.to_string b.id_prefix))
             (String.length (Model_identifiers.Id_prefix.to_string a.id_prefix)))
        entries
    in
    (match
       List.find_opt
         (fun entry -> Model_identifiers.Model_id.starts_with ~prefix:entry.id_prefix model_id)
         sorted_t
     with
     | Some entry -> Ok entry
     | None -> Error No_such_row)
;;

let lookup_result t model_id =
  t.models
  |> List.filter (fun entry -> Option.is_none entry.provider_name)
  |> fun entries -> lookup_entries_result entries model_id
;;

let lookup t model_id =
  match lookup_result t model_id with
  | Ok entry -> Some entry
  | Error No_such_row -> None
  | Error (Malformed_model_id detail) ->
    Log.warn "model catalog lookup refused %S: %s" model_id detail;
    None
;;

(* Wire-kind labels ("openai_compat", "gemini", ...) are what
   [capability_provider_label] synthesizes when a config declares no
   [provider_id]. They stay opaque to alias canonicalization: letting a
   catalog entry claim one as an alias would route every anonymous config of
   that wire kind onto that provider's scoped capabilities/pricing. *)
let wire_kind_labels =
  List.map (fun kind -> Provider_kind.to_string kind) Provider_kind.all
;;

(* Canonical provider label per the catalog's own [[providers]] alias data.
   This applies the alias-to-canonical-id policy the binding registry already
   uses ([Provider_runtime_binding.provider_id_of_provider_config]); the
   capability path previously compared the raw label only, so the same config
   could resolve capabilities on one path and miss on the other. The first
   declaring entry wins and resolution is single-step (a canonical id is
   never re-resolved). Wire-kind labels are never canonicalized. *)
let canonical_provider_name t provider_name =
  let provider_name = normalize_label provider_name in
  if List.mem provider_name wire_kind_labels
  then provider_name
  else (
    let matches (entry : provider_entry) =
      String.equal provider_name (normalize_label entry.id)
      || List.exists
           (fun alias -> String.equal provider_name (normalize_label alias))
           entry.aliases
    in
    match List.find_opt matches t.providers with
    | Some entry -> normalize_label entry.id
    | None -> provider_name)
;;

let provider_entry_for_label t provider_name =
  let requested = normalize_label provider_name in
  if List.mem requested wire_kind_labels
  then None
  else
    List.find_opt
      (fun (entry : provider_entry) ->
         String.equal requested (normalize_label entry.id)
         || List.exists
              (fun alias -> String.equal requested (normalize_label alias))
              entry.aliases)
      t.providers
;;

let lookup_for_provider_result t ~provider_name ~model_id =
  match Model_identifiers.Model_id.of_string model_id with
  | Error detail -> Error (Malformed_model_id detail)
  | Ok model_id ->
    let find_exact label =
      List.find_opt
        (fun entry ->
           match entry.provider_name with
           | None -> false
           | Some declared ->
             String.equal label (normalize_label declared)
             && Model_identifiers.Model_id.equal_id_prefix
                  ~prefix:entry.id_prefix
                  model_id)
        t.models
    in
    let requested = normalize_label provider_name in
    match find_exact requested with
    | Some hit -> Ok hit
    | None ->
      let canonical = canonical_provider_name t requested in
      if String.equal canonical requested
      then Error No_such_row
      else
        (match find_exact canonical with
         | Some hit -> Ok hit
         | None -> Error No_such_row)
;;

let lookup_for_provider t ~provider_name ~model_id =
  match lookup_for_provider_result t ~provider_name ~model_id with
  | Ok entry -> Some entry
  | Error No_such_row -> None
  | Error (Malformed_model_id detail) ->
    Log.warn
      "model catalog provider lookup refused model %S for provider %S: %s"
      model_id
      provider_name
      detail;
    None
;;

let provider_label_for_base_url ?getenv t ~kind ~base_url =
  Model_provider_catalog.provider_label_for_base_url ?getenv t.providers ~kind ~base_url
;;

let provider_label_for_endpoint ?getenv t ~kind ~base_url ~request_path =
  Model_provider_catalog.provider_label_for_endpoint
    ?getenv
    t.providers
    ~kind
    ~base_url
    ~request_path
;;

type default_cache =
  | Unloaded
  | Loaded of t

let load_embedded_catalog () =
  match load_default () with
  | Ok catalog -> catalog
  | Error msg ->
    raise
      (Invalid_embedded_catalog
         (Printf.sprintf "invalid generated embedded model catalog: %s" msg))
;;

let embedded_catalog : default_cache Atomic.t = Atomic.make Unloaded

let load_embedded_once () =
  match Atomic.get embedded_catalog with
  | Loaded value -> value
  | Unloaded ->
    let value = load_embedded_catalog () in
    if Atomic.compare_and_set embedded_catalog Unloaded (Loaded value)
    then value
    else (
      match Atomic.get embedded_catalog with
      | Loaded value -> value
      | Unloaded -> value)
;;

let runtime_override : t option Atomic.t = Atomic.make None

let set_global t = Atomic.set runtime_override (Some t)

let clear_global () =
  Atomic.set runtime_override None;
  Atomic.set embedded_catalog Unloaded
;;

let global () =
  match Atomic.get runtime_override with
  | Some _ as o -> o
  | None ->
    let embedded_value = load_embedded_once () in
    (* Re-read: [set_global] may have landed while the embedded catalog loaded,
       and a full replacement wins over the embedded rows. *)
    (match Atomic.get runtime_override with
     | Some _ as o -> o
     | None -> Some embedded_value)
;;
