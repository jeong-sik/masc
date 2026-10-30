(** Dynamic Model Catalog TOML loader.

    Integrates per-model capability and pricing overrides from TOML configurations,
    replacing hardcoded code-level registries. *)

type suggested_client = Claude_code | Codex
(** Presentation-only official-client suggestions. This is not provider
    ownership, capability admission or account entitlement. *)

type model_entry =
  { model_id : Model_identifiers.Model_id.t
  ; suggested_clients : suggested_client list
  ; base_label : string option
    (** Registry provider identity for OpenAI-compatible model families whose
        wire kind alone would otherwise collapse to [openai_compat]. This is
        not a capability preset; [base_label] remains the capability base. *)
  ; provider_name : string option
  ; max_context_tokens : int option
  ; serving_constraint : Serving_constraint.t option
    (** Evidence-backed input-token admission interval for this exact catalog
        row. It remains distinct from the declared model context window. *)
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
  ; json_schema_dialect : Capability_vocab.json_schema_dialect option
  ; supports_multimodal_inputs : bool option
  ; supports_image_input : bool option
  ; supports_audio_input : bool option
  ; supports_video_input : bool option
  ; supports_document_input : bool option
  ; modality_priority : string option
  ; task : Capability_vocab.task option
    (** Catalog-declared inference task for non-chat models (transcription,
        speech, image/video generation). Parsed fail-closed against
        {!Capability_vocab.task_values}; [None] means the entry declares no
        task — it is never inferred from the model id. *)
  ; supported_models : string list option
    (** Explicit exact model identities supported by this catalog row. A
        declaration must be a non-empty array of non-empty, exactly trimmed,
        unique strings. *)
  ; supports_native_streaming : bool option
  ; supports_system_prompt : bool option
  ; supports_assistant_prefill : bool option
    (** Whether Anthropic Messages accepts a final assistant continuation.
        Model-catalog declarations override the provider default. *)
  ; supports_prompt_caching : bool option
  ; supports_top_k : bool option
  ; supports_min_p : bool option
  ; supports_seed : bool option
  ; ignored_sampling_parameters : Capability_vocab.sampling_parameter list option
    (** Request sampling parameters that this catalog row declares must not be
        serialized. Parsed fail-closed against
        {!Capability_vocab.sampling_parameter_values}. *)
  ; thinking_control_format : Capability_vocab.thinking_control_format option
    (** Joined from the TOML [thinking_control_format] and [thinking_control_token]
        keys at parse time: [chat_template_token] carries its token in the
        [Chat_template_token] constructor, so a tokenless row (or a token without
        that format) fails closed during {!load_file}. *)
  ; anthropic_thinking_control : Capability_vocab.anthropic_thinking_control option
    (** Anthropic Messages API thinking-control policy. This is explicit
        catalog data; request builders must not infer it from model-id text. *)
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
  ; request_path : string
  ; requires_api_key : bool
  ; default_model : string option
  ; discovery_timeout_s : float option
  ; capabilities_base : string option
  ; capabilities_base_by_identity_kind : (Provider_kind.t * string) list
  ; supports_parallel_tool_suppression : bool
  ; serves_bare_models : Model_identifiers.Model_id.t list
  }

type t

(** Raised by {!global} when the build-time generated catalog violates the
    catalog syntax or schema. The generated catalog is an AGENT_CORE build invariant,
    so there is no empty-catalog fallback. *)
exception Invalid_embedded_catalog of string

val empty : t
val model_entries : t -> model_entry list
val provider_entries : t -> provider_entry list

type provider_reference =
  | Declared_provider of string
  | Anonymous_wire of Provider_kind.t
(** Whether the caller has an explicit provider identity or only a wire kind.
    A declared id may equal a wire-kind label. Anonymous wires never resolve
    a provider entry or its aliases. *)

val provider_entry_for_reference :
  t -> provider_reference -> provider_entry option
(** Resolve a declared provider id or alias in declaration order. *)

(** Parse and validate a model catalog from an in-memory TOML value. [source]
    is included in syntax-error diagnostics. This is the typed boundary for
    callers that already own the catalog contents; no global state is changed. *)
val of_toml_string : source:string -> string -> (t, string) result

val load_file : string -> (t, string) result

(** Load the build-time embedded default [models.toml].

    The embedded value is generated directly from the AGENT_CORE-owned root
    [models.toml], so linked consumers do not depend on a working directory,
    installation prefix, or host filesystem layout. Returns [Error] when the
    embedded TOML cannot be parsed; callers that require catalog-backed
    capability decisions should propagate that error rather than falling back
    silently. *)
val load_default : unit -> (t, string) result

(** Exact ASCII-case-insensitive lookup across provider-independent rows.
    Provider-scoped rows are excluded. [None] means the exact valid model ID
    is undeclared; no family, suffix or qualified-name reconstruction occurs. *)
val lookup : t -> Model_identifiers.Model_id.t -> model_entry option

(** Exact normalized lookup across provider-scoped rows. [provider_name] is
    trimmed and ASCII case-folded. The parsed [model_id] (no leading or
    trailing whitespace, by {!Model_identifiers.Model_id.of_string}) equals the
    row's declared [model_id] after ASCII case-folding. There is no family/prefix match on the model identity. The
    provider and model remain separate values; AGENT_CORE never synthesizes slash,
    colon, or dot-qualified model ids.

    When no row matches the requested [provider_name] verbatim, the name is
    canonicalized once through the catalog's own [[providers]] alias data (the
    first entry whose [id] or [aliases] contains the requested name, in
    declaration order) and the exact lookup is retried with that entry's [id].
    This applies the same alias-to-canonical-id policy the binding registry
    uses for its own catalog, so both capability paths answer alike. A
    verbatim row always wins over an alias-resolved one, and resolution is
    single-step (a canonical id is never re-resolved). Wire-kind labels
    ({!Provider_kind.to_string} values such as ["openai_compat"]) are never
    canonicalized: they are what configs without an explicit provider id
    synthesize, and an alias claiming one would capture every anonymous
    config of that wire kind.

    Provider-independent exact lookup remains exclusively in {!lookup}. *)
val lookup_for_provider
  :  t
  -> provider_name:string
  -> model_id:Model_identifiers.Model_id.t
  -> model_entry option

(** Exact scoped lookup with the caller's provider authority. Verbatim rows
    retain precedence. Declared ids and aliases may equal a wire-kind label;
    anonymous wires try only their verbatim wire label and never resolve a
    catalog provider or its aliases. Model identities still match exactly. *)
val lookup_for_provider_reference
  :  t
  -> provider:provider_reference
  -> model_id:Model_identifiers.Model_id.t
  -> model_entry option

val serves_bare_row : t -> provider_reference -> model_entry -> bool
(** Whether this original bare catalog row describes the provider. A declared
    provider must list the row's exact [model_id]. Anonymous native wires permit bare rows;
    anonymous OpenAI-compatible endpoints do not. Scoped rows return [false].
    This grants no authority to read a replacement capability manifest. *)

val lookup_model_for_provider
  :  t
  -> provider:provider_reference
  -> model_id:Model_identifiers.Model_id.t
  -> model_entry option
(** Exact scoped rows first, then the exact provider-independent row only
    when {!serves_bare_row} permits it. No prefix or shorter-row fallback occurs. A scoped row shadows the entire bare row, including fields
    that it leaves undeclared. *)

val lookup_model_for_provider_entry :
  t -> provider:provider_entry -> model_id:Model_identifiers.Model_id.t -> model_entry option
(** Resolve against the explicitly selected provider declaration. Its exact id,
    aliases and bare-model permissions replace the catalog provider entry;
    a replaced seed cannot grant authority to its replacement. *)

val model_entries_for_provider
  :  t
  -> provider:provider_reference
  -> model_entry list
(** Visible rows owned by this validated immutable catalog. Verbatim scoped
    rows precede canonical scoped rows, then permitted bare rows; a row with
    the same whole id in an earlier scope shadows the later row. Model ids
    remain verbatim. Enumeration preserves declared exact identities. *)

(** Return the active model catalog.

    Resolution order:
    - runtime override installed with {!set_global} (full replacement)
    - build-time embedded AGENT_CORE [models.toml]

    A provider or model fact is written in the embedded catalog and nowhere
    else. A deployment names which rows it uses in its runtime configuration;
    it does not restate what a row says. The second copy this module used to
    accept disagreed with the first on tool support, on replay policy, and on
    one model's window by a factor of five.

    The embedded result is cached after first computation. Invalid generated
    data raises {!Invalid_embedded_catalog}; it never becomes [None] or an
    empty catalog. AGENT_CORE does not inspect an environment variable for an
    alternate catalog. Callers that need a custom catalog must call
    {!load_file} and {!set_global} explicitly.

    {!clear_global} clears the runtime override and the cache. *)
val global : unit -> t option

val set_global : t -> unit

val clear_global : unit -> unit
