(** Immutable capability records and provider presets, independent of catalog
    publication, model lookup, configuration and credentials.

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
  | Reasoning_enabled
  (** Boolean [reasoning.enabled] control without categorical depth selection. *)
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
  ; declared_image_input : bool option
    (** Explicit image capability from a preset or catalog override; [None]
        preserves the absence of a declaration. *)
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

val with_declared_image_input : bool -> capabilities -> capabilities

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

(** Lookup capabilities for a provider label string.

    Recognized labels (case-insensitive, whitespace trimmed):
    [anthropic] / [claude], [openai_compat] / [openai],
    [gemini], [ollama], [glm] / [zhipu], [kimi],
    [xai], [mistral], [cohere], [mimo], [nvidia].

    Labels decode through {!Capability_preset} before resolution. Provider ids
    and wire kinds are not capability declarations.

    Returns [None] for labels outside this set. Intended for adapter
    layers that track provider kind as a string (e.g. config loaders,
    metrics exporters) and want a single SSOT for provider-level
    capability flags.

    @since 0.170.9 *)
val capabilities_for_provider_label : string -> capabilities option

val capabilities_of_preset : Capability_preset.t -> capabilities
(** Resolve an already decoded preset without provider identity, labels,
    catalog lookup or a permissive fallback. *)

(** Capabilities preset for a canonical {!Provider_kind.t}.

    Maps the closed variants directly to their presets without serialising
    the kind to a string and re-parsing it. Use this when the caller already
    holds a typed {!Provider_kind.t}. This is an explicit protocol baseline,
    not a provider-identity lookup or a catalog admission fallback.

    @since 0.209.0 *)
val capabilities_of_kind : Provider_kind.t -> capabilities

(** Merge Discovery ctx_size into existing capabilities. *)
val with_context_size : capabilities -> ctx_size:int -> capabilities
