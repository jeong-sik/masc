(** Provider capabilities -- per-provider/model feature flags and limits.

    @since 0.42.0
    @since 0.72.0 — added numeric limits, parallel tool calls, thinking split

    @stability Internal
    @since 0.93.1 *)

type thinking_control_format = Capability_vocab.thinking_control_format =
  | No_thinking_control (** No thinking control supported *)
  | Thinking_object (** Top-level [thinking] object plus optional [reasoning_effort]. *)
  | Thinking_object_adaptive
  | Thinking_object_only
  | Chat_template_kwargs
  | Chat_template_token of string
  (** Thinking toggled by a chat-template token (e.g. [<|think|>]) emitted in
          the system turn; the token is carried in the constructor. *)
  | Ollama_think
  | Reasoning_effort
  | Reasoning_effort_default_on
  (** Categorical depth with reasoning enabled when effort is omitted.
      Explicit enable is already satisfied; disable still requires an accepted [none]. *)
[@@deriving show, eq]

type preserve_thinking_control_format =
      Capability_vocab.preserve_thinking_control_format =
  | No_preserve_thinking_control
  | Thinking_object_keep_all
  | Chat_template_kwargs_preserve_thinking
  | Always_preserved_thinking
  | Thinking_object_clear_thinking
  (** Provider [thinking] object whose [clear_thinking] member gates prior-turn
      reasoning replay. See {!Capability_vocab.preserve_thinking_control_format}. *)

type uncontrolled_reasoning = Capability_vocab.uncontrolled_reasoning =
  | Provider_default_reasoning
  | Provider_enables_reasoning
      (** The wire turns reasoning on when the request carries no control, so
          an absent control is not thinking off. *)

type reasoning_replay_override = Capability_vocab.reasoning_replay_override =
  | Default_reasoning_replay
  | Force_no_replay
  | Force_drop_without_tool_preserve_with_tool
  | Force_latest_user_turn_tool_calls
  | Force_initial_system_latest_user_turn_tool_calls
  (** Replay tool-call reasoning only inside the structurally latest user turn. *)
  | Force_preserve_always
  | Force_preserve_responses_text
    (** Full plaintext replay on Responses only; other protocols keep their default. *)
  | Force_turn_scoped_system_context_preserve_always
  | Force_preserve_with_request_tools
    (** Replay all prior assistant reasoning exactly when outgoing tools are present. *)

type assistant_tool_content_format = Capability_vocab.assistant_tool_content_format =
  | Assistant_tool_content_null
  | Assistant_tool_content_empty_string

type chat_output_budget_field = Capability_vocab.chat_output_budget_field =
  | Chat_max_tokens
  | Chat_max_completion_tokens

type tool_schema_conformance = Capability_vocab.tool_schema_conformance =
  | Rich_json_schema
  | Conformant_subset_required

type content_inline_reasoning = Capability_vocab.content_inline_reasoning =
  | No_content_inline_reasoning
  | Think_tags
    (** Split tagged content for display; no original Chat carrier authority. *)
  | Think_tags_with_chat_replay
    (** Also retain/replay the original scalar Chat content through a validated witness. *)
      (** The model also wraps reasoning in [<think>] tags inside its content
          channel. Independent of {!reasoning_streaming_format}: a model can do
          both, and separating them is what keeps a wall of thinking out of the
          reply. *)

type reasoning_output_format = Capability_vocab.reasoning_output_format =
  | No_reasoning_output_format
  | Split_reasoning_fields

type reasoning_streaming_format = Capability_vocab.reasoning_streaming_format =
  | Default_reasoning_streaming
  | No_reasoning_streaming
  | Delta_reasoning_field of string
  | Delta_reasoning_field_and_details of string
  | Template_reasoning_streaming

type sampling_parameter = Capability_vocab.sampling_parameter =
  | Temperature
  | Top_p
  | Top_k
  | Min_p
  | Presence_penalty
  | Frequency_penalty
  | Seed

(** Catalog-declared inference task for non-chat models. [None] on every
    chat/completion model; a value is only ever set by an explicit [task]
    field on a model catalog entry — never inferred from the model id. *)
type task = Capability_vocab.task =
  | Transcription
  | Speech
  | Image_generation
  | Video_generation

(** Structured-output tier a resolved capability advertises, projected from the
    two capability booleans by {!structured_output_support}. The request-admission
    decision reads this typed view rather than provider identity. *)
type structured_output_support = Capability_vocab.structured_output_support =
  | No_structured_output
  | Json_object_only
  | Native_json_schema
[@@deriving show, eq]

type json_schema_dialect = Capability_vocab.json_schema_dialect =
  | Openai_json_schema
  | Json_object_schema

type anthropic_thinking_control =
  | Anthropic_adaptive_default
  | Anthropic_adaptive_disabled_through_high
      (** Explicit disabled thinking accepts low/medium/high effort, or the
          model default when effort is omitted; higher efforts require adaptive. *)
  | Anthropic_adaptive_between_tools
      (** [enable_thinking=false] selects [between_tools], not fully disabled
          thinking; only low/medium/high effort is accepted in that mode. *)
  | Anthropic_always_adaptive

val anthropic_thinking_control_of_vocab_value
  :  Capability_vocab.anthropic_thinking_control
  -> anthropic_thinking_control
(** Project a parsed vocabulary value to the resolved policy. Callers parse
    operator- or catalog-facing strings with
    {!Capability_vocab.anthropic_thinking_control_of_string} first. *)

type capabilities =
  { (* Numeric limits *)
    max_context_tokens : int option
  ; serving_constraint : Serving_constraint.t option
    (** Evidence-backed input-token serving interval for the exact resolved
        runtime row. This is not inferred from [max_context_tokens]. *)
  ; max_output_tokens : int option
  ; (* Tool use *)
    supports_tools : bool
  ; supports_tool_choice : bool
  ; supports_required_tool_choice : bool
  ; supports_named_tool_choice : bool
  ; supports_parallel_tool_calls : bool
  ; assistant_tool_content_format : assistant_tool_content_format
  ; chat_output_budget_field : chat_output_budget_field
    (** Which Chat Completions field carries the output-token budget — classic
        [max_tokens] or the reasoning-era [max_completion_tokens] OpenAI's
        gpt-5 family requires. Field name only; the #2517 omit/clamp receipt
        policy is unchanged. *)
  ; tool_schema_conformance : tool_schema_conformance
    (** Whether the provider rejects enum/oneOf/anyOf/allOf inside function
        parameter schemas; when conformant-only, the serializer projects tool
        schemas to the allowed subset. *)
  ; (* Thinking / reasoning *)
    supports_reasoning : bool
  ; accepted_reasoning_efforts : Reasoning_effort.t list option
    (** Model/provider-specific subset of canonical reasoning efforts accepted
        by the request wire format. [None] means no subset is declared and the
        dialect vocabulary applies; [Some values] is enforced before request
        serialization. *)
  ; thinking_control_format : thinking_control_format
  ; preserve_thinking_control_format : preserve_thinking_control_format
  ; content_inline_reasoning : content_inline_reasoning
  ; reasoning_output_format : reasoning_output_format
  ; reasoning_streaming_format : reasoning_streaming_format
  ; uncontrolled_reasoning : uncontrolled_reasoning
    (** What the wire does about reasoning when the request declares no
        control. Only [Provider_enables_reasoning] constrains anything: on
        such a wire a reasoning-capable model must be told an effort, because
        silence means reasoning on. *)
  ; reasoning_replay_override : reasoning_replay_override
  ; (* Output format *)
    supports_response_format_json : bool
  ; supports_structured_output : bool
  ; json_schema_dialect : json_schema_dialect
    (** Declared schema envelope for OpenAI-compatible Chat requests.
        This selects serialization only and grants no schema capability. *)
  ; (* Input modalities *)
    supports_multimodal_inputs : bool
  ; supports_image_input : bool
  ; supports_audio_input : bool
  ; supports_video_input : bool
  ; supports_document_input : bool
    (** Whether the row accepts a {!Types.Document} block as input. Independent
        of [supports_multimodal_inputs]: a row can be multimodal for images and
        still have no document representation on its wire. Serialization
        consults this at admission so a document is never re-labelled as
        another modality (agent-core boundary). *)
  ; modality_priority : Modality.priority
  ; (* Inference task *)
    task : task option
    (** Inference task declared by the model catalog entry (transcription,
        speech, image/video generation). [None] = no declared task; there is
        no model-id inference fallback. *)
  ; (* Protocol *)
    supports_native_streaming : bool
  ; supports_system_prompt : bool
  ; supports_assistant_prefill : bool
    (** Whether Anthropic Messages accepts a final assistant continuation.
        Enforced only on the Anthropic wire; Kimi retains its own contract.
        Model-catalog and explicit capability declarations override the provider
        default, which preserves existing continuation behavior. *)
  ; supports_prompt_caching : bool
  ; (* Sampling parameters *)
    supports_top_k : bool
  ; supports_min_p : bool
  ; supports_seed : bool
    (** Deterministic seed for reproducible sampling.
      @since 0.185.0 *)
  ; ignored_sampling_parameters : sampling_parameter list
    (** Request sampling parameters that must not be serialized for this
        provider/model even when a caller supplied them. *)
  ; (* Usage reporting *)
    emits_usage_tokens : bool
    (** Whether the provider's standard response carries usage tokens
      (input_tokens/output_tokens).

      @since 0.170.9 *)
  ; (* Model limitations *)
    supported_models : string list option
    (** Explicit list of supported models if the provider is restricted
        to a specific set (e.g. Kimi to "kimi-for-coding").
        [None] means no strict client-side restriction. *)
  }

val default_capabilities : capabilities

(** Structured-output tier a resolved capability record advertises. Total
    projection of [supports_structured_output] and [supports_response_format_json]:
    native schema support is the top tier regardless of the JSON-mode flag,
    JSON mode alone is [Json_object_only], neither is [No_structured_output]. This
    is the typed capability {!Provider_config.validate_output_schema_request}
    reads instead of branching on provider identity. *)
val structured_output_support : capabilities -> structured_output_support

val anthropic_capabilities : capabilities
val kimi_capabilities : capabilities
val mimo_capabilities : capabilities
val openai_compat_chat_capabilities : capabilities
val openai_compat_chat_extended_capabilities : capabilities
val gemini_capabilities : capabilities
val ollama_capabilities : capabilities
val ollama_cloud_capabilities : capabilities
val glm_capabilities : capabilities

(** NVIDIA NIM Nvidia capabilities: Llama-based, chat_template_kwargs thinking.
    @since 0.185.0 *)
val provider_l_capabilities : capabilities

val sampling_parameter_to_string : sampling_parameter -> string

(** Resolve the chat-template token for an exact normalized provider/model
    catalog row whose [thinking_control_format] is [Chat_template_token]. A
    missing exact pair returns [None]; this function never falls back to a
    provider-independent model family. The token is catalog data, not a
    hardcoded backend constant. *)
val thinking_control_token_for_provider_model_id
  :  provider_label:string
  -> model_id:string
  -> string option

(** Effective request-level parallel tool-use disablement.

    Explicit caller disablement always wins. Otherwise, when a request carries
    tools and the selected provider/model says it does not support parallel tool
    calls, callers should serialize the provider-specific "disable parallel
    tool use" wire field when the provider has one. *)
val effective_disable_parallel_tool_use
  :  caller_disabled:bool
  -> supports_parallel_tool_calls:bool
  -> tools_present:bool
  -> bool

(** Resolve Anthropic thinking control from the model catalog, then the
    capability manifest when the catalog has no matching row. [None] means
    neither source declares an Anthropic thinking policy. Bare rows only: the
    lookup skips provider-qualified rows. *)
val anthropic_thinking_control_for_model_id : string -> anthropic_thinking_control option

(** Resolve the request's authoritative row with the same provider policy as
    capabilities. A scoped row without a policy stays [None]. Declared
    providers read bare catalog rows only when permitted and never a manifest;
    anonymous native wires retain bare catalog/manifest lookup. *)
val anthropic_thinking_control_for_provider_model_id
  :  provider:Model_catalog.provider_reference
  -> model_id:string
  -> anthropic_thinking_control option

(** Look up capabilities for [model_id] in the loaded model catalog only
    (no manifest consultation).

    The catalog is resolved by {!Model_catalog.global}: an explicit runtime
    override installed via {!Model_catalog.set_global}, otherwise the
    build-time embedded AGENT_CORE [models.toml]. Embedding hosts and test harnesses
    can install an explicit runtime override; AGENT_CORE performs no environment-based
    catalog discovery.

    Returns [None] when no catalog is available or when no catalog entry
    prefix-matches [model_id]; there is no in-code fallback table. *)
val for_model_id_catalog : string -> capabilities option

(** Resolve an explicit provider/model pair while preserving whether the
    caller declared an identity or knows only a wire kind. Exact scoped rows
    win. A declared provider reads bare catalog rows only when its catalog
    entry declares [serves_bare_models]; it never borrows capability-manifest
    facts. Anonymous native wires retain model/manifest fallback; anonymous
    OpenAI-compatible endpoints do not borrow bare model facts. Provider bases
    answer last. Anonymous wire labels never resolve catalog provider aliases.

    [wire] selects the base for providers with multiple wire kinds. [None]
    uses the provider's default base. *)
val for_provider_model_id
  :  wire:Provider_kind.t option
  -> provider:Model_catalog.provider_reference
  -> model_id:string
  -> capabilities option

(** Immutable resolution for one request. Missing facts remain missing even
    if process catalogs are replaced later. *)
type request_policy

val resolve_request_policy
  :  wire:Provider_kind.t
  -> provider:Model_catalog.provider_reference
  -> model_id:string
  -> request_policy

val resolve_bound_request_policy :
  catalog:Model_catalog.t option -> provider:Model_catalog.provider_entry ->
  capabilities:capabilities -> model_id:string -> request_policy
(** Pure resolution from the selection-owned catalog and provider declaration.
    The selected wire base precedes the model base; explicit model fields then
    override that base, with selected provider defaults when no base is declared. No global
    catalog or manifest is read; absent thinking controls remain absent. *)

val request_policy_capabilities : request_policy -> capabilities option
val request_policy_anthropic_thinking_control :
  request_policy -> anthropic_thinking_control option


(** Lookup capabilities for a known model_id.

    Checks the globally loaded model catalog first, then the capability
    manifest. Returns [None] when neither source has a matching entry;
    there is no built-in fallback table. *)
val for_model_id : string -> capabilities option

(** Lookup capabilities for a provider label string.

    Recognized labels (case-insensitive, whitespace trimmed):
    [anthropic] / [claude], [openai_compat] / [openai],
    [gemini], [ollama], [glm] / [zhipu], [kimi],
    [xai], [mistral], [cohere], [mimo], [nvidia].

    Canonical labels and aliases for the closed {!Provider_kind.t} space are
    normalized to a typed kind first, then delegated to {!capabilities_of_kind}.
    String-only presets that are not expressible as a provider kind stay at this
    label boundary.

    Returns [None] for labels outside this set. Intended for adapter
    layers that track provider kind as a string (e.g. config loaders,
    metrics exporters) and want a single SSOT for provider-level
    capability flags.

    @since 0.170.9 *)
val capabilities_for_provider_label : string -> capabilities option

(** Capabilities preset for a canonical {!Provider_kind.t}.

    Maps the 7 closed variants directly to their presets without serialising
    the kind to a string and re-parsing it. Use this when the caller already
    holds a typed {!Provider_kind.t}; {!capabilities_for_provider_label}
    delegates canonical labels here and only keeps string-only presets (e.g.
    ["openai_chat_extended"], ["ollama_cloud"], ["xai"], ["mistral"],
    ["cohere"], ["mimo"], ["nvidia"]) at the label boundary.

    @since 0.209.0 *)
val capabilities_of_kind : Provider_kind.t -> capabilities

(** Merge Discovery ctx_size into existing capabilities. *)
val with_context_size : capabilities -> ctx_size:int -> capabilities

(** {2 Capability Manifest} *)

(** Apply a {!Capability_manifest.entry} on top of a provider-preset base.

    [entry.base_label] (if present) is a parsed {!Capability_manifest.base_label}
    and is resolved via {!capabilities_for_provider_label}; an absent label falls
    back to {!default_capabilities}.  Each [Some] field in [entry] overrides the
    corresponding field; [None] fields inherit from the base.

    Capability manifests do not carry evidence-backed serving constraints.
    Those constraints require provenance and validity fields and are therefore
    accepted only through the model catalog declaration path.

    @since 0.188.0 *)
val apply_manifest_entry : Capability_manifest.entry -> capabilities

(** Look up capabilities for [model_id] against an explicit manifest,
    falling back to the catalog lookup ({!for_model_id_catalog}) on a
    miss.

    Useful when the caller does not want to install a process-wide manifest.

    @since 0.188.0 *)
val for_model_id_with_manifest : Capability_manifest.t -> string -> capabilities option

(** {2 Capability Drift Detection} *)

type drift_observation =
  | Usage_missing_but_declared
  | Tools_used_but_declared_unsupported
  | Thinking_returned_but_declared_unsupported
  | Stop_tool_use_but_declared_unsupported
[@@deriving show]

(** Compare an {!api_response} against declared {!capabilities}.
    Returns observations where actual behavior contradicts
    the capability record. Empty list = no drift detected.

    @since 0.185.0 *)
val detect_drift : capabilities -> Types.api_response -> drift_observation list
