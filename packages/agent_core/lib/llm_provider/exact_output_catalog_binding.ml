module Caps = Capabilities
module PC = Provider_config
module String_set = Set.Make (String)

type exact_binding_error =
  | Provider_missing
  | Model_missing

type endpoint_error =
  | Malformed_base_url
  | Base_url_userinfo_not_allowed
  | Base_url_query_not_allowed
  | Base_url_fragment_not_allowed
  | Invalid_request_path
  | Unsupported_gemini_request_path
  | Invalid_gemini_model_path

let has_control value =
  String.exists
    (fun character -> Char.code character < 0x20 || Char.code character = 0x7f)
    value
;;

let validate_base_url value =
  if has_control value
  then Error Malformed_base_url
  else if String.contains value '?'
  then Error Base_url_query_not_allowed
  else if String.contains value '#'
  then Error Base_url_fragment_not_allowed
  else (
    let uri = Uri.of_string value in
    match Uri.scheme uri, Uri.host uri with
    | Some ("http" | "https"), Some host when host <> "" ->
      if Option.is_some (Uri.userinfo uri)
      then Error Base_url_userinfo_not_allowed
      else if Uri.query uri <> []
      then Error Base_url_query_not_allowed
      else if Option.is_some (Uri.fragment uri)
      then Error Base_url_fragment_not_allowed
      else Ok ()
    | _ -> Error Malformed_base_url)
;;

let contains_encoded_control value =
  let value = String.lowercase_ascii value in
  List.exists
    (fun encoded ->
       let encoded_length = String.length encoded in
       let rec loop offset =
         offset + encoded_length <= String.length value
         && (String.sub value offset encoded_length = encoded || loop (offset + 1))
       in
       loop 0)
    [ "%00"; "%0a"; "%0d" ]
;;

let validate_request_path ~kind value =
  match kind with
  | PC.Gemini -> if value = "" then Ok () else Error Unsupported_gemini_request_path
  | PC.Anthropic | PC.Kimi | PC.OpenAI_compat | PC.Ollama | PC.Glm ->
    let path_segments = String.split_on_char '/' value in
    if
      value = ""
      || value.[0] <> '/'
      || has_control value
      || contains_encoded_control value
      || String.contains value '%'
      || String.contains value '\\'
      || String.contains value '?'
      || String.contains value '#'
      || List.exists (fun segment -> segment = "." || segment = "..") path_segments
      || List.exists (fun segment -> segment = "") (List.tl path_segments)
    then Error Invalid_request_path
    else Ok ()
;;

let validate_model_path kind model_id =
  match kind with
  | PC.Gemini
    when model_id = ""
         || model_id = "."
         || model_id = ".."
         || not
              (String.for_all
                 (function
                   | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.' | '~' -> true
                   | _ -> false)
                 model_id) -> Error Invalid_gemini_model_path
  | PC.Gemini
  | PC.Anthropic
  | PC.Kimi
  | PC.OpenAI_compat
  | PC.Ollama
  | PC.Glm -> Ok ()
;;

let target_string_field ~target_label ~field toml =
  match Otoml.find_opt toml Otoml.get_string [ field ] with
  | None -> Error (Printf.sprintf "target %s misses %s" target_label field)
  | Some value when value = "" || String.trim value <> value || has_control value ->
    Error (Printf.sprintf "target %s has invalid %s" target_label field)
  | Some value -> Ok value
  | exception Otoml.Type_error _ ->
    Error (Printf.sprintf "target %s has non-string %s" target_label field)
;;

let target_float_field ~target_label ~field toml =
  match Otoml.find_opt toml Otoml.get_float [ field ] with
  | None -> Ok None
  | Some value -> Ok (Some value)
  | exception Otoml.Type_error _ ->
    Error (Printf.sprintf "target %s has non-float %s" target_label field)
;;

let target_bool_field ~target_label ~field toml =
  match Otoml.find_opt toml Otoml.get_boolean [ field ] with
  | None -> Ok None
  | Some value -> Ok (Some value)
  | exception Otoml.Type_error _ ->
    Error (Printf.sprintf "target %s has non-boolean %s" target_label field)
;;

let target_positive_int_field ~target_label ~field toml =
  match Otoml.find_opt toml Otoml.get_integer [ field ] with
  | None -> Ok None
  | Some value when value >= 1 -> Ok (Some value)
  | Some _ -> Error (Printf.sprintf "target %s has invalid %s" target_label field)
  | exception Otoml.Type_error _ ->
    Error (Printf.sprintf "target %s has non-integer %s" target_label field)
;;

let validate_timeout ~target_label ~field = function
  | None -> Ok ()
  | Some value when Float.is_finite value && value > 0. -> Ok ()
  | Some _ -> Error (Printf.sprintf "target %s has invalid %s" target_label field)
;;

let normalize_identity value = String.lowercase_ascii (String.trim value)

let model_identity_key (entry : Model_catalog.model_entry) =
  normalize_identity (Option.value entry.provider_name ~default:"")
  ^ "\x00"
  ^ (Model_identifiers.Id_prefix.equality_key entry.id_prefix :> string)
;;

let model_identities_unique entries =
  let rec loop seen = function
    | [] -> true
    | entry :: rest ->
      let identity = model_identity_key entry in
      if String_set.mem identity seen
      then false
      else loop (String_set.add identity seen) rest
  in
  loop String_set.empty entries
;;

let resolve_exact ~catalog ~model_entries ~provider_ref ~model_id =
  match
    Model_catalog.provider_entries catalog
    |> List.find_opt (fun (entry : Model_catalog.provider_entry) ->
      String.equal entry.id provider_ref)
  with
  | None -> Error Provider_missing
  | Some provider ->
    (match
       Model_catalog.model_entries_for_provider catalog
         ~provider:(Model_catalog.Declared_provider provider.id) ~model_entries
       |>
       List.find_opt
         (fun (entry : Model_catalog.model_entry) ->
            String.equal
                 (Model_identifiers.Id_prefix.to_string entry.id_prefix)
                 model_id)
     with
     | None -> Error Model_missing
     | Some model -> Ok (provider, model))
;;

let compare_model_entries a b =
  String.compare (model_identity_key a) (model_identity_key b)
;;

let first_some preferred fallback =
  match preferred with
  | Some _ -> preferred
  | None -> fallback
;;

let option_int = function
  | None -> "none"
  | Some value -> "some:" ^ string_of_int value
;;

let bool_string value = if value then "1" else "0"

let modality_priority_string = function
  | Modality.Preserve_input_order -> "preserve_input_order"
  | Modality.Visual_first -> "visual_first"
;;

let task_string = function
  | None -> "none"
  | Some Caps.Transcription -> "transcription"
  | Some Caps.Speech -> "speech"
  | Some Caps.Image_generation -> "image_generation"
  | Some Caps.Video_generation -> "video_generation"
;;

let anthropic_thinking_control_string = function
  | None -> "none"
  | Some Caps.Anthropic_adaptive_default -> "adaptive_default"
  | Some Caps.Anthropic_adaptive_disabled_through_high -> "adaptive_disabled_through_high"
  | Some Caps.Anthropic_adaptive_between_tools -> "adaptive_between_tools"
  | Some Caps.Anthropic_always_adaptive -> "always_adaptive"
;;

let target_model_admitted (caps : Caps.capabilities) ~model_id =
  match caps.supported_models with
  | None -> true
  | Some models -> List.exists (String.equal model_id) models
;;

let supported_models_string = function
  | None -> "none"
  | Some models -> "some:" ^ String.concat "," (List.sort_uniq String.compare models)
;;

let functional_capability_projection
      (caps : Caps.capabilities)
      ~anthropic_thinking_control
  =
  let serving_constraint =
    match caps.serving_constraint with
    | None -> [ "serving_constraint=none" ]
    | Some constraint_ ->
      "serving_constraint=some"
      :: List.map
           (fun part -> "serving_constraint." ^ part)
           (Serving_constraint.fingerprint_parts constraint_)
  in
  [ "agent_core-exact-output-functional-capabilities-v2"
  ; "max_context=" ^ option_int caps.max_context_tokens
  ]
  @ serving_constraint
  @ [ "max_output=" ^ option_int caps.max_output_tokens
    ; "json_mode=" ^ bool_string caps.supports_response_format_json
    ; "native_schema=" ^ bool_string caps.supports_structured_output
    ; "multimodal=" ^ bool_string caps.supports_multimodal_inputs
    ; "image=" ^ bool_string caps.supports_image_input
    ; "audio=" ^ bool_string caps.supports_audio_input
    ; "video=" ^ bool_string caps.supports_video_input
    ; "document=" ^ bool_string caps.supports_document_input
    ; "modality_priority=" ^ modality_priority_string caps.modality_priority
    ; "system_prompt=" ^ bool_string caps.supports_system_prompt
    ; "assistant_prefill=" ^ bool_string caps.supports_assistant_prefill
    ; "task=" ^ task_string caps.task
    ; "supported_models=" ^ supported_models_string caps.supported_models
    ; "anthropic_thinking=" ^ anthropic_thinking_control_string anthropic_thinking_control
    ]
;;

let catalog_anthropic_thinking_control =
  Option.map Caps.anthropic_thinking_control_of_vocab_value
;;

let catalog_modality_priority fallback = function
  | None -> fallback
  | Some "preserve_input_order" -> Modality.Preserve_input_order
  | Some "visual_first" -> Modality.Visual_first
  | Some _ -> fallback
;;

(* [wire] is the provider wire this binding reaches, when its caller knows
   one. A provider row can serve more than one ([[providers]] identity_kinds)
   and name a different capability base per wire, and only the deployment's
   binding says which of them it speaks; the Keeper path reads the same field
   the same way ([Capabilities.apply_catalog_entry]). A caller without a
   binding passes none and gets the row's own base, as every caller did before
   the argument existed. *)
let capabilities_of_catalog_binding
      ?wire
      (provider : Model_catalog.provider_entry)
      (model : Model_catalog.model_entry)
  =
  let wire_base =
    match model.provider_name with
    | None -> None
    | Some _ ->
      Option.bind wire (fun kind ->
        List.assoc_opt kind provider.Model_catalog.capabilities_base_by_identity_kind)
  in
  let base_label =
    match wire_base with
    | Some _ -> wire_base
    | None ->
      (match model.provider_name with
       | None -> model.base_label
       | Some _ -> first_some model.base_label provider.capabilities_base)
  in
  let base =
    match Option.bind base_label Caps.capabilities_for_provider_label with
    | Some capabilities -> capabilities
    | None -> Caps.default_capabilities
  in
  let bool_or fallback = Option.value ~default:fallback in
  let supports_tool_choice = bool_or base.supports_tool_choice model.supports_tool_choice in
  let supports_required_tool_choice =
    match model.supports_required_tool_choice with
    | Some required -> required && supports_tool_choice
    | None -> base.supports_required_tool_choice && supports_tool_choice
  in
  let supports_named_tool_choice =
    match model.supports_named_tool_choice with
    | Some named -> named && supports_tool_choice
    | None -> base.supports_named_tool_choice && supports_tool_choice
  in
  let supports_reasoning = bool_or base.supports_reasoning model.supports_reasoning in
  let accepted_reasoning_efforts =
    if not supports_reasoning then None
    else
      match model.accepted_reasoning_efforts with
      | Some values ->
        let efforts = List.filter_map Reasoning_effort.of_string values in
        Some efforts
      | None -> base.accepted_reasoning_efforts
  in
  let thinking_control_format =
    match model.thinking_control_format with
    | Some format -> (format : Caps.thinking_control_format)
    | None -> base.thinking_control_format
  in
  let assistant_tool_content_format =
    match
      Option.bind
        model.assistant_tool_content_format
        Capability_vocab.assistant_tool_content_format_of_string
    with
    | Some format -> format
    | None -> base.assistant_tool_content_format
  in
  let chat_output_budget_field =
    match
      Option.bind
        model.chat_output_budget_field
        Capability_vocab.chat_output_budget_field_of_string
    with
    | Some field -> field
    | None -> base.chat_output_budget_field
  in
  let tool_schema_conformance =
    match
      Option.bind
        model.tool_schema_conformance
        Capability_vocab.tool_schema_conformance_of_string
    with
    | Some conformance -> conformance
    | None -> base.tool_schema_conformance
  in
  let preserve_thinking_control_format =
    match
      Option.bind
        model.preserve_thinking_control_format
        Capability_vocab.preserve_thinking_control_format_of_string
    with
    | Some format -> format
    | None -> base.preserve_thinking_control_format
  in
  let content_inline_reasoning =
    match
      Option.bind
        model.content_inline_reasoning
        Capability_vocab.content_inline_reasoning_of_string
    with
    | Some format -> format
    | None -> base.content_inline_reasoning
  in
  let reasoning_output_format =
    match
      Option.bind
        model.reasoning_output_format
        Capability_vocab.reasoning_output_format_of_string
    with
    | Some format -> format
    | None -> base.reasoning_output_format
  in
  let reasoning_streaming_format =
    match
      Option.bind
        model.reasoning_streaming_format
        Capability_vocab.reasoning_streaming_format_of_string
    with
    | Some format -> format
    | None -> base.reasoning_streaming_format
  in
  let reasoning_replay_override =
    match
      Option.bind
        model.reasoning_replay
        Capability_vocab.reasoning_replay_override_of_string
    with
    | Some replay -> replay
    | None -> base.reasoning_replay_override
  in
  let ignored_sampling_parameters =
    match model.ignored_sampling_parameters with
    | Some params -> params
    | None -> base.ignored_sampling_parameters
  in
  { base with
    max_context_tokens = first_some model.max_context_tokens base.max_context_tokens
  ; serving_constraint = first_some model.serving_constraint base.serving_constraint
  ; max_output_tokens = first_some model.max_output_tokens base.max_output_tokens
  ; supports_reasoning
  ; accepted_reasoning_efforts
  ; thinking_control_format
  ; preserve_thinking_control_format
  ; content_inline_reasoning
  ; reasoning_output_format
  ; reasoning_streaming_format
  ; reasoning_replay_override
  ; supports_tools = bool_or base.supports_tools model.supports_tools
  ; supports_tool_choice
  ; supports_required_tool_choice
  ; supports_named_tool_choice
  ; assistant_tool_content_format
  ; chat_output_budget_field
  ; tool_schema_conformance
  ; supports_parallel_tool_calls =
      bool_or base.supports_parallel_tool_calls model.supports_parallel_tool_calls
  ; supports_response_format_json =
      bool_or base.supports_response_format_json model.supports_response_format_json
  ; supports_structured_output =
      bool_or base.supports_structured_output model.supports_structured_output
  ; supports_multimodal_inputs =
      bool_or base.supports_multimodal_inputs model.supports_multimodal_inputs
  ; supports_image_input = bool_or base.supports_image_input model.supports_image_input
  ; supports_audio_input = bool_or base.supports_audio_input model.supports_audio_input
  ; supports_video_input = bool_or base.supports_video_input model.supports_video_input
  ; supports_document_input =
      bool_or base.supports_document_input model.supports_document_input
  ; modality_priority =
      catalog_modality_priority base.modality_priority model.modality_priority
  ; supports_system_prompt =
      bool_or base.supports_system_prompt model.supports_system_prompt
  ; supports_native_streaming =
      bool_or base.supports_native_streaming model.supports_native_streaming
  ; supports_assistant_prefill =
      bool_or base.supports_assistant_prefill model.supports_assistant_prefill
  ; supports_prompt_caching =
      bool_or base.supports_prompt_caching model.supports_prompt_caching
  ; supports_top_k = bool_or base.supports_top_k model.supports_top_k
  ; supports_min_p = bool_or base.supports_min_p model.supports_min_p
  ; supports_seed = bool_or base.supports_seed model.supports_seed
  ; ignored_sampling_parameters
  ; task = first_some model.task base.task
  ; supported_models = first_some model.supported_models base.supported_models
  }
;;

let%test "exact catalog binding preserves reasoning efforts and thinking control" =
  let toml =
    "[[providers]]\n\
     id = \"openrouter\"\n\
     kind = \"openai_compat\"\n\
     base_url = \"https://openrouter.ai/api/v1\"\n\
     request_path = \"/chat/completions\"\n\
     auth = \"none\"\n\
     capabilities_base = \"openai_chat_extended\"\n\
     [[models]]\n\
     id_prefix = \"deepseek/deepseek-v4-flash\"\n\
     provider_name = \"openrouter\"\n\
     accepted_reasoning_efforts = [\"none\", \"low\", \"high\"]\n\
     thinking_control_format = \"reasoning_effort\"\n\
     supports_reasoning = true\n"
  in
  match Model_catalog.of_toml_string ~source:"reasoning test" toml with
  | Ok catalog ->
    (match Model_catalog.provider_entries catalog, Model_catalog.model_entries catalog with
     | [ provider ], [ model ] ->
       let caps = capabilities_of_catalog_binding provider model in
       caps.supports_reasoning = true
       && caps.thinking_control_format = Caps.Reasoning_effort
       && caps.accepted_reasoning_efforts
          = Some [ Reasoning_effort.None_; Reasoning_effort.Low; Reasoning_effort.High ]
     | _ -> false)
  | Error _ -> false
;;

let%test "exact catalog binding clears reasoning efforts when reasoning is unsupported" =
  let toml =
    "[[providers]]\n\
     id = \"openrouter\"\n\
     kind = \"openai_compat\"\n\
     base_url = \"https://openrouter.ai/api/v1\"\n\
     request_path = \"/chat/completions\"\n\
     auth = \"none\"\n\
     capabilities_base = \"openai_chat_extended\"\n\
     [[models]]\n\
     id_prefix = \"non-reasoning-model\"\n\
     provider_name = \"openrouter\"\n\
     accepted_reasoning_efforts = [\"low\", \"high\"]\n\
     supports_reasoning = false\n"
  in
  match Model_catalog.of_toml_string ~source:"non-reasoning test" toml with
  | Ok catalog ->
    (match Model_catalog.provider_entries catalog, Model_catalog.model_entries catalog with
     | [ provider ], [ model ] ->
       let caps = capabilities_of_catalog_binding provider model in
       caps.supports_reasoning = false
       && caps.accepted_reasoning_efforts = None
     | _ -> false)
  | Error _ -> false
;;

let%test "exact catalog binding gates forced tool choice on supports_tool_choice" =
  let toml =
    "[[providers]]\n\
     id = \"ollama\"\n\
     kind = \"openai_compat\"\n\
     base_url = \"http://127.0.0.1:11434\"\n\
     request_path = \"/v1/chat/completions\"\n\
     auth = \"none\"\n\
     capabilities_base = \"openai_chat\"\n\
     [[models]]\n\
     id_prefix = \"no-tools-model\"\n\
     provider_name = \"ollama\"\n\
     supports_tool_choice = false\n\
     supports_required_tool_choice = true\n\
     supports_named_tool_choice = true\n"
  in
  match Model_catalog.of_toml_string ~source:"tool choice gating test" toml with
  | Ok catalog ->
    (match Model_catalog.provider_entries catalog, Model_catalog.model_entries catalog with
     | [ provider ], [ model ] ->
       let caps = capabilities_of_catalog_binding provider model in
       caps.supports_tool_choice = false
       && caps.supports_required_tool_choice = false
       && caps.supports_named_tool_choice = false
     | _ -> false)
  | Error _ -> false
;;

let%test "exact functional capability projection has a stable golden" =
  let fixture =
    { Caps.default_capabilities with
      max_context_tokens = Some 8
    ; max_output_tokens = Some 3
    ; supports_response_format_json = true
    ; supports_structured_output = false
    ; supports_multimodal_inputs = true
    ; supports_image_input = true
    ; supports_audio_input = false
    ; supports_video_input = false
    ; supports_document_input = true
    ; modality_priority = Modality.Visual_first
    ; supports_system_prompt = true
    ; task = None
    ; supported_models = Some [ "model-b"; "model-a" ]
    }
  in
  functional_capability_projection
    fixture
    ~anthropic_thinking_control:(Some Caps.Anthropic_adaptive_default)
  = [ "agent_core-exact-output-functional-capabilities-v2"
    ; "max_context=some:8"
    ; "serving_constraint=none"
    ; "max_output=some:3"
    ; "json_mode=1"
    ; "native_schema=0"
    ; "multimodal=1"
    ; "image=1"
    ; "audio=0"
    ; "video=0"
    ; "document=1"
    ; "modality_priority=visual_first"
    ; "system_prompt=1"
    ; "assistant_prefill=1"
    ; "task=none"
    ; "supported_models=some:model-a,model-b"
    ; "anthropic_thinking=adaptive_default"
    ]
;;

let%test "exact functional capability projection is field-sensitive" =
  let base = Caps.default_capabilities in
  let baseline = functional_capability_projection base ~anthropic_thinking_control:None in
  List.for_all
    (fun changed ->
       functional_capability_projection changed ~anthropic_thinking_control:None
       <> baseline)
    [ { base with max_context_tokens = Some 1 }
    ; { base with max_output_tokens = Some 1 }
    ; { base with supports_response_format_json = true }
    ; { base with supports_structured_output = true }
    ; { base with supports_multimodal_inputs = true }
    ; { base with supports_image_input = true }
    ; { base with supports_audio_input = true }
    ; { base with supports_video_input = true }
    ; { base with supports_document_input = true }
    ; { base with modality_priority = Modality.Visual_first }
    ; { base with supports_system_prompt = not base.supports_system_prompt }
    ; { base with supports_assistant_prefill = not base.supports_assistant_prefill }
    ; { base with task = Some Caps.Transcription }
    ; { base with supported_models = Some [ "one" ] }
    ]
  && functional_capability_projection
       base
       ~anthropic_thinking_control:(Some Caps.Anthropic_always_adaptive)
     <> baseline
;;

let anthropic_thinking_control_of_model (model : Model_catalog.model_entry) =
  catalog_anthropic_thinking_control model.anthropic_thinking_control
;;
