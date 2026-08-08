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
  | Enable_thinking
  (** DashScope-style top-level [enable_thinking] / [preserve_thinking] bools
      plus optional [thinking_budget]. *)
[@@deriving show, eq]

type preserve_thinking_control_format =
      Capability_vocab.preserve_thinking_control_format =
  | No_preserve_thinking_control
  | Thinking_object_keep_all
  | Chat_template_kwargs_preserve_thinking
  | Top_level_preserve_thinking
  | Always_preserved_thinking
  | Thinking_object_clear_thinking
  (** Provider [thinking] object whose [clear_thinking] member gates prior-turn
      reasoning replay. See {!Capability_vocab.preserve_thinking_control_format}. *)

type reasoning_replay_override = Capability_vocab.reasoning_replay_override =
  | Default_reasoning_replay
  | Force_no_replay
  | Force_drop_without_tool_preserve_with_tool
  | Force_latest_user_turn_tool_calls
  (** Replay tool-call reasoning only inside the structurally latest user turn. *)
  | Force_preserve_always

type assistant_tool_content_format = Capability_vocab.assistant_tool_content_format =
  | Assistant_tool_content_null
  | Assistant_tool_content_empty_string

type reasoning_output_format = Capability_vocab.reasoning_output_format =
  | No_reasoning_output_format
  | Split_reasoning_fields

type reasoning_streaming_format = Capability_vocab.reasoning_streaming_format =
  | Default_reasoning_streaming
  | No_reasoning_streaming
  | Delta_reasoning_field of string
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

type anthropic_thinking_control =
  | Anthropic_manual_budget
  | Anthropic_adaptive_default
  | Anthropic_adaptive_preferred
  | Anthropic_adaptive_only
  | Anthropic_always_adaptive

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
  ; (* Thinking / reasoning *)
    supports_reasoning : bool
  ; supports_extended_thinking : bool
  ; supports_reasoning_budget : bool
  ; accepted_reasoning_efforts : Reasoning_effort.t list option
    (** Model/provider-specific subset of canonical reasoning efforts accepted
        by the request wire format. [None] means no subset is declared and the
        dialect vocabulary applies; [Some values] is enforced before request
        serialization. *)
  ; thinking_control_format : thinking_control_format
  ; preserve_thinking_control_format : preserve_thinking_control_format
  ; reasoning_output_format : reasoning_output_format
  ; reasoning_streaming_format : reasoning_streaming_format
  ; reasoning_replay_override : reasoning_replay_override
  ; (* Output format *)
    supports_response_format_json : bool
  ; supports_structured_output : bool
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
        another modality (oas#2744). *)
  ; modality_priority : Modality.priority
  ; (* Inference task *)
    task : task option
    (** Inference task declared by the model catalog entry (transcription,
        speech, image/video generation). [None] = no declared task; there is
        no model-id inference fallback. *)
  ; (* Protocol *)
    supports_native_streaming : bool
  ; supports_system_prompt : bool
  ; supports_caching : bool
  ; supports_prompt_caching : bool
  ; prompt_cache_alignment : int option
  ; (* Sampling parameters *)
    supports_top_k : bool
  ; supports_min_p : bool
  ; supports_seed : bool
    (** Deterministic seed for reproducible sampling.
      @since 0.185.0 *)
  ; supports_seed_with_images : bool
    (** Whether seed determinism is maintained when image inputs are present.
      Local providers (Ollama) achieve near-perfect reproducibility; cloud
      providers (Openai, Gemini) do not guarantee it.
      @since 0.185.0 *)
  ; ignored_sampling_parameters : sampling_parameter list
    (** Request sampling parameters that must not be serialized for this
        provider/model even when a caller supplied them. *)
  ; (* Advanced modalities *)
    supports_computer_use : bool
  ; supports_code_execution : bool
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
val dashscope_capabilities : capabilities
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
    neither source declares an Anthropic thinking policy. *)
val anthropic_thinking_control_for_model_id : string -> anthropic_thinking_control option

(** Look up capabilities for [model_id] in the loaded model catalog only
    (no manifest consultation).

    The catalog is resolved by {!Model_catalog.global}: an explicit runtime
    override installed via {!Model_catalog.set_global}, otherwise the
    build-time embedded OAS [models.toml]. Embedding hosts and test harnesses
    can install an explicit runtime override; OAS performs no environment-based
    catalog discovery.

    Returns [None] when no catalog is available or when no catalog entry
    prefix-matches [model_id]; there is no in-code fallback table. *)
val for_model_id_catalog : string -> capabilities option

(** Look up capabilities for the explicit provider/model pair. A
    provider-scoped catalog row matches only when its normalized
    [provider_name] and complete normalized [id_prefix] equal [provider_label]
    and [model_id], respectively. OAS never rewrites either value into slash,
    colon, or dot-qualified candidates, and does not apply family/prefix
    matching inside the provider scope. When the exact pair is absent,
    [allow_bare_fallback] controls whether this falls back to a
    provider-independent {!for_model_id} row. *)
val for_provider_model_id
  :  allow_bare_fallback:bool
  -> provider_label:string
  -> model_id:string
  -> capabilities option

(** Lookup capabilities for a known model_id.

    Checks the globally loaded model catalog first, then the capability
    manifest. Returns [None] when neither source has a matching entry;
    there is no built-in fallback table. *)
val for_model_id : string -> capabilities option

(** Lookup capabilities for a provider label string.

    Recognized labels (case-insensitive, whitespace trimmed):
    [anthropic] / [claude], [openai_compat] / [openai],
    [gemini], [ollama], [glm] / [zhipu], [kimi], [dashscope],
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

(** Update tool support from Discovery. *)
val with_tool_support : capabilities -> supports_tools:bool -> capabilities

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
