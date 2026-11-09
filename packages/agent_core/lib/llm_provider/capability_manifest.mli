(** Strict JSON input for model-specific capability declarations.

    Allows operators and model deployers to describe capabilities for
    custom, quantized, or future model variants without requiring an
    AGENT_CORE code change.

    The manifest is a JSON file with the following shape:

    {[
      {
        "schema_version": 2,
        "models": [
          {
            "model_id": "my-local-llama",
            "base": "openai_chat",
            "max_context_tokens": 131072,
            "supports_tools": true,
            "supports_reasoning": false
          }
        ]
      }
    ]}

    Embedding applications parse with {!load_file} or {!of_json}, then compose
    the input with [Model_catalog.with_model_overrides] before selecting provider
    bindings or freezing requests. All execution consumers read that one model
    catalog. This parser owns no process-global policy source.

    @since 0.188.0 *)

(** One entry in the capability manifest.

    [model_id] is an exact non-empty model identity without leading or trailing
    whitespace. ASCII case is folded for equality; no suffix, family, separator
    or provider-name transformation is applied.  [base] names a provider preset from
    {!Capability_preset} (e.g.
    ["openai_chat"], ["anthropic"]); when absent, the built-in
    [default_capabilities] is used.  Unrecognised labels are rejected
    by the JSON parser; admitted entries carry the closed preset directly.

    All other fields are optional overrides: a [None] value means
    "inherit from the base", a [Some v] value replaces the base value. *)
type entry =
  { model_id : Model_identifiers.Model_id.t
  ; base_label : Capability_preset.t option
    (** Shared closed provider preset, independent of provider identity. *)
  ; max_context_tokens : int option (** [None] = inherit from base. *)
  ; max_output_tokens : int option (** [None] = inherit from base. *)
  ; supports_tools : bool option
  ; supports_tool_choice : bool option
  ; supports_required_tool_choice : bool option
  ; supports_named_tool_choice : bool option
  ; supports_parallel_tool_calls : bool option
  ; assistant_tool_content_format : string option
  ; chat_output_budget_field : string option
  ; tool_schema_conformance : string option
    (** Wire shape for assistant messages that contain tool calls but no visible
        text (null / empty_string). *)
  ; supports_reasoning : bool option
  ; accepted_reasoning_efforts : string list option
    (** Optional subset of canonical reasoning effort values this model accepts
        (none / minimal / low / medium / high / xhigh). *)
  ; supports_response_format_json : bool option
  ; supports_structured_output : bool option
  ; json_schema_dialect : Capability_vocab.json_schema_dialect option
  ; supports_multimodal_inputs : bool option
  ; supports_image_input : bool option
  ; supports_audio_input : bool option
  ; supports_video_input : bool option
  ; supports_document_input : bool option
  ; modality_priority : string option
    (** Canonical multimodal block ordering policy (preserve_input_order /
        visual_first, plus the aliases in
        {!Capability_vocab.modality_priority_values}); unknown values fail
        closed in {!of_json}. Applied in [Capabilities.apply_catalog_entry]. *)
  ; supports_native_streaming : bool option
  ; supports_system_prompt : bool option
  ; supports_assistant_prefill : bool option
  ; supports_prompt_caching : bool option
  ; supports_top_k : bool option
  ; supports_min_p : bool option
  ; supports_seed : bool option
  ; ignored_sampling_parameters : Capability_vocab.sampling_parameter list option
    (** Request sampling parameters that this manifest row declares must not be
        serialized. *)
  ; thinking_control_format : Capability_vocab.thinking_control_format option
    (** Canonical thinking-wire format (none / thinking_object /
        thinking_object_adaptive / thinking_object_only / chat_template_kwargs /
        chat_template_token / reasoning_effort / enable_thinking); applied in
        [Capabilities.apply_catalog_entry]. Joined from the JSON
        [thinking_control_format] and [thinking_control_token] members at parse
        time — [chat_template_token] carries its token in the constructor, so a
        tokenless declaration fails closed in {!of_json}. *)
  ; anthropic_thinking_control : Capability_vocab.anthropic_thinking_control option
    (** Anthropic Messages API thinking policy. This is model declaration data,
        not an identifier-derived guess. *)
  ; preserve_thinking_control_format : string option
    (** Canonical historical reasoning preservation wire format (none /
        thinking_object_keep_all / chat_template_kwargs_preserve_thinking /
        top_level_preserve_thinking / always_preserved); applied in
        [Capabilities.apply_catalog_entry]. *)
  ; content_inline_reasoning : string option
  ; reasoning_output_format : string option
    (** Canonical request-side reasoning output split control (none /
        split_reasoning_fields); applied in [Capabilities.apply_catalog_entry]. *)
  ; reasoning_streaming_format : string option
    (** Canonical streaming reasoning side-channel (default / none /
        template_parser / delta:<field>); applied in
        [Capabilities.apply_catalog_entry]. *)
  ; reasoning_replay : string option
    (** Optional multi-turn reasoning replay policy override (default /
        no_replay / drop_without_tool / preserve_always). *)
  ; emits_usage_tokens : bool option
    (** Whether the standard response carries usage tokens; applied in
        [Capabilities.apply_catalog_entry]. *)
  ; supported_models : string list option
    (** Exact client-side model allow-list; applied in
        [Capabilities.apply_catalog_entry]. {!of_json} rejects an empty list
        and blank, padded, or duplicate ids. *)
  }

(** A validated immutable capability manifest. Only the strict parser
    constructs this value; raw entry lists cannot bypass admission.
    Declaration order is retained for distinct model IDs; it does not affect lookup. *)
type t

val entries : t -> entry list
(** Read-only declaration-order view. Changing this list or a copied entry
    does not construct an admitted manifest. *)

(** [of_json json] parses a manifest from a [Yojson.Safe.t] value.

    Returns [Error msg] when [schema_version] is missing or not 2, a closed
    root or entry object contains an unknown or duplicate field, an optional
    field has the wrong JSON type, an integer literal is outside the native
    [int] range, [model_id] is missing, empty, or padded with whitespace,
    [models] is absent or is not an explicit list,
    [base] or another closed-vocabulary field (e.g. [modality_priority]) names
    an unknown value, or [supported_models] is empty or holds a blank, padded,
    or duplicate id. Duplicate model declarations are rejected by the same
    ASCII case-insensitive identity used by lookup. The non-operational [_comment]
    field is accepted at the root and entry levels. *)
val of_json : Yojson.Safe.t -> (t, string) result

(** [load_file path] reads and parses a manifest from the given file
    path.  Returns [Error msg] on I/O or JSON parse errors. *)
val load_file : string -> (t, string) result

(** [lookup t model_id] returns the entry with that exact model identity, using
    {!Model_identifiers.Model_id.equal}. Returns [None] for an undeclared model. *)
val lookup : t -> Model_identifiers.Model_id.t -> entry option
