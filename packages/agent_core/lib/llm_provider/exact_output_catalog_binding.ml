module Caps = Capabilities
module PC = Provider_config
module String_map = Map.Make (String)
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
  | PC.Anthropic | PC.Kimi | PC.OpenAI_compat | PC.Ollama | PC.Glm | PC.DashScope ->
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
  | PC.Glm
  | PC.DashScope -> Ok ()
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
  ^ normalize_identity entry.id_prefix
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

let validate_overlay_model_identities ~base ~overlay =
  let base_models =
    List.fold_left
      (fun values (entry : Model_catalog.model_entry) ->
         String_map.add
           (model_identity_key entry)
           (entry.provider_name, entry.id_prefix)
           values)
      String_map.empty
      base
  in
  List.for_all
    (fun (entry : Model_catalog.model_entry) ->
       match String_map.find_opt (model_identity_key entry) base_models with
       | None -> true
       | Some (provider_name, id_prefix) ->
         provider_name = entry.provider_name && String.equal id_prefix entry.id_prefix)
    overlay
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
       List.find_opt
         (fun (entry : Model_catalog.model_entry) ->
            entry.provider_name = Some provider.id
            && String.equal entry.id_prefix model_id)
         model_entries
     with
     | None -> Error Model_missing
     | Some model -> Ok (provider, model))
;;

let compare_model_entries a b =
  String.compare (model_identity_key a) (model_identity_key b)
;;

let prefer_overlay overlay base =
  match overlay with
  | Some _ -> overlay
  | None -> base
;;

(* Sparse row semantics belong only to the immutable exact resolver. The
   process-global catalog keeps whole-row replacement. *)
let merge_exact_model_entry
      ~(base : Model_catalog.model_entry)
      (overlay : Model_catalog.model_entry)
  : Model_catalog.model_entry
  =
  { Model_catalog.id_prefix = overlay.id_prefix
  ; base_label = prefer_overlay overlay.base_label base.base_label
  ; provider_name = overlay.provider_name
  ; max_context_tokens = prefer_overlay overlay.max_context_tokens base.max_context_tokens
  ; serving_constraint = prefer_overlay overlay.serving_constraint base.serving_constraint
  ; max_output_tokens = prefer_overlay overlay.max_output_tokens base.max_output_tokens
  ; supports_tools = prefer_overlay overlay.supports_tools base.supports_tools
  ; supports_tool_choice =
      prefer_overlay overlay.supports_tool_choice base.supports_tool_choice
  ; supports_required_tool_choice =
      prefer_overlay
        overlay.supports_required_tool_choice
        base.supports_required_tool_choice
  ; supports_named_tool_choice =
      prefer_overlay overlay.supports_named_tool_choice base.supports_named_tool_choice
  ; supports_parallel_tool_calls =
      prefer_overlay
        overlay.supports_parallel_tool_calls
        base.supports_parallel_tool_calls
  ; assistant_tool_content_format =
      prefer_overlay
        overlay.assistant_tool_content_format
        base.assistant_tool_content_format
  ; supports_reasoning = prefer_overlay overlay.supports_reasoning base.supports_reasoning
  ; supports_extended_thinking =
      prefer_overlay overlay.supports_extended_thinking base.supports_extended_thinking
  ; supports_reasoning_budget =
      prefer_overlay overlay.supports_reasoning_budget base.supports_reasoning_budget
  ; accepted_reasoning_efforts =
      prefer_overlay overlay.accepted_reasoning_efforts base.accepted_reasoning_efforts
  ; supports_response_format_json =
      prefer_overlay
        overlay.supports_response_format_json
        base.supports_response_format_json
  ; supports_structured_output =
      prefer_overlay overlay.supports_structured_output base.supports_structured_output
  ; supports_multimodal_inputs =
      prefer_overlay overlay.supports_multimodal_inputs base.supports_multimodal_inputs
  ; supports_image_input =
      prefer_overlay overlay.supports_image_input base.supports_image_input
  ; supports_audio_input =
      prefer_overlay overlay.supports_audio_input base.supports_audio_input
  ; supports_video_input =
      prefer_overlay overlay.supports_video_input base.supports_video_input
  ; supports_document_input =
      prefer_overlay overlay.supports_document_input base.supports_document_input
  ; modality_priority = prefer_overlay overlay.modality_priority base.modality_priority
  ; task = prefer_overlay overlay.task base.task
  ; supported_models = prefer_overlay overlay.supported_models base.supported_models
  ; supports_native_streaming =
      prefer_overlay overlay.supports_native_streaming base.supports_native_streaming
  ; supports_system_prompt =
      prefer_overlay overlay.supports_system_prompt base.supports_system_prompt
  ; supports_caching = prefer_overlay overlay.supports_caching base.supports_caching
  ; supports_prompt_caching =
      prefer_overlay overlay.supports_prompt_caching base.supports_prompt_caching
  ; supports_top_k = prefer_overlay overlay.supports_top_k base.supports_top_k
  ; supports_min_p = prefer_overlay overlay.supports_min_p base.supports_min_p
  ; supports_seed = prefer_overlay overlay.supports_seed base.supports_seed
  ; ignored_sampling_parameters =
      prefer_overlay overlay.ignored_sampling_parameters base.ignored_sampling_parameters
  ; supports_computer_use =
      prefer_overlay overlay.supports_computer_use base.supports_computer_use
  ; supports_code_execution =
      prefer_overlay overlay.supports_code_execution base.supports_code_execution
  ; thinking_control_format =
      prefer_overlay overlay.thinking_control_format base.thinking_control_format
  ; anthropic_thinking_control =
      prefer_overlay overlay.anthropic_thinking_control base.anthropic_thinking_control
  ; preserve_thinking_control_format =
      prefer_overlay
        overlay.preserve_thinking_control_format
        base.preserve_thinking_control_format
  ; reasoning_output_format =
      prefer_overlay overlay.reasoning_output_format base.reasoning_output_format
  ; reasoning_streaming_format =
      prefer_overlay overlay.reasoning_streaming_format base.reasoning_streaming_format
  ; reasoning_replay = prefer_overlay overlay.reasoning_replay base.reasoning_replay
  ; input_per_million = prefer_overlay overlay.input_per_million base.input_per_million
  ; output_per_million = prefer_overlay overlay.output_per_million base.output_per_million
  ; cache_write_multiplier =
      prefer_overlay overlay.cache_write_multiplier base.cache_write_multiplier
  ; cache_read_multiplier =
      prefer_overlay overlay.cache_read_multiplier base.cache_read_multiplier
  }
;;

let model_row_key (entry : Model_catalog.model_entry) =
  Option.map normalize_identity entry.provider_name, normalize_identity entry.id_prefix
;;

let merge_exact_model_entries
      ~(base : Model_catalog.model_entry list)
      ~(overlay : Model_catalog.model_entry list)
  =
  let overlay_keys = List.map model_row_key overlay in
  let overlay =
    List.map
      (fun (entry : Model_catalog.model_entry) ->
         match
           List.find_opt
             (fun (base_entry : Model_catalog.model_entry) ->
                model_row_key base_entry = model_row_key entry)
             base
         with
         | None -> entry
         | Some base -> merge_exact_model_entry ~base entry)
      overlay
  in
  overlay
  @ List.filter
      (fun (entry : Model_catalog.model_entry) ->
         not (List.mem (model_row_key entry) overlay_keys))
      base
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
  | Some Caps.Anthropic_manual_budget -> "manual_budget"
  | Some Caps.Anthropic_adaptive_default -> "adaptive_default"
  | Some Caps.Anthropic_adaptive_preferred -> "adaptive_preferred"
  | Some Caps.Anthropic_adaptive_only -> "adaptive_only"
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
  [ "oas-exact-output-functional-capabilities-v2"
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
    ; "task=" ^ task_string caps.task
    ; "supported_models=" ^ supported_models_string caps.supported_models
    ; "anthropic_thinking=" ^ anthropic_thinking_control_string anthropic_thinking_control
    ]
;;

let catalog_anthropic_thinking_control = function
  | None -> None
  | Some Capability_vocab.Manual_budget -> Some Caps.Anthropic_manual_budget
  | Some Capability_vocab.Adaptive_default -> Some Caps.Anthropic_adaptive_default
  | Some Capability_vocab.Adaptive_preferred -> Some Caps.Anthropic_adaptive_preferred
  | Some Capability_vocab.Adaptive_only -> Some Caps.Anthropic_adaptive_only
  | Some Capability_vocab.Always_adaptive -> Some Caps.Anthropic_always_adaptive
;;

let catalog_modality_priority fallback = function
  | None -> fallback
  | Some "preserve_input_order" -> Modality.Preserve_input_order
  | Some "visual_first" -> Modality.Visual_first
  | Some _ -> fallback
;;

let capabilities_of_catalog_binding
      (provider : Model_catalog.provider_entry)
      (model : Model_catalog.model_entry)
  =
  let base_label = prefer_overlay model.base_label provider.capabilities_base in
  let base =
    match Option.bind base_label Caps.capabilities_for_provider_label with
    | Some capabilities -> capabilities
    | None -> Caps.default_capabilities
  in
  let bool_or fallback = Option.value ~default:fallback in
  { base with
    max_context_tokens = prefer_overlay model.max_context_tokens base.max_context_tokens
  ; serving_constraint = prefer_overlay model.serving_constraint base.serving_constraint
  ; max_output_tokens = prefer_overlay model.max_output_tokens base.max_output_tokens
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
  ; task = prefer_overlay model.task base.task
  ; supported_models = prefer_overlay model.supported_models base.supported_models
  }
;;

let%test "exact pricing-only overlay preserves functional fields" =
  let base =
    Model_catalog.of_toml_string
      ~source:"exact pricing base"
      "[[providers]]\n\
       id = \"pricing-provider\"\n\
       kind = \"openai_compat\"\n\
       base_url = \"https://pricing.example\"\n\
       request_path = \"/v1/chat/completions\"\n\
       api_key_env = \"\"\n\
       capabilities_base = \"openai_chat\"\n\
       [[models]]\n\
       id_prefix = \"pricing-model\"\n\
       provider_name = \"pricing-provider\"\n\
       max_context_tokens = 100\n\
       supports_response_format_json = true\n\
       supports_document_input = true\n\
       supported_models = [\"pricing-model\"]\n\
       input_per_million = 1.0\n"
  in
  let overlay =
    Model_catalog.of_toml_string
      ~source:"exact pricing overlay"
      "[[models]]\n\
       id_prefix = \"pricing-model\"\n\
       provider_name = \"pricing-provider\"\n\
       input_per_million = 99.0\n"
  in
  match base, overlay with
  | Ok base, Ok overlay ->
    (match
       ( Model_catalog.provider_entries base
       , Model_catalog.model_entries base
       , merge_exact_model_entries
           ~base:(Model_catalog.model_entries base)
           ~overlay:(Model_catalog.model_entries overlay) )
     with
     | [ provider ], [ base_model ], [ merged_model ] ->
       let base_capabilities = capabilities_of_catalog_binding provider base_model in
       let merged_capabilities = capabilities_of_catalog_binding provider merged_model in
       functional_capability_projection
         base_capabilities
         ~anthropic_thinking_control:
           (catalog_anthropic_thinking_control base_model.anthropic_thinking_control)
       = functional_capability_projection
           merged_capabilities
           ~anthropic_thinking_control:
             (catalog_anthropic_thinking_control merged_model.anthropic_thinking_control)
       && merged_model.max_context_tokens = Some 100
       && merged_model.supports_response_format_json = Some true
       && merged_model.supports_document_input = Some true
       && merged_model.supported_models = Some [ "pricing-model" ]
       && merged_model.input_per_million = Some 99.0
     | _ -> false)
  | Error _, _ | _, Error _ -> false
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
    ~anthropic_thinking_control:(Some Caps.Anthropic_adaptive_preferred)
  = [ "oas-exact-output-functional-capabilities-v2"
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
    ; "task=none"
    ; "supported_models=some:model-a,model-b"
    ; "anthropic_thinking=adaptive_preferred"
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
    ; { base with task = Some Caps.Transcription }
    ; { base with supported_models = Some [ "one" ] }
    ]
  && functional_capability_projection
       base
       ~anthropic_thinking_control:(Some Caps.Anthropic_manual_budget)
     <> baseline
;;

let anthropic_thinking_control_of_model (model : Model_catalog.model_entry) =
  catalog_anthropic_thinking_control model.anthropic_thinking_control
;;
