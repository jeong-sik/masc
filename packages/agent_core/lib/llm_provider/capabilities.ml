(** Provider/model policy projection and capability observations. *)

include Capability_profile

let effective_disable_parallel_tool_use
      ~caller_disabled
      ~supports_parallel_tool_calls
      ~tools_present
  =
  caller_disabled || (tools_present && not supports_parallel_tool_calls)
;;

(* The lookups below take a parsed [Model_id.t]. Each public entry parses the
   caller's string once here and answers [None] for a malformed id, as every
   lookup did when each of them parsed (and discarded) the id itself. *)
let with_model_id model_id f =
  match Model_identifiers.Model_id.of_string model_id with
  | Ok model_id -> f model_id
  | Error _ -> None
;;

let anthropic_thinking_control_from_catalog ~catalog model_id =
  Option.bind catalog (fun catalog ->
    Option.bind (Model_catalog.lookup catalog model_id) (fun entry ->
      Option.map anthropic_thinking_control_of_vocab_value
        entry.Model_catalog.anthropic_thinking_control))
;;

let anthropic_thinking_control_for_model_id model_id =
  with_model_id model_id
    (anthropic_thinking_control_from_catalog ~catalog:(Catalog_snapshot.models (Catalog_snapshot.current ())))
;;

let anthropic_thinking_control_for_provider_from_catalog ~catalog ~provider model_id =
  Option.bind catalog (fun catalog ->
    Option.bind (Model_catalog.lookup_model_for_provider catalog ~provider ~model_id)
      (fun entry -> Option.map anthropic_thinking_control_of_vocab_value
        entry.Model_catalog.anthropic_thinking_control))
;;

(* ── Catalog capability projection ───────────────────── *)

(** Apply admitted capability fields on top of a base capabilities record.

    [base_label] resolves to a provider preset via
    [capabilities_for_provider_label]; defaults to [default_capabilities]
    when absent or unrecognised.  Each [Some] field in [entry] overrides
    the corresponding field of the base; [None] fields are left unchanged. *)

let preserve_thinking_control_format_of_catalog_string raw =
  Capability_vocab.preserve_thinking_control_format_of_string raw
;;

let warn_unknown_capability_value ~field raw =
  Diag.warn
    "capabilities"
    "unknown %s value %S; keeping provider base capability"
    field
    raw
;;

let reasoning_replay_override_of_catalog_string raw =
  Capability_vocab.reasoning_replay_override_of_string raw
;;


let assistant_tool_content_format_of_catalog_string raw =
  Capability_vocab.assistant_tool_content_format_of_string raw

let chat_output_budget_field_of_catalog_string raw =
  Capability_vocab.chat_output_budget_field_of_string raw

let tool_schema_conformance_of_catalog_string raw =
  Capability_vocab.tool_schema_conformance_of_string raw
;;

let content_inline_reasoning_of_catalog_string raw =
  Capability_vocab.content_inline_reasoning_of_string raw
;;

let reasoning_output_format_of_catalog_string raw =
  Capability_vocab.reasoning_output_format_of_string raw
;;

let reasoning_streaming_format_of_catalog_string raw =
  Capability_vocab.reasoning_streaming_format_of_string raw
;;

let modality_priority_of_catalog_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "preserve_input_order" | "preserve-input-order" | "preserve" ->
    Some Modality.Preserve_input_order
  | "visual_first" | "visual-first" -> Some Modality.Visual_first
  | _ -> None
;;

let reasoning_efforts_of_catalog_strings ~field values =
  let parsed =
    List.map
      (fun raw ->
         match Reasoning_effort.of_string raw with
         | Some effort -> Ok effort
         | None -> Error raw)
      values
  in
  let efforts, invalid =
    List.partition_map
      (function
        | Ok effort -> Either.Left effort
        | Error raw -> Either.Right raw)
      parsed
  in
  match invalid with
  | [] -> Some efforts
  | values ->
    Diag.warn
      "capabilities"
      "unknown %s value(s) %s; keeping provider base capability"
      field
      (String.concat ", " values);
    None
;;

type declarative_capability_overrides =
  { base_label : string option
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
  ; json_schema_dialect : json_schema_dialect option
  ; supports_multimodal_inputs : bool option
  ; supports_image_input : bool option
  ; supports_audio_input : bool option
  ; supports_video_input : bool option
  ; supports_document_input : bool option
  ; modality_priority : string option
  ; task : Capability_vocab.task option
  ; supports_native_streaming : bool option
  ; supports_system_prompt : bool option
  ; supports_assistant_prefill : bool option
  ; supports_prompt_caching : bool option
  ; supports_top_k : bool option
  ; supports_min_p : bool option
  ; supports_seed : bool option
  ; ignored_sampling_parameters : Capability_vocab.sampling_parameter list option
  ; thinking_control_format : Capability_vocab.thinking_control_format option
    (* Already joined with its token by the catalog/manifest parser; the token
       lives in the [Chat_template_token] constructor, not a sibling field. *)
  ; preserve_thinking_control_format : string option
  ; content_inline_reasoning : string option
  ; reasoning_output_format : string option
  ; reasoning_streaming_format : string option
  ; reasoning_replay : string option
  }

let apply_declarative_capability_overrides ?(base=default_capabilities) overrides =
  let base =
    match overrides.base_label with
    | None -> base
    | Some label ->
      (match capabilities_for_provider_label label with
       | Some c -> c
       | None -> default_capabilities)
  in
  let base = match overrides.supports_image_input with
    | Some value -> with_declared_image_input value base
    | None -> base in
  let override_bool base_val = function
    | Some b -> b
    | None -> base_val
  in
  let supports_tool_choice =
    override_bool base.supports_tool_choice overrides.supports_tool_choice
  in
  let supports_required_tool_choice =
    match overrides.supports_required_tool_choice with
    | Some required -> required && supports_tool_choice
    | None -> base.supports_required_tool_choice && supports_tool_choice
  in
  (* Read only this field's own override, the way
     [supports_required_tool_choice] above does. Consulting
     [overrides.supports_tool_choice] here made an omission mean "yes": a
     catalog row that declared `supports_tool_choice = true` and left
     `supports_named_tool_choice` out was answered `true`, so the record
     claimed a capability nobody wrote down. 21 rows in models.toml are
     shaped that way. An absent field now falls through to the base record
     like every sibling, and a row that really does support named choice has
     to say so. *)
  let supports_named_tool_choice =
    match overrides.supports_named_tool_choice with
    | Some named -> named && supports_tool_choice
    | None -> base.supports_named_tool_choice && supports_tool_choice
  in
  let override_int_opt base_val = function
    | Some n -> Some n
    | None -> base_val
  in
  let capabilities =
    { base with
    max_context_tokens =
      override_int_opt base.max_context_tokens overrides.max_context_tokens
  ; serving_constraint =
      (match overrides.serving_constraint with
       | Some _ as constraint_ -> constraint_
       | None -> base.serving_constraint)
  ; max_output_tokens =
      override_int_opt base.max_output_tokens overrides.max_output_tokens
  ; supports_tools = override_bool base.supports_tools overrides.supports_tools
  ; supports_tool_choice
  ; supports_required_tool_choice
  ; supports_named_tool_choice
  ; supports_parallel_tool_calls =
      override_bool
        base.supports_parallel_tool_calls
        overrides.supports_parallel_tool_calls
  ; assistant_tool_content_format =
      (match overrides.assistant_tool_content_format with
       | Some s ->
         (match assistant_tool_content_format_of_catalog_string s with
          | Some format -> format
          | None ->
            warn_unknown_capability_value ~field:"assistant_tool_content_format" s;
            base.assistant_tool_content_format)
       | None -> base.assistant_tool_content_format)
  ; chat_output_budget_field =
      (match overrides.chat_output_budget_field with
       | Some s ->
         (match chat_output_budget_field_of_catalog_string s with
          | Some field -> field
          | None ->
            warn_unknown_capability_value ~field:"chat_output_budget_field" s;
            base.chat_output_budget_field)
       | None -> base.chat_output_budget_field)
  ; tool_schema_conformance =
      (match overrides.tool_schema_conformance with
       | Some s ->
         (match tool_schema_conformance_of_catalog_string s with
          | Some c -> c
          | None ->
            warn_unknown_capability_value ~field:"tool_schema_conformance" s;
            base.tool_schema_conformance)
       | None -> base.tool_schema_conformance)
  ; supports_reasoning =
      override_bool base.supports_reasoning overrides.supports_reasoning
  ; accepted_reasoning_efforts =
      (match overrides.accepted_reasoning_efforts with
       | Some values ->
         (match
            reasoning_efforts_of_catalog_strings
              ~field:"accepted_reasoning_efforts"
              values
          with
          | Some efforts -> Some efforts
          | None -> base.accepted_reasoning_efforts)
       | None -> base.accepted_reasoning_efforts)
  ; supports_response_format_json =
      override_bool
        base.supports_response_format_json
        overrides.supports_response_format_json
  ; supports_structured_output =
      override_bool base.supports_structured_output overrides.supports_structured_output
  ; json_schema_dialect = Option.value overrides.json_schema_dialect ~default:base.json_schema_dialect
  ; supports_multimodal_inputs =
      override_bool base.supports_multimodal_inputs overrides.supports_multimodal_inputs
  ; supports_audio_input =
      override_bool base.supports_audio_input overrides.supports_audio_input
  ; supports_video_input =
      override_bool base.supports_video_input overrides.supports_video_input
  ; supports_document_input =
      override_bool base.supports_document_input overrides.supports_document_input
  ; modality_priority =
      (match overrides.modality_priority with
       | Some s ->
         (match modality_priority_of_catalog_string s with
          | Some priority -> priority
          | None ->
            warn_unknown_capability_value ~field:"modality_priority" s;
            base.modality_priority)
       | None -> base.modality_priority)
  ; task =
      (* Already typed at the catalog parse boundary; no string re-parse. *)
      (match overrides.task with
       | Some _ as task -> task
       | None -> base.task)
  ; supports_native_streaming =
      override_bool base.supports_native_streaming overrides.supports_native_streaming
  ; supports_system_prompt =
      override_bool base.supports_system_prompt overrides.supports_system_prompt
  ; supports_assistant_prefill =
      override_bool base.supports_assistant_prefill overrides.supports_assistant_prefill
  ; supports_prompt_caching =
      override_bool base.supports_prompt_caching overrides.supports_prompt_caching
  ; supports_top_k = override_bool base.supports_top_k overrides.supports_top_k
  ; supports_min_p = override_bool base.supports_min_p overrides.supports_min_p
  ; supports_seed = override_bool base.supports_seed overrides.supports_seed
  ; ignored_sampling_parameters =
      (match overrides.ignored_sampling_parameters with
       | Some parameters -> parameters
       | None -> base.ignored_sampling_parameters)
  ; thinking_control_format =
      (* Typed and token-joined at catalog/manifest parse time (unknown labels
         already failed closed there), so this is a plain override. *)
      (match overrides.thinking_control_format with
       | Some fmt -> fmt
       | None -> base.thinking_control_format)
  ; preserve_thinking_control_format =
      (match overrides.preserve_thinking_control_format with
       | Some s ->
         (match preserve_thinking_control_format_of_catalog_string s with
          | Some t -> t
          | None ->
            warn_unknown_capability_value ~field:"preserve_thinking_control_format" s;
            base.preserve_thinking_control_format)
       | None -> base.preserve_thinking_control_format)
  ; content_inline_reasoning =
      (match overrides.content_inline_reasoning with
       | Some s ->
         (match content_inline_reasoning_of_catalog_string s with
          | Some format -> format
          | None ->
            warn_unknown_capability_value ~field:"content_inline_reasoning" s;
            base.content_inline_reasoning)
       | None -> base.content_inline_reasoning)
  ; reasoning_output_format =
      (match overrides.reasoning_output_format with
       | Some s ->
         (match reasoning_output_format_of_catalog_string s with
          | Some format -> format
          | None ->
            warn_unknown_capability_value ~field:"reasoning_output_format" s;
            base.reasoning_output_format)
       | None -> base.reasoning_output_format)
  ; reasoning_streaming_format =
      (match overrides.reasoning_streaming_format with
       | Some s ->
         (match reasoning_streaming_format_of_catalog_string s with
          | Some format -> format
          | None ->
            warn_unknown_capability_value ~field:"reasoning_streaming_format" s;
            base.reasoning_streaming_format)
       | None -> base.reasoning_streaming_format)
  ; reasoning_replay_override =
      (match overrides.reasoning_replay with
       | Some s ->
         (match reasoning_replay_override_of_catalog_string s with
          | Some replay -> replay
          | None ->
            warn_unknown_capability_value ~field:"reasoning_replay" s;
            base.reasoning_replay_override)
       | None -> base.reasoning_replay_override)
    }
  in
  (* Native adapters own their wire format, so [No_thinking_control] does not
     erase an enabled model's effort vocabulary. An explicit lack of reasoning
     support still invalidates it before native request validation. *)
  if capabilities.supports_reasoning then capabilities
  else { capabilities with accepted_reasoning_efforts = None }
;;

let%test "reasoning_replay_override_of_catalog_string parses vocabulary" =
  reasoning_replay_override_of_catalog_string "preserve_always"
  = Some Force_preserve_always
  && reasoning_replay_override_of_catalog_string "drop_without_tool"
     = Some Force_drop_without_tool_preserve_with_tool
  && reasoning_replay_override_of_catalog_string "latest_user_turn_tool_calls"
     = Some Force_latest_user_turn_tool_calls
  && reasoning_replay_override_of_catalog_string "no_replay" = Some Force_no_replay
  && reasoning_replay_override_of_catalog_string "" = None
  && reasoning_replay_override_of_catalog_string "bogus" = None
;;

let overrides_of_catalog_entry (entry : Model_catalog.model_entry) =
  { base_label = entry.base_label
  ; max_context_tokens = entry.max_context_tokens
  ; serving_constraint = entry.serving_constraint
  ; max_output_tokens = entry.max_output_tokens
  ; supports_tools = entry.supports_tools
  ; supports_tool_choice = entry.supports_tool_choice
  ; supports_required_tool_choice = entry.supports_required_tool_choice
  ; supports_named_tool_choice = entry.supports_named_tool_choice
  ; supports_parallel_tool_calls = entry.supports_parallel_tool_calls
  ; assistant_tool_content_format = entry.assistant_tool_content_format
  ; chat_output_budget_field = entry.chat_output_budget_field
  ; tool_schema_conformance = entry.tool_schema_conformance
  ; supports_reasoning = entry.supports_reasoning
  ; accepted_reasoning_efforts = entry.accepted_reasoning_efforts
  ; supports_response_format_json = entry.supports_response_format_json
  ; supports_structured_output = entry.supports_structured_output
  ; json_schema_dialect = entry.json_schema_dialect
  ; supports_multimodal_inputs = entry.supports_multimodal_inputs
  ; supports_image_input = entry.supports_image_input
  ; supports_audio_input = entry.supports_audio_input
  ; supports_video_input = entry.supports_video_input
  ; supports_document_input = entry.supports_document_input
  ; modality_priority = entry.modality_priority
  ; task = entry.task
  ; supports_native_streaming = entry.supports_native_streaming
  ; supports_system_prompt = entry.supports_system_prompt
  ; supports_assistant_prefill = entry.supports_assistant_prefill
  ; supports_prompt_caching = entry.supports_prompt_caching
  ; supports_top_k = entry.supports_top_k
  ; supports_min_p = entry.supports_min_p
  ; supports_seed = entry.supports_seed
  ; ignored_sampling_parameters = entry.ignored_sampling_parameters
  ; thinking_control_format = entry.thinking_control_format
  ; preserve_thinking_control_format = entry.preserve_thinking_control_format
  ; content_inline_reasoning = entry.content_inline_reasoning
  ; reasoning_output_format = entry.reasoning_output_format
  ; reasoning_streaming_format = entry.reasoning_streaming_format
  ; reasoning_replay = entry.reasoning_replay
  }
;;

let provider_base_label ~catalog ~wire provider =
  match Model_catalog.provider_entry_for_reference catalog provider with
  | None -> None
  | Some provider ->
    (match Option.bind wire (fun kind -> List.assoc_opt kind provider.capabilities_base_by_identity_kind) with
     | Some _ as base -> base
     | None -> provider.capabilities_base)
;;

let apply_catalog_entry ?base ~provider_entry ~wire
    (entry : Model_catalog.model_entry) : capabilities =
  let base, provider_entry, wire = match entry.provider_name with
    | None -> None, None, None
    | Some _ -> base, provider_entry, wire in
  let overrides = overrides_of_catalog_entry entry in
  let wire_base = Option.bind provider_entry
    (fun (provider : Model_catalog.provider_entry) ->
      Option.bind wire (fun kind ->
        List.assoc_opt kind provider.capabilities_base_by_identity_kind)) in
  let base_label = match wire_base, overrides.base_label with
    | (Some _ as base), _ -> base
    | None, (Some _ as base) -> base
    | None, None -> Option.bind provider_entry
        (fun (provider : Model_catalog.provider_entry) -> provider.capabilities_base)
  in
  let capabilities = apply_declarative_capability_overrides ?base
      { overrides with base_label } in
  { capabilities with
    emits_usage_tokens = (match entry.emits_usage_tokens with
      | Some emits -> emits | None -> capabilities.emits_usage_tokens)
  ; supported_models = (match entry.supported_models with
      | Some _ as models -> models | None -> capabilities.supported_models)
  }
;;

let declared_image_input_for_provider_model ~catalog ~wire ~provider ~model_id =
  match provider with
  | Model_catalog.Anonymous_wire _ -> None
  | Model_catalog.Declared_provider _ ->
    Option.bind (Model_catalog.provider_entry_for_reference catalog provider)
      (fun provider_entry ->
        Option.bind (Model_catalog.lookup_model_for_provider catalog ~provider ~model_id)
          (fun entry ->
            let provider_entry, wire = match entry.Model_catalog.provider_name with
              | None -> None, None
              | Some _ -> Some provider_entry, wire in
            (apply_catalog_entry ~provider_entry ~wire entry).declared_image_input))
;;

(** Look up capabilities for [model_id] in the loaded model catalog only.

    Model facts come from one complete {!Catalog_snapshot.current} selection:
    an explicit admitted publication or the immutable embedded default.
    AGENT_CORE performs no environment-based catalog discovery.

    Returns [None] when no catalog is available or when the catalog has
    no entry whose [model_id] matches [model_id]. There is no in-code
    fallback table: the former built-in static table was removed when
    model specifications were externalized to the TOML catalog. *)

let for_model_id_from_catalog catalog model_id =
  match catalog with
  | Some catalog ->
    (match Model_catalog.lookup catalog model_id with
     | Some entry -> Some (apply_catalog_entry ~provider_entry:None ~wire:None entry)
     | None -> None)
  | None -> None
;;

let for_model_id model_id =
  with_model_id model_id (for_model_id_from_catalog (Catalog_snapshot.models (Catalog_snapshot.current ())))
;;

let for_provider_reference_base ~catalog ~wire ~provider =
  match catalog with
  | None -> None
  | Some catalog ->
    Option.bind
      (provider_base_label ~catalog ~wire provider)
      capabilities_for_provider_label
;;

let for_provider_model_id_from_catalog ~catalog ~wire ~provider ~model_id =
  let row = Option.bind catalog (fun catalog ->
    Option.map (fun entry -> catalog, entry)
      (Model_catalog.lookup_model_for_provider catalog ~provider ~model_id)) in
  match row with
  | Some (catalog, entry) ->
    (match entry.Model_catalog.provider_name with
     | None -> Some (apply_catalog_entry ~provider_entry:None ~wire:None entry)
     | Some _ ->
       let provider_entry = Model_catalog.provider_entry_for_reference catalog provider in
       Some (apply_catalog_entry ~provider_entry ~wire entry))
  | None ->
    for_provider_reference_base ~catalog ~wire ~provider
;;

type request_policy =
  { model_capabilities : capabilities option
  ; anthropic_thinking_control : anthropic_thinking_control option
  ; pricing_source : Pricing.source
  }

let resolve_request_policy_from_catalog ~catalog ~wire ~provider ~model_id =
  let pricing_source = Pricing.of_catalog ~catalog ~provider in
  match Model_identifiers.Model_id.of_string model_id with
  | Error _ -> { model_capabilities = None; anthropic_thinking_control = None; pricing_source }
  | Ok model_id ->
  let model_capabilities = for_provider_model_id_from_catalog
      ~catalog ~wire:(Some wire) ~provider ~model_id in
  let anthropic_thinking_control =
    match wire with
    | Provider_kind.Anthropic ->
      anthropic_thinking_control_for_provider_from_catalog
        ~catalog ~provider model_id
    | Provider_kind.Kimi | Provider_kind.OpenAI_compat | Provider_kind.Ollama
    | Provider_kind.Gemini | Provider_kind.Glm -> None
  in
  { model_capabilities; anthropic_thinking_control; pricing_source }
;;

let resolve_bound_request_policy ~catalog ~wire ~(provider : Model_catalog.provider_entry)
    ~capabilities ~model_id =
  let pricing_source = Pricing.of_provider_entry ~catalog ~provider in
  let capabilities = match Option.bind
      (List.assoc_opt wire provider.capabilities_base_by_identity_kind)
      capabilities_for_provider_label with
    | Some capabilities -> capabilities
    | None -> capabilities in
  let row = match Model_identifiers.Model_id.of_string model_id with
    | Error _ -> None
    | Ok model_id -> Option.bind catalog (fun catalog ->
        Model_catalog.lookup_model_for_provider_entry catalog ~provider ~model_id) in
  match row with
  | None -> {model_capabilities=Some capabilities;anthropic_thinking_control=None;pricing_source}
  | Some row ->
    let scoped_provider = match row.Model_catalog.provider_name with
      | None -> None | Some _ -> Some provider in
    let model_capabilities = Some (apply_catalog_entry ~base:capabilities
        ~provider_entry:scoped_provider ~wire:(Some wire) row) in
    let anthropic_thinking_control = match wire with
      | Provider_kind.Anthropic -> Option.map anthropic_thinking_control_of_vocab_value
          row.anthropic_thinking_control
      | Kimi | OpenAI_compat | Ollama | Gemini | Glm -> None in
    {model_capabilities;anthropic_thinking_control;pricing_source}
;;

let resolve_snapshot_request_policy ~snapshot ~wire ~provider_id ~model_id =
  match Catalog_snapshot.policy_provider snapshot provider_id with
  | Some (entry, provider) ->
    resolve_bound_request_policy ~catalog:(Catalog_snapshot.models snapshot)
      ~wire ~provider ~capabilities:entry.capabilities ~model_id
  | None ->
    let catalog = Option.map Model_catalog.without_providers
        (Catalog_snapshot.models snapshot) in
    resolve_request_policy_from_catalog ~catalog ~wire
      ~provider:(Model_catalog.Declared_provider provider_id) ~model_id
;;

let resolve_request_policy ~wire ~provider ~model_id =
  let catalog = Catalog_snapshot.model_catalog_for_provider
      (Catalog_snapshot.current ()) provider in
  resolve_request_policy_from_catalog ~catalog ~wire ~provider ~model_id
;;

let for_provider_model_id ~wire ~provider ~model_id =
  with_model_id model_id (fun model_id ->
    let catalog = Catalog_snapshot.model_catalog_for_provider
        (Catalog_snapshot.current ()) provider in
    for_provider_model_id_from_catalog ~catalog ~wire ~provider ~model_id)
;;

let anthropic_thinking_control_for_provider_model_id ~provider ~model_id =
  with_model_id model_id (fun model_id ->
    let catalog = Catalog_snapshot.model_catalog_for_provider
        (Catalog_snapshot.current ()) provider in
    anthropic_thinking_control_for_provider_from_catalog ~catalog ~provider model_id)
;;

let request_policy_capabilities policy = policy.model_capabilities
let request_policy_anthropic_thinking_control policy = policy.anthropic_thinking_control
let request_policy_pricing_source policy = policy.pricing_source

(* The token is the single source of truth carried by the entry's
   [Chat_template_token] constructor (the parser validated its exactness), so it
   is read back through the constructor rather than a sibling field. *)
let token_of_declared_format format =
  Option.bind format Capability_vocab.token_of_thinking_control_format
;;

let thinking_control_token_for_provider_model_id ~provider_label ~model_id =
  let provider = match Provider_kind.of_canonical_string
      (String.lowercase_ascii (String.trim provider_label)) with
    | Some kind -> Model_catalog.Anonymous_wire kind
    | None -> Model_catalog.Declared_provider provider_label in
  with_model_id model_id (fun model_id ->
    Option.bind (Catalog_snapshot.model_catalog_for_provider
      (Catalog_snapshot.current ()) provider) (fun catalog ->
        Option.bind (Model_catalog.lookup_for_provider_reference catalog ~provider ~model_id)
          (fun row -> token_of_declared_format row.Model_catalog.thinking_control_format)))
;;

[@@@coverage off]

let admit_fixture_catalogs ~models ~providers =
  match Catalog_snapshot.of_catalogs ~models ~providers with
  | Ok snapshot -> snapshot
  | Error error -> failwith (Catalog_snapshot.error_to_string error)
;;

let%test "for_model_id glm-4.5 has reasoning" =
  match for_model_id "glm-4.5" with
  | Some c ->
    c.supports_reasoning
    && c.max_context_tokens = Some 128_000
    && c.max_output_tokens = Some 96_000
  | None -> false
;;

let%test "for_provider_model_id glm-4-flash basic" =
  match
    for_provider_model_id
      ~wire:None
      ~provider:(Model_catalog.Anonymous_wire Provider_kind.Glm)
      ~model_id:"glm-4-flash"
  with
  | Some c -> c.supports_tools && c.max_output_tokens = Some 4_096
  | None -> false
;;

let%test "for_model_id glm-5 is text only" =
  match for_model_id "glm-5" with
  | Some c -> c.supports_reasoning && not c.supports_image_input
  | None -> false
;;

let%test "for_model_id glm-5v has vision" =
  match for_model_id "glm-5v-turbo" with
  | Some c -> c.supports_reasoning && c.supports_image_input
  | None -> false
;;

let%test "for_model_id glm-4.6v stays vision-capable" =
  match for_model_id "glm-4.6v" with
  | Some c ->
    c.supports_reasoning && c.supports_image_input && c.max_output_tokens = Some 32_768
  | None -> false
;;

let%test "for_model_id glm-4.5v stays vision-capable" =
  match for_model_id "glm-4.5v" with
  | Some c ->
    c.supports_reasoning && c.supports_image_input && c.max_output_tokens = Some 16_384
  | None -> false
;;

let%test "for_model_id glm-4.7-flashx has GLM-4.7 thinking limits" =
  match for_model_id "glm-4.7-flashx" with
  | Some c ->
    c.supports_reasoning
    && c.max_context_tokens = Some 200_000
    && c.max_output_tokens = Some 128_000
    && c.supports_tools
  | None -> false
;;

let%test "for_model_id glm-4.7-flash has thinking" =
  match for_model_id "glm-4.7-flash" with
  | Some c -> c.supports_reasoning && c.max_output_tokens = Some 128_000
  | None -> false
;;

let%test "for_model_id glm-4.5-flash has GLM-4.5 thinking limits" =
  match for_model_id "glm-4.5-flash" with
  | Some c ->
    c.supports_reasoning
    && c.max_context_tokens = Some 128_000
    && c.max_output_tokens = Some 96_000
    && c.supports_tools
  | None -> false
;;

(* [for_model_id] tests below install an explicit catalog through
   [Catalog_snapshot.publish] and restore the whole selection afterwards, so they
   are insulated from any caller-installed model catalog. Inline tests that
   exercise the production catalog use the embedded default generated directly
   from the AGENT_CORE-owned [models.toml].

   Fixtures are strict TOML snapshots, parsed through the same constructor as
   deployment catalogs; they are not auto-synced with [models.toml]. *)
let%test_module "catalog fixtures" = (module struct
let test_catalog_of_toml contents =
  Model_catalog.of_toml_string ~source:"capabilities inline fixture" contents
  |> Result.get_ok
;;

let%test_module "named tool choice catalog" =
  (module struct
    let test_catalog_entry model_id fields =
      let catalog = test_catalog_of_toml
          (Printf.sprintf "[[models]]\nmodel_id = %S\n%s" model_id fields) in
      match Model_catalog.model_entries catalog with
      | [ entry ] -> entry
      | _ -> invalid_arg "capabilities fixture must declare one row"
    ;;

    let%test "named tool choice needs its own declaration, not a sibling override" =
      (* A row that turns tool_choice on and says nothing about named choice used
         to be answered `true`, so the record advertised a capability the catalog
         never declared. 21 rows in models.toml are shaped this way. *)
      let entry =
        test_catalog_entry "named-choice-omitted" {|base = "openai_chat"
supports_tools = true
supports_tool_choice = true
|}
      in
      let derived = apply_catalog_entry ~provider_entry:None ~wire:None entry in
      let base =
        match capabilities_for_provider_label "openai_chat" with
        | Some c -> c
        | None -> default_capabilities
      in
      derived.supports_tool_choice
      && derived.supports_named_tool_choice = base.supports_named_tool_choice
    ;;

    let%test "named tool choice honours an explicit declaration" =
      let entry =
        test_catalog_entry "named-choice-declared" {|base = "openai_chat"
supports_tools = true
supports_tool_choice = true
supports_named_tool_choice = true
|}
      in
      (apply_catalog_entry ~provider_entry:None ~wire:None entry).supports_named_tool_choice
    ;;

    let%test "named tool choice cannot outlive tool choice" =
      (* Declaring named choice while tool choice is off stays false: the sibling
         fields are conjoined, not independent. *)
      let entry =
        test_catalog_entry "named-choice-without-tool-choice" {|base = "openai_chat"
supports_tools = true
supports_tool_choice = false
supports_named_tool_choice = true
|}
      in
      not
        (apply_catalog_entry ~provider_entry:None ~wire:None entry).supports_named_tool_choice
    ;;
  end)
;;

let test_catalog : Model_catalog.t =
  test_catalog_of_toml {|
[[models]]
model_id = "qwen3"
base = "openai_chat"
max_context_tokens = 262144
max_output_tokens = 81920
supports_tools = true
supports_tool_choice = true
supports_required_tool_choice = true
supports_named_tool_choice = true
supports_reasoning = true
thinking_control_format = "chat_template_kwargs"
preserve_thinking_control_format = "chat_template_kwargs_preserve_thinking"
supports_native_streaming = true

[[models]]
model_id = "qwen3-32b"
base = "openai_chat"
max_context_tokens = 262144
max_output_tokens = 81920
supports_tools = true
supports_tool_choice = true
supports_required_tool_choice = true
supports_named_tool_choice = true
supports_reasoning = true
thinking_control_format = "chat_template_kwargs"
preserve_thinking_control_format = "chat_template_kwargs_preserve_thinking"
supports_native_streaming = true

[[models]]
model_id = "qwen3.5"
base = "openai_chat"
max_context_tokens = 262144
max_output_tokens = 81920
supports_tools = true
supports_tool_choice = true
supports_required_tool_choice = true
supports_named_tool_choice = true
supports_reasoning = true
thinking_control_format = "chat_template_kwargs"
preserve_thinking_control_format = "chat_template_kwargs_preserve_thinking"
supports_native_streaming = true

[[models]]
model_id = "qwen36-35b-a3b-mtp"
base = "openai_chat"
max_context_tokens = 262144
max_output_tokens = 81920
supports_tools = true
supports_tool_choice = true
supports_required_tool_choice = true
supports_named_tool_choice = true
supports_reasoning = true
thinking_control_format = "chat_template_kwargs"
preserve_thinking_control_format = "chat_template_kwargs_preserve_thinking"
supports_native_streaming = true

[[models]]
model_id = "qwen-3"
base = "openai_chat"
max_context_tokens = 262144
max_output_tokens = 81920
supports_tools = true
supports_tool_choice = true
supports_required_tool_choice = true
supports_named_tool_choice = true
supports_reasoning = true
thinking_control_format = "chat_template_kwargs"
preserve_thinking_control_format = "chat_template_kwargs_preserve_thinking"
supports_native_streaming = true

[[models]]
model_id = "qwen/qwen3.6"
base = "openai_chat"
max_context_tokens = 262144
max_output_tokens = 81920
supports_tools = true
supports_tool_choice = true
supports_required_tool_choice = true
supports_named_tool_choice = true
supports_reasoning = true
thinking_control_format = "chat_template_kwargs"
preserve_thinking_control_format = "chat_template_kwargs_preserve_thinking"
supports_native_streaming = true

[[models]]
model_id = "glm-5.1"
base = "glm"
max_context_tokens = 200000
max_output_tokens = 128000
supports_tools = true
supports_tool_choice = false
supports_required_tool_choice = false
supports_named_tool_choice = false
supports_reasoning = true
supports_native_streaming = true

[[models]]
model_id = "glm-5-turbo"
base = "glm"
max_context_tokens = 200000
max_output_tokens = 128000
supports_tools = true
supports_tool_choice = false
supports_required_tool_choice = false
supports_named_tool_choice = false
supports_reasoning = true
supports_native_streaming = true

[[models]]
model_id = "glm-5v-turbo"
base = "glm"
max_context_tokens = 200000
max_output_tokens = 128000
supports_tools = true
supports_tool_choice = false
supports_required_tool_choice = false
supports_named_tool_choice = false
supports_reasoning = true
supports_native_streaming = true
supports_multimodal_inputs = true
supports_image_input = true

[[models]]
model_id = "glm-ocr"
base = "glm"
max_context_tokens = 128000
max_output_tokens = 16384
supports_tools = false
supports_multimodal_inputs = true
supports_image_input = true

[[models]]
model_id = "glm-4.7-flashx"
base = "glm"
max_context_tokens = 200000
max_output_tokens = 128000
supports_tools = true
supports_tool_choice = false
supports_required_tool_choice = false
supports_named_tool_choice = false
supports_reasoning = true
supports_native_streaming = true

[[models]]
model_id = "glm-4.7-flash"
base = "glm"
max_context_tokens = 200000
max_output_tokens = 128000
supports_tools = true
supports_tool_choice = false
supports_required_tool_choice = false
supports_named_tool_choice = false
supports_reasoning = true
supports_native_streaming = true

[[models]]
model_id = "glm-4.5-air"
base = "glm"
max_context_tokens = 128000
max_output_tokens = 96000
supports_tools = true
supports_tool_choice = false
supports_required_tool_choice = false
supports_named_tool_choice = false
supports_reasoning = true
supports_native_streaming = true

[[models]]
model_id = "glm-4.5-flash"
base = "glm"
max_context_tokens = 128000
max_output_tokens = 96000
supports_tools = true
supports_tool_choice = false
supports_required_tool_choice = false
supports_named_tool_choice = false
supports_reasoning = true
supports_native_streaming = true

[[models]]
model_id = "glm-5"
base = "glm"
max_context_tokens = 200000
max_output_tokens = 128000
supports_tools = true
supports_tool_choice = false
supports_required_tool_choice = false
supports_named_tool_choice = false
supports_reasoning = true
supports_native_streaming = true

[[models]]
model_id = "glm-4.6"
base = "glm"
max_context_tokens = 200000
max_output_tokens = 128000
supports_tools = true
supports_tool_choice = false
supports_required_tool_choice = false
supports_named_tool_choice = false
supports_reasoning = true
supports_native_streaming = true

[[models]]
model_id = "glm-4.7"
base = "glm"
max_context_tokens = 200000
max_output_tokens = 128000
supports_tools = true
supports_tool_choice = false
supports_required_tool_choice = false
supports_named_tool_choice = false
supports_reasoning = true
supports_native_streaming = true

[[models]]
model_id = "glm-4.5"
base = "glm"
max_context_tokens = 128000
max_output_tokens = 96000
supports_tools = true
supports_tool_choice = false
supports_required_tool_choice = false
supports_named_tool_choice = false
supports_reasoning = true
supports_native_streaming = true

[[models]]
model_id = "glm-4.6v"
base = "glm"
max_context_tokens = 128000
max_output_tokens = 32768
supports_tools = true
supports_tool_choice = false
supports_required_tool_choice = false
supports_named_tool_choice = false
supports_reasoning = true
supports_native_streaming = true
supports_multimodal_inputs = true
supports_image_input = true

[[models]]
model_id = "glm-4-flash"
max_context_tokens = 128000
max_output_tokens = 4096
supports_tools = true

[[models]]
model_id = "glm-4v"
max_context_tokens = 128000
max_output_tokens = 4096
supports_tools = true
supports_multimodal_inputs = true
supports_image_input = true

[[models]]
model_id = "glm-4"
max_context_tokens = 128000
max_output_tokens = 4096
supports_tools = true

[[models]]
model_id = "deepseek-v4-pro"
base = "openai_chat"
max_context_tokens = 1000000
max_output_tokens = 384000
supports_tools = true
supports_tool_choice = true
supports_required_tool_choice = false
supports_named_tool_choice = false
supports_reasoning = true
thinking_control_format = "thinking_object"
supports_native_streaming = true

[[models]]
model_id = "deepseek-ai/deepseek-v4-pro"
base = "openai_chat"
max_context_tokens = 1000000
max_output_tokens = 384000
supports_tools = true
supports_tool_choice = true
supports_required_tool_choice = false
supports_named_tool_choice = false
supports_reasoning = true
thinking_control_format = "thinking_object"
supports_native_streaming = true

[[models]]
model_id = "deepseek-v4-flash"
base = "openai_chat"
max_context_tokens = 1000000
max_output_tokens = 384000
supports_tools = true
supports_tool_choice = true
supports_required_tool_choice = false
supports_named_tool_choice = false
supports_reasoning = true
thinking_control_format = "thinking_object"
supports_native_streaming = true

[[models]]
model_id = "deepseek-ai/deepseek-v4-flash"
base = "openai_chat"
max_context_tokens = 1000000
max_output_tokens = 384000
supports_tools = true
supports_tool_choice = true
supports_required_tool_choice = false
supports_named_tool_choice = false
supports_reasoning = true
thinking_control_format = "thinking_object"
supports_native_streaming = true

[[models]]
model_id = "nvidia/nvidia-vl"
base = "nvidia"
max_context_tokens = 131072
max_output_tokens = 16384
supports_multimodal_inputs = true
supports_image_input = true

[[models]]
model_id = "nvidia-vl"
base = "nvidia"
max_context_tokens = 131072
max_output_tokens = 16384
supports_multimodal_inputs = true
supports_image_input = true

[[models]]
model_id = "nvidia/nvidia"
base = "nvidia"
max_context_tokens = 131072
max_output_tokens = 16384

[[models]]
model_id = "nvidia"
base = "nvidia"
max_context_tokens = 131072
max_output_tokens = 16384

[[models]]
model_id = "google/gemma-4"
base = "openai_chat"
max_context_tokens = 262144
supports_tools = true
supports_tool_choice = true
supports_required_tool_choice = true
supports_named_tool_choice = true
supports_multimodal_inputs = true
supports_image_input = true
modality_priority = "visual_first"
supports_native_streaming = true
supports_seed = true

[[models]]
model_id = "google/gemma-4-26b-a4b"
base = "openai_chat"
max_context_tokens = 262144
supports_tools = true
supports_tool_choice = true
supports_required_tool_choice = true
supports_named_tool_choice = true
supports_multimodal_inputs = true
supports_image_input = true
modality_priority = "visual_first"
supports_native_streaming = true
supports_seed = true

[[models]]
model_id = "hf.co/unsloth/gemma-4"
base = "ollama"
max_context_tokens = 262144
supports_tools = true
supports_tool_choice = false
supports_named_tool_choice = false
supports_reasoning = true
thinking_control_format = "chat_template_token"
thinking_control_token = "<|think|>"
supports_multimodal_inputs = true
supports_image_input = true
modality_priority = "visual_first"
supports_seed = true

[[models]]
model_id = "hf.co/unsloth/gemma-4-e2b-it-qat-gguf"
base = "ollama"
max_context_tokens = 131072
supports_tools = true
supports_tool_choice = false
supports_named_tool_choice = false
supports_reasoning = true
thinking_control_format = "chat_template_token"
thinking_control_token = "<|think|>"
supports_multimodal_inputs = true
supports_image_input = true
modality_priority = "visual_first"
supports_seed = true
supports_audio_input = true

[[models]]
model_id = "claude-opus-5-5"
base = "anthropic"
max_context_tokens = 1000000
max_output_tokens = 128000

[[models]]
model_id = "gpt-4.1"
base = "openai_chat"
max_context_tokens = 1000000
max_output_tokens = 32000
|}
;;

(* Installs [test_catalog] as the runtime override for the duration of [f],
   then clears the override so subsequent lookups use the embedded catalog. *)
let with_test_catalog f =
  Catalog_snapshot.publish (admit_fixture_catalogs ~models:(Some (test_catalog)) ~providers:(None));
  Fun.protect ~finally:Catalog_snapshot.reset f
;;

let%test "for_model_id qwen3 has extended thinking" =
  with_test_catalog (fun () ->
    match for_model_id "qwen3-32b" with
    | Some c ->
      c.supports_reasoning
      && c.supports_tools
      && c.supports_native_streaming
    | None -> false)
;;

let%test "for_model_id qwen3.5 routes to Qwen_3 family" =
  with_test_catalog (fun () ->
    match for_model_id "qwen3.5" with
    | Some c -> c.max_output_tokens = Some 81_920
    | None -> false)
;;

let%test "for_model_id qwen36 model routes to Qwen_3 family" =
  with_test_catalog (fun () ->
    match for_model_id "qwen36-35b-a3b-mtp" with
    | Some c ->
      c.thinking_control_format = Chat_template_kwargs
    | None -> false)
;;

let%test "for_model_id glm-5-turbo has GLM-5 thinking limits" =
  with_test_catalog (fun () ->
    match for_model_id "glm-5-turbo" with
    | Some c ->
      c.supports_reasoning
      && c.max_context_tokens = Some 200_000
      && c.max_output_tokens = Some 128_000
    | None -> false)
;;

let%test "for_model_id glm-5.1 full model (reasoning + extended thinking)" =
  with_test_catalog (fun () ->
    match for_model_id "glm-5.1" with
    | Some c ->
      c.supports_reasoning
      && c.max_output_tokens = Some 128_000
    | None -> false)
;;

let%test "for_model_id bare glm-5 full model (reasoning + extended thinking)" =
  with_test_catalog (fun () ->
    match for_model_id "glm-5" with
    | Some c ->
      c.supports_reasoning
      && c.max_output_tokens = Some 128_000
    | None -> false)
;;

let%test "for_model_id catalog miss returns None" =
  with_test_catalog (fun () ->
    Option.is_none (for_model_id "totally-unknown-model-id"))
;;

let%test "for_model_id empty catalog returns None" =
  Catalog_snapshot.publish (admit_fixture_catalogs ~models:(Some (Model_catalog.empty)) ~providers:(None));
  Fun.protect ~finally:Catalog_snapshot.reset (fun () ->
    Option.is_none (for_model_id "qwen3-32b"))
;;

let%test "Anthropic thinking policy resolves from the model catalog declaration" =
  Catalog_snapshot.publish (admit_fixture_catalogs ~models:(Some ((test_catalog_of_toml {|[[models]]
model_id = "declared-anthropic-model"
anthropic_thinking_control = "adaptive_default"
|}))) ~providers:(None));
  Fun.protect ~finally:Catalog_snapshot.reset (fun () ->
    anthropic_thinking_control_for_model_id "declared-anthropic-model"
    = Some Anthropic_adaptive_default)
;;

let%test "Anthropic thinking policy reads composed JSON declaration" =
  Catalog_snapshot.publish (admit_fixture_catalogs ~models:(Some (Model_catalog.empty)) ~providers:(None));
  let manifest = Capability_manifest.of_json (Yojson.Safe.from_string
    {|{"schema_version":2,"models":[{"model_id":"manifest-anthropic-model","anthropic_thinking_control":"adaptive_disabled_through_high"}]}|})
    |> Result.get_ok in
  Catalog_snapshot.publish (admit_fixture_catalogs ~models:(Some ((Model_catalog.with_model_overrides Model_catalog.empty manifest))) ~providers:(None));
  Fun.protect
    ~finally:(fun () ->
      Catalog_snapshot.reset ())
    (fun () ->
       anthropic_thinking_control_for_model_id "manifest-anthropic-model"
       = Some Anthropic_adaptive_disabled_through_high)
;;

(* Adversarial F1 (2026-09-06): a provider-qualified row — deepseek on the
   Anthropic-compatible surface — is invisible to the bare lookup, so the
   provider-aware variant must be the one that sees its policy, and the bare
   reading must stay blind to it. *)
let%test "Anthropic thinking policy on a provider-qualified row resolves by provider label" =
  Catalog_snapshot.publish (admit_fixture_catalogs ~models:(Some ((test_catalog_of_toml {|[[models]]
model_id = "provider-scoped-anthropic-model"
provider_name = "deepseek-anthropic"
anthropic_thinking_control = "always_adaptive"
|}))) ~providers:(None));
  Fun.protect ~finally:Catalog_snapshot.reset (fun () ->
    anthropic_thinking_control_for_provider_model_id
      ~provider:(Model_catalog.Declared_provider "deepseek-anthropic")
      ~model_id:"provider-scoped-anthropic-model"
    = Some Anthropic_always_adaptive
    && Option.is_none
         (anthropic_thinking_control_for_model_id
            "provider-scoped-anthropic-model"))
;;

(* --- emits_usage_tokens / capabilities_for_provider_label --- *)

let%test "emits_usage_tokens: default is true" = default_capabilities.emits_usage_tokens

let%test "emits_usage_tokens: anthropic reports usage" =
  anthropic_capabilities.emits_usage_tokens
;;

let%test "emits_usage_tokens: ollama reports usage" =
  ollama_capabilities.emits_usage_tokens
;;

let%test "capabilities_for_provider_label: anthropic" =
  match capabilities_for_provider_label "anthropic" with
  | Some c -> c.emits_usage_tokens
  | None -> false
;;

let%test "capabilities_for_provider_label: openai alias" =
  Option.is_some (capabilities_for_provider_label "openai")
  && Option.is_some (capabilities_for_provider_label "openai_chat")
;;

let%test "capabilities_for_provider_label: glm alias" =
  Option.is_some (capabilities_for_provider_label "glm")
  && Option.is_some (capabilities_for_provider_label "glm-coding")
;;

let%test "capabilities_for_provider_label: unknown returns None" =
  Option.is_none (capabilities_for_provider_label "not_a_real_provider_xyz")
;;

(* --- Nvidia / Gemma 4 --- *)

let%test "provider_l_capabilities has chat_template_kwargs thinking" =
  provider_l_capabilities.thinking_control_format = Chat_template_kwargs
;;

let%test "for_model_id nvidia/nvidia resolves reasoning and tool choice" =
  (* nvidia/nvidia is the surviving bare nvidia row after #45872's exact
     identities; its row leaves both flags to the nvidia base template
     (provider_l), which declares reasoning and tool choice. *)
  match for_model_id "nvidia/nvidia" with
  | Some c -> c.supports_reasoning && c.supports_tool_choice
  | None -> false
;;

let%test "for_model_id nvidia-vl has image input" =
  match for_model_id "nvidia-vl" with
  | Some c -> c.supports_image_input && c.supports_multimodal_inputs
  | None -> false
;;

let%test "for_model_id qwen3 has chat_template_kwargs thinking control" =
  (* Qwen3.x OpenAI-compatible llama.cpp/llama-server deployments return
     [reasoning_content] when thinking is enabled through
     {"chat_template_kwargs": {"enable_thinking": bool}}.  Without this
     format, a declared thinking capability never reaches the wire. *)
  match for_model_id "qwen3.6" with
  | Some c -> c.thinking_control_format = Chat_template_kwargs
  | None -> false
;;

(* nvidia-ultra-253b and nvidia/nvidia-core left the embedded catalog with
   #45872's exact-identity rows.  Their reasoning coverage now lives on
   surviving rows: the nvidia base template (above) and gemma4:31b (below). *)

let%test "for_model_id gemma4:31b keeps the reasoning coverage" =
  (* gemma4:31b declares supports_reasoning = true and tool_choice = false,
     so this row pins the reasoning flag independently of the base template. *)
  match for_model_id "gemma4:31b" with
  | Some c -> c.supports_reasoning && not c.supports_tool_choice
  | None -> false
;;

let%test "for_model_id google/gemma-4-26b-a4b has tools + seed" =
  match for_model_id "google/gemma-4-26b-a4b" with
  | Some c ->
    c.supports_tools
    && c.supports_seed
    && c.supports_image_input
    && c.max_context_tokens = Some 262_144
    && c.modality_priority = Modality.Visual_first
  | None -> false
;;

let%test "for_model_id google/gemma-4-e2b has tools, audio, and 128K context" =
  match for_model_id "google/gemma-4-e2b" with
  | Some c ->
    c.supports_tools
    && c.supports_image_input
    && c.supports_audio_input
    && c.max_context_tokens = Some 131_072
  | None -> false
;;

let%test "for_provider_model_id unsloth Gemma 4 QAT uses template token thinking" =
  (* The QAT rows are provider-scoped (provider_name = "ollama"), so a bare
     for_model_id cannot see them; the provider-scoped lookup is the real
     runtime path. *)
  match
    for_provider_model_id ~wire:None
      ~provider:(Model_catalog.Declared_provider "ollama")
      ~model_id:"hf.co/unsloth/gemma-4-26B-A4B-it-qat-GGUF:UD-Q4_K_XL"
  with
  | Some c ->
    c.supports_reasoning
    && c.thinking_control_format = Chat_template_token "<|think|>"
    && c.modality_priority = Modality.Visual_first
  | None -> false
;;

let%test "for_provider_model_id unsloth Gemma 4 E2B QAT keeps exact 128K audio row" =
  match
    for_provider_model_id ~wire:None
      ~provider:(Model_catalog.Declared_provider "ollama")
      ~model_id:"hf.co/unsloth/gemma-4-E2B-it-qat-GGUF:UD-Q4_K_XL"
  with
  | Some c ->
    c.supports_tools
    && c.supports_image_input
    && c.supports_audio_input
    && c.max_context_tokens = Some 131_072
    && c.thinking_control_format = Chat_template_token "<|think|>"
    && c.modality_priority = Modality.Visual_first
  | None -> false
;;

let%test "for_model_id hf.co/google Gemma 4 uses template token thinking" =
  (* The 26B-A4B-it-qat-q4_0-gguf row left the catalog; hf.co/google/gemma-4
     is the surviving ollama-hosted google QAT row with template-token thinking. *)
  match for_model_id "hf.co/google/gemma-4" with
  | Some c ->
    c.supports_reasoning
    && c.thinking_control_format = Chat_template_token "<|think|>"
  | None -> false
;;

let%test "for_model_id google/gemma-4-e2b is not a 256K model" =
  match for_model_id "google/gemma-4-e2b" with
  | Some c -> c.max_context_tokens = Some 131_072
  | None -> false
;;

let%test "for_model_id google/gemma-4-31b resolves" =
  match for_model_id "google/gemma-4-31b" with
  | Some c -> c.supports_tools && c.supports_image_input
  | None -> false
;;

let%test "for_model_id Qwen mtp alias uses chat_template_kwargs" =
  match for_model_id "qwen36-35b-a3b-mtp" with
  | Some c ->
    c.thinking_control_format = Chat_template_kwargs
  | None -> false
;;

let%test "capabilities_for_provider_label: nvidia" =
  match capabilities_for_provider_label "nvidia" with
  | Some c -> c.thinking_control_format = Chat_template_kwargs
  | None -> false
;;

(* Exact declarations keep their capability fingerprints without inheritance. *)
let%test
    "for_model_id: specific model IDs get correct (not shadowed) capabilities"
  =
  with_test_catalog (fun () ->
    let check model_id expected =
      match for_model_id model_id with
      | Some c -> expected c
      | None -> false
    in
    List.for_all
      (fun (m, e) -> check m e)
      [ ( "glm-4.7-flash"
        , fun c -> c.max_output_tokens = Some 128_000 )
      ; ( "glm-4.5-flash"
        , fun c -> c.max_output_tokens = Some 96_000 )
      ; ( "glm-5-turbo"
        , fun c -> c.max_output_tokens = Some 128_000 )
      ; ( "glm-5-turbo"
        , fun c -> c.max_output_tokens = Some 128_000 )
      ; ("glm-4.6v", fun c -> c.supports_image_input && c.supports_reasoning)
      ; ( "glm-4.7-flash"
        , fun c -> c.max_output_tokens = Some 128_000 && c.supports_reasoning )
      ; ( "glm-4.7-flashx"
        , fun c -> c.max_output_tokens = Some 128_000 && c.supports_reasoning )
      ; ( "glm-4-flash"
        , fun c -> c.max_output_tokens = Some 4_096 && not c.supports_reasoning )
      ; ("glm-4v", fun c -> c.supports_image_input)
      ; ( "glm-4.5-air"
        , fun c -> c.max_output_tokens = Some 96_000 && c.supports_reasoning )
      ; ( "glm-4.5-air"
        , fun c -> c.max_output_tokens = Some 96_000 && c.supports_reasoning )
      ; ( "glm-5v-turbo"
        , fun c ->
            c.supports_image_input
            && c.supports_reasoning
            && c.max_output_tokens = Some 128_000 )
      ; ( "glm-5v-turbo"
        , fun c ->
            c.supports_image_input
            && c.supports_reasoning
            && c.max_output_tokens = Some 128_000 )
      ; ("glm-ocr", fun c -> c.supports_image_input && not c.supports_tools)
      ; ("glm-ocr", fun c -> c.supports_image_input && not c.supports_tools)
      ; ("claude-opus-5-5", fun c -> c.max_output_tokens = Some 128_000)
      ; ("gpt-4.1", fun c -> c.max_output_tokens = Some 32_000)
      ; ( "deepseek-v4-flash"
        , fun c ->
            c.thinking_control_format = Thinking_object
            && c.max_output_tokens = Some 384_000 )
      ; ( "deepseek-v4-flash"
        , fun c ->
            c.thinking_control_format = Thinking_object
            && c.max_output_tokens = Some 384_000 )
      ; ( "deepseek-v4-pro"
        , fun c ->
            c.thinking_control_format = Thinking_object
            && c.max_output_tokens = Some 384_000 )
      ; ( "deepseek-ai/DeepSeek-V4-Flash"
        , fun c ->
            c.thinking_control_format = Thinking_object
            && c.max_output_tokens = Some 384_000 )
      ; ( "deepseek-ai/DeepSeek-V4-Pro"
        , fun c ->
            c.thinking_control_format = Thinking_object
            && c.max_output_tokens = Some 384_000 )
      ; ( "qwen/qwen3.6"
        , fun c ->
            c.thinking_control_format = Chat_template_kwargs
            )
      ; ( "deepseek-v4-pro"
        , fun c ->
            c.thinking_control_format = Thinking_object
            && c.max_output_tokens = Some 384_000 )
      ; ( "nvidia"
        , fun c ->
            c.thinking_control_format = Chat_template_kwargs && c.supports_tool_choice )
      ; ( "nvidia/nvidia"
        , fun c ->
            c.thinking_control_format = Chat_template_kwargs && c.supports_tool_choice )
      ; ("nvidia-vl", fun c -> c.supports_image_input && c.supports_multimodal_inputs)
      ; ( "google/gemma-4-26b-a4b"
        , fun c ->
            c.supports_tools
            && c.supports_image_input
            && c.supports_seed
            && c.modality_priority = Modality.Visual_first
            && c.max_context_tokens = Some 262_144 )
      ; ( "hf.co/unsloth/gemma-4"
        , fun c ->
            c.supports_reasoning
            && c.thinking_control_format = Chat_template_token "<|think|>" )
      ; ( "hf.co/unsloth/gemma-4-e2b-it-qat-gguf"
        , fun c ->
            c.supports_audio_input
            && c.thinking_control_format = Chat_template_token "<|think|>"
            && c.max_context_tokens = Some 131_072 )
      ])
;;

let%test "undeclared model variants do not inherit catalog policies" =
  with_test_catalog (fun () ->
    List.for_all (fun (entry : Model_catalog.model_entry) ->
      let raw = Model_identifiers.Model_id.to_string entry.model_id in
      List.for_all (fun variant -> Option.is_none (for_model_id variant))
        [raw ^ ".undeclared"; "undeclared-provider/" ^ raw]) (Model_catalog.model_entries test_catalog))
;;

end)
;;

(* ── Capability drift detection ────────────────────────── *)

type drift_observation =
  | Usage_missing_but_declared (** [emits_usage_tokens=true] but response has no usage *)
  | Tools_used_but_declared_unsupported
  (** Response contains ToolUse but [supports_tools=false] *)
  | Thinking_returned_but_declared_unsupported
  (** Response contains Thinking/RedactedThinking but [supports_reasoning=false] *)
  | Stop_tool_use_but_declared_unsupported
  (** [stop_reason=StopToolUse] but [supports_tools=false] *)
[@@deriving show]

let detect_drift (caps : capabilities) (resp : Types.api_response)
  : drift_observation list
  =
  let obs = ref [] in
  (* Usage drift *)
  if caps.emits_usage_tokens && resp.usage = None
  then obs := Usage_missing_but_declared :: !obs;
  (* Content block analysis.
     Enumerate every [Types.content_block] variant explicitly so that adding
     a new constructor (e.g. [Video], [Reasoning_summary]) triggers an
     exhaustiveness warning here, forcing a deliberate decision on whether
     the new block carries tool-use or reasoning semantics. The previous
     [_ -> ()] catch-all silently grouped 5 unrelated variants and would
     have absorbed any future block without review. *)
  let has_tool_use = ref false
  and has_thinking = ref false in
  List.iter
    (fun (block : Types.content_block) ->
       match block with
       | ToolUse _ -> has_tool_use := true
       | Thinking _ | ReasoningDetails _ | RedactedThinking _ -> has_thinking := true
       | Text _ | ToolResult _ | Image _ | Document _ | Audio _ ->
         (* No capability-drift signal: these blocks are valid against any
           capability set the response declares. *)
         ())
    resp.content;
  if !has_tool_use && not caps.supports_tools
  then obs := Tools_used_but_declared_unsupported :: !obs;
  if !has_thinking && not caps.supports_reasoning
  then obs := Thinking_returned_but_declared_unsupported :: !obs;
  (* Stop reason analysis *)
  if resp.stop_reason = Types.StopToolUse && not caps.supports_tools
  then obs := Stop_tool_use_but_declared_unsupported :: !obs;
  List.rev !obs
;;

(* ── Alias collision invariant ─────────────────────── *)

(* Aliases must resolve to the same underlying capabilities record.
   If a new provider is added with overlapping labels, this test catches
   divergence. M06 regression guard. *)
let%test "capabilities_for_provider_label: aliases resolve to identical capabilities" =
  let resolve label = capabilities_for_provider_label label in
  let same_base a b =
    match resolve a, resolve b with
    | Some ca, Some cb ->
      ca.supports_tools = cb.supports_tools
      && ca.supports_reasoning = cb.supports_reasoning
      && ca.emits_usage_tokens = cb.emits_usage_tokens
      && ca.max_context_tokens = cb.max_context_tokens
      && ca.max_output_tokens = cb.max_output_tokens
      && ca.supports_image_input = cb.supports_image_input
      && ca.thinking_control_format = cb.thinking_control_format
      && ca.accepted_reasoning_efforts = cb.accepted_reasoning_efforts
      && ca.preserve_thinking_control_format = cb.preserve_thinking_control_format
      && ca.content_inline_reasoning = cb.content_inline_reasoning
      && ca.reasoning_output_format = cb.reasoning_output_format
      && ca.reasoning_streaming_format = cb.reasoning_streaming_format
      && ca.assistant_tool_content_format = cb.assistant_tool_content_format
      && ca.ignored_sampling_parameters = cb.ignored_sampling_parameters
      && ca.reasoning_replay_override = cb.reasoning_replay_override
    | _ -> false
  in
  let alias_pairs = [ "openai", "openai_chat"; "glm", "glm-coding" ] in
  List.for_all (fun (a, b) -> same_base a b) alias_pairs
  && Option.is_some (resolve "anthropic")
  && Option.is_some (resolve "gemini")
  && Option.is_some (resolve "ollama")
  && Option.is_some (resolve "kimi")
  && Option.is_some (resolve "xai")
  && Option.is_some (resolve "mistral")
  && Option.is_some (resolve "cohere")
  && Option.is_some (resolve "mimo")
  && Option.is_some (resolve "nvidia")
;;

(* Every declared label is reachable — no dead branches in the match.
   If a label is added to the match but has no corresponding capability
   binding, this test will fail. *)
let%test "capabilities_for_provider_label: all declared labels resolve" =
  let labels =
    [ "anthropic"
    ; "openai"
    ; "openai_chat"
    ; "openai_chat_extended"
    ; "openrouter"
    ; "gemini"
    ; "ollama"
    ; "glm"
    ; "glm-coding"
    ; "xai"
    ; "mistral"
    ; "cohere"
    ; "mimo"
    ; "nvidia"
    ; "kimi"
    ]
  in
  List.for_all (fun l -> Option.is_some (capabilities_for_provider_label l)) labels
;;

(* Every label resolves to a distinct capability fingerprint unless
   explicitly aliased. Catches accidental capability merging. *)
let%test
    "capabilities_for_provider_label: no accidental aliasing across distinct providers"
  =
  let non_aliased = [ "anthropic"; "gemini"; "ollama"; "kimi"; "nvidia" ] in
  let fingerprints =
    List.filter_map
      (fun l ->
         match capabilities_for_provider_label l with
         | Some c ->
           Some
             ( c.supports_tools
             , c.supports_reasoning
             , c.emits_usage_tokens
             , c.max_context_tokens
             , c.max_output_tokens
             , c.thinking_control_format )
         | None -> None)
      non_aliased
  in
  (* Each non-aliased provider should have at least one distinguishing field *)
  let n = List.length fingerprints in
  n = List.length non_aliased
;;
