module Caps = Capabilities
module PC = Provider_config

type exact_binding_error =
  | Provider_missing
  | Model_missing of Model_catalog.provider_entry

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

let validate_timeout ~target_label ~field = function
  | None -> Ok ()
  | Some value when Float.is_finite value && value > 0. -> Ok ()
  | Some _ -> Error (Printf.sprintf "target %s has invalid %s" target_label field)
;;

let normalize_identity value = String.lowercase_ascii (String.trim value)

let model_identity_key (entry : Model_catalog.model_entry) =
  normalize_identity (Option.value entry.provider_name ~default:"")
  ^ "\x00"
  ^ (Model_identifiers.Model_id.equality_key entry.model_id :> string)
;;

let resolve_exact ~catalog ~provider_ref ~model_id =
  match
    Model_catalog.provider_entries catalog
    |> List.find_opt (fun (entry : Model_catalog.provider_entry) ->
      String.equal entry.id provider_ref)
  with
  | None -> Error Provider_missing
  | Some provider ->
    let requested = Model_identifiers.Model_id.of_string model_id in
    (match
       Model_catalog.model_entries_for_provider catalog
         ~provider:(Model_catalog.Declared_provider provider.id)
       |>
       List.find_opt
         (fun (entry : Model_catalog.model_entry) ->
            match requested with
            | Ok requested -> Model_identifiers.Model_id.equal entry.model_id requested
            | Error _ -> false)
     with
     | None -> Error (Model_missing provider)
     | Some model -> Ok (provider, model))
;;

let compare_model_entries a b =
  String.compare (model_identity_key a) (model_identity_key b)
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
    ; "json_schema_dialect=" ^ Capability_vocab.json_schema_dialect_to_string caps.json_schema_dialect
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


(* [wire] is the provider wire this binding reaches, when its caller knows
   one. A provider row can serve more than one ([[providers]] identity_kinds)
   and name a different capability base per wire, and only the deployment's
   binding says which of them it speaks; the Keeper path reads the same field
   the same way ([Capabilities.apply_catalog_entry]). A caller without a
   binding passes none and gets the row's own base, as every caller did before
   the argument existed. *)
let capabilities_of_catalog_binding ?wire provider (model : Model_catalog.model_entry) =
  let provider_entry = match model.provider_name with
    | None -> None | Some _ -> Some provider in
  Caps.apply_catalog_entry ~provider_entry ~wire model
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
     model_id = \"deepseek/deepseek-v4-flash\"\n\
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
     model_id = \"non-reasoning-model\"\n\
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
     model_id = \"no-tools-model\"\n\
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
    ; "json_schema_dialect=openai_json_schema"
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
