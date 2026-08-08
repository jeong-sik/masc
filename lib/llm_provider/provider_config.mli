(** Lightweight provider configuration for standalone LLM calls.

    Decoupled from agent_state/agent_config. Consumers can
    construct this directly and pass it to {!Complete.complete}.

    @since 0.46.0

    @stability Internal
    @since 0.93.1 *)

(** Provider kind determines request/response wire format.

    Re-exported from {!Provider_kind} — the underlying type now lives there so
    it can be shared with {!Types} without creating a dependency cycle. *)
type provider_kind = Provider_kind.t =
  | Anthropic
  | Kimi (** Kimi direct API: Anthropic-compatible [/v1/messages]. @since 0.169.0 *)
  | OpenAI_compat
  | Ollama
  (** Ollama native [/api/chat] wire format with [think] control and no
      [tool_choice]. @since 0.112.0 *)
  | Gemini
  | Glm
  (** ZhipuAI GLM native: OpenAI_compat wire format + JWT auth + GLM error parsing. @since 0.83.0 *)
  | DashScope

(** Default HTTP request path for a given provider kind.
    Single source of truth shared by [make] and direct record-literal
    callers; pin the [kind] and the [request_path] together via this
    helper to avoid the two fields drifting out of sync. *)
val request_path_default_for_kind : provider_kind -> string

type t =
  { kind : provider_kind
  ; provider_id : string option
    (** Exact provider/catalog identity carried independently from [model_id]
        and endpoint location. [None] means only the generic wire [kind] is
        known; OAS never reconstructs a provider id from URL or model syntax. *)
  ; model_id : string
  ; base_url : string
  ; api_key : Secret.t
    (** API key / token as an abstract secret.  Never log or serialize
        this field directly; use {!auth_headers_for_config} at HTTP request
        time. *)
  ; headers : (string * string) list
  ; request_path : string
  ; max_tokens : int option
    (** [None] = resolve from model capabilities at request time. @since 0.123.0 *)
  ; max_context : int option
    (** Provider's context window limit in tokens. When set, downstream callers may truncate messages to fit before dispatch. @since 0.120.0 *)
  ; max_request_body_bytes : int option
    (** Exact serialized HTTP request-body limit for this resolved target.
        [None] means the target declares no byte limit; OAS never invents one
        from provider kind, endpoint URL, or model id.  The final provider wire
        body is measured after serialization and rejected before dispatch when
        it exceeds this value. @since 0.223.0 *)
  ; temperature : float option
  ; top_p : float option
  ; top_k : int option
  ; min_p : float option
  ; system_prompt : string option
  ; enable_thinking : bool option
  ; preserve_thinking : bool option
    (** Request historical reasoning preservation when the selected provider
        exposes a preserve toggle. The concrete wire field is selected by
        [Capabilities.preserve_thinking_control_format]: chat-template kwargs,
        top-level [preserve_thinking], [thinking.keep], or no request field for
        always-preserved models.
        @since 0.205.12 *)
  ; thinking_budget : int option
    (** Explicit token budget for provider wires that accept a numeric thinking
        budget. [None] omits it. This value is never converted into
        {!Reasoning_effort.t}. *)
  ; reasoning_effort : Reasoning_effort.t option
    (** Explicit effort value for provider wires that accept categorical
        reasoning effort. [None] omits the field. This is independent of
        [thinking_budget]; the SDK never converts token counts into effort
        categories. *)
  ; clear_thinking : bool option
  ; tool_stream : bool
  ; tool_choice : Types.tool_choice option
  ; disable_parallel_tool_use : bool
  ; response_format : Types.response_format
  ; cache_system_prompt : bool
  ; supports_tool_choice_override : bool option
    (** Override the registry default for [supports_tool_choice].
      [None] = use the per-kind default from {!Capabilities}.
      [Some b] = force [b].

      Kept on this low-level config so downstream callers (e.g. declaring
      per-entry capability facts in their own config file) can inject
      a verified model-side support flag without the SDK matching on
      [model_id]. The SDK stays model-agnostic; the consumer declares.

      Design principle: declaration-over-probing. The SDK does not run
      any capability probe against the provider endpoint (Ollama's
      [/api/show] exposes no authoritative tool_choice flag; LiteLLM
      encodes this in a static JSON table and has the same blind spot).
      Instead of guessing from model_id substrings, the consumer owns
      the policy and declares it.

      @since 0.150.0 *)
  ; supports_structured_output_override : bool option
    (** Override whether this concrete OpenAI-compatible endpoint supports
        provider-native JSON-schema output requests. This is intentionally an
        endpoint declaration, not a model capability override:
        {!validate_output_schema_request} still requires the resolved model
        capability to advertise [supports_structured_output].

        [None] keeps the built-in endpoint policy.
        [Some true] allows verified self-hosted/OpenAI-compatible endpoints
        such as RunPod/vLLM/SGLang gateways.
        [Some false] fail-closes even when the host would otherwise be
        accepted.

        @since 0.207.0 *)
  ; model_capabilities_override : Capabilities.capabilities option
    (** Explicit capability declaration for this concrete provider endpoint.
        This is projected from provider catalog entries that have verified the
        endpoint/runtime contract. It lets declared OpenAI-compatible runtimes
        opt into non-default thinking/reasoning dialects without forcing raw
        OpenAI-compatible endpoints to infer those dialects from model-id
        prefixes alone.

        [None] uses the normal provider/model catalog resolution policy.

        @since 0.208.4 *)
  ; keep_alive : string option
    (** Ollama [keep_alive] request field. Accepted values: integer
      seconds ({"-1"}, {"0"}, {"3600"}) or duration strings ({"5m"},
      {"30m"}, {"24h"}). [None] omits the field. The SDK does not
      invent a residency policy; callers that require permanent residency
      must explicitly provide {"-1"}. Honored only by the Ollama backend;
      ignored by other kinds.
      @since 0.171.0 *)
  ; internal_model_rotation_count : int option
    (** Number of model attempts the subprocess CLI is configured to
      cycle through internally before yielding a final response.
      [None] = SDK has no opinion (the default for non-CLI providers
      and CLI providers that do not expose rotation visibility).

      Some vendor CLIs cycle through multiple candidate models and return only
      the final attempt's outcome. Without this hint a single CLI call appears
      as one provider attempt to the downstream observer even though the vendor
      may perform multiple internal attempts with its own delay policy.
      Consumers can render that declared rotation in traces without hard-coding
      a vendor-specific count.

      The SDK does not enforce or schedule the rotation; it remains
      the CLI binary's responsibility. This field is purely
      declarative metadata for observing one [Complete.complete] call.

      Honored only as an advisory hint; ignored for non-CLI kinds.
      @since 0.182.0 *)
  ; num_ctx : int option
    (** Ollama [num_ctx] option. Per-request context window allocation
      in tokens. Drives KV cache RAM allocation. [None] leaves the
      field unset so Ollama uses its own default. Non-positive explicit
      values are rejected at request construction.
      Honored only by the Ollama backend; ignored by other kinds.
      Profiles may surface this field so small-model configurations
      can pick a smaller window than long-context configurations.
      @since 0.171.0 *)
  ; seed : int option
    (** Deterministic seed for providers that support it. When [Some n],
      injected into the request body as ["seed": n] when the model's
      {!Capabilities.t.supports_seed} is [true], otherwise rejected.
      [None] omits the field.
      @since 0.185.0 *)
  ; previous_response_id : string option
    (** OpenAI Responses API conversation-state pointer. When [Some id] and
      [request_path] targets [/v1/responses], the Responses request includes
      ["previous_response_id": id]. This is intentionally separate from manual
      item replay: callers choose the state strategy explicitly instead of the
      SDK inferring one from message history. Ignored by non-Responses request
      builders.
      @since 0.207.10 *)
  ; connect_timeout_s : float option
    (** Explicit connect + initial-response-headers wall-clock timeout.
      [None] applies no SDK-owned deadline. [Some s] forces [s] seconds for
      the connect/headers phase only — it is independent of
      the body deadline ([body_timeout_s]) and the inter-chunk stream-idle
      deadline ([stream_idle_timeout_s]).

      The consumer declares any deadline; OAS never selects one from provider
      kind, URL, model, or process environment.
      @since 0.207.9 *)
  ; max_concurrent_requests : int option
    (** Per-endpoint bound on concurrent in-flight completion dispatches.
      [None] applies no bound. [Some n] admits at most [n] concurrent
      dispatches process-wide for this endpoint identity
      [(kind, base_url, api-key identity)]; excess dispatches wait in FIFO
      order (see {!Provider_admission}). Must be [>= 1] when declared;
      {!Complete.complete} rejects the request otherwise.

      The consumer declares the allowance its provider account grants; OAS
      never selects one from provider kind, URL, model, or process
      environment.
      @since 0.216.0 *)
  }

(** Default config for quick construction. Only [kind], [model_id],
    [base_url], and [request_path] are required; rest use safe defaults. *)
val make
  :  kind:provider_kind
  -> model_id:string
  -> base_url:string
  -> ?provider_id:string
  -> ?api_key:string
  -> ?headers:(string * string) list
  -> ?request_path:string
  -> ?max_tokens:int
  -> ?max_context:int
  -> ?max_request_body_bytes:int
  -> ?temperature:float
  -> ?top_p:float
  -> ?top_k:int
  -> ?min_p:float
  -> ?system_prompt:string
  -> ?enable_thinking:bool
  -> ?preserve_thinking:bool
  -> ?thinking_budget:int
  -> ?reasoning_effort:Reasoning_effort.t
  -> ?clear_thinking:bool
  -> ?tool_stream:bool
  -> ?tool_choice:Types.tool_choice
  -> ?disable_parallel_tool_use:bool
  -> ?response_format:Types.response_format
  -> ?cache_system_prompt:bool
  -> ?supports_tool_choice_override:bool
  -> ?supports_structured_output_override:bool
  -> ?model_capabilities_override:Capabilities.capabilities
  -> ?keep_alive:string
  -> ?internal_model_rotation_count:int
  -> ?num_ctx:int
  -> ?seed:int
  -> ?previous_response_id:string
  -> ?connect_timeout_s:float
  -> ?max_concurrent_requests:int
  -> unit
  -> t

(** Lowercase string representation of the wire-format kind.
    Returns the variant name in lowercase (e.g. [Anthropic] -> ["anthropic"]).
    Exhaustive match: adding a new variant triggers a compile error.
    @since 0.100.0 *)
val string_of_provider_kind : provider_kind -> string

(** All provider kinds in canonical order. Re-export of
    {!Provider_kind.all} — see that module's docs for intent.
    @since 0.166.0 *)
val all_provider_kinds : provider_kind list

(** Conventional API key env var name per kind. Re-export of
    {!Provider_kind.default_api_key_env}. Returns [None] for kinds
    that do not have a universally-agreed env var (local / transport-
    mediated / OpenAI-compatible spaces where the env name is
    consumer-specified).
    @since 0.166.0 *)
val default_api_key_env : provider_kind -> string option

(** Canonical inverse of {!string_of_provider_kind}.

    Accepts every lowercase form produced by {!string_of_provider_kind}.

    The match is case-insensitive; leading and trailing whitespace is
    trimmed. Returns [None] for any other input so callers fail fast
    rather than silently falling back to a default provider.

    Use this instead of scattered ad-hoc string-to-kind matches to keep all
    string drift in one place.
    @since 0.165.0 *)
val provider_kind_of_string : string -> provider_kind option

(** {1 Serializers}

    Hand-written to emit the wire-format produced by
    {!string_of_provider_kind} (for example ["anthropic"]) rather than the
    capitalised constructor name that [\[@@deriving yojson\]] would default
    to (["Anthropic"]).

    Records that embed [provider_kind] (for example
    [Types.inference_telemetry]) can therefore add it to a derived-yojson
    record without breaking the current on-disk / over-the-wire format.
    @since 0.165.0 *)

val pp_provider_kind : Format.formatter -> provider_kind -> unit
val show_provider_kind : provider_kind -> string
val provider_kind_to_yojson : provider_kind -> Yojson.Safe.t

val provider_kind_of_yojson
  :  Yojson.Safe.t
  -> provider_kind Ppx_deriving_yojson_runtime.error_or

(** OpenAI-compatible reasoning effort levels accepted on the wire.
    [reasoning_effort_to_string] is the only string serialization surface for
    these values. *)
type reasoning_effort = Reasoning_effort.t =
  | None_
  | Minimal
  | Low
  | Medium
  | High
  | XHigh
  | Max

val all_reasoning_efforts : reasoning_effort list
val reasoning_effort_to_string : reasoning_effort -> string
val reasoning_effort_of_string : string -> reasoning_effort option

(** Resolve the [thinking.clear_thinking] member: the explicit field, else the
    inverse of [preserve_thinking], else the wire default [true]. SSOT for both
    request builders. *)
val clear_thinking_value
  :  clear_thinking:bool option
  -> preserve_thinking:bool option
  -> bool

(** [true] iff the request is under Preserved Thinking: thinking active AND
    [clear_thinking] false. Rows whose
    {!Capabilities.preserve_thinking_control_format} is
    [Thinking_object_clear_thinking] replay prior-turn reasoning exactly then;
    under the wire default [clear_thinking = true] the server discards prior
    reasoning, so replaying it violates the contract and bloats the request. *)
val preserved_thinking_active
  :  enable_thinking:bool option
  -> clear_thinking:bool option
  -> preserve_thinking:bool option
  -> bool

(** Top-level [thinking.clear_thinking] request-field resolver, gated purely on
    the declared preserve wire. Rows with any other preserve wire omit the
    field. No provider identity, endpoint, or model id participates. *)
val clear_thinking_object_request_field
  :  preserve_thinking_control_format:Capabilities.preserve_thinking_control_format
  -> clear_thinking:bool option
  -> preserve_thinking:bool option
  -> bool option

(** Capability catalog provider identity for [config]. Uses the explicitly
    carried [provider_id], otherwise the typed wire kind. Endpoint URLs and
    model-id syntax never participate. *)
val capability_provider_label : t -> string

(** Resolve model capabilities using the explicit provider/model pair. A
    config with [provider_id] only accepts an exact provider-scoped row. Without
    [provider_id], native typed provider kinds may use a provider-independent
    model row; [OpenAI_compat] never does, because its wire kind alone cannot
    select a vendor/model dialect. Generic compatibility callers can provide
    [model_capabilities_override] or an exact [provider_id]. *)
val capabilities_for_config_model : t -> Capabilities.capabilities option

(** Derive a provider-safe schema name for native structured-output APIs
    that require one (for example Openai's [json_schema.name]). *)
val structured_output_name_of_schema : Yojson.Safe.t -> string

(** Validate whether [response_format = JsonSchema _] can be sent natively for
    this config.
    Returns [Ok ()] when no schema was requested or when the provider kind
    is wired for native schema output. Returns [Error reason] for
    unsupported provider/model combinations so callers can fail fast
    before making an HTTP request.

    Conservative policy:
    - [OpenAI_compat] is accepted only when the selected model capability
      record reports [supports_structured_output] and the concrete endpoint is
      declared schema-capable. [None] uses the built-in official
      OpenAI/Ollama Cloud endpoint policy; [Some true] admits verified
      self-hosted/OpenAI-compatible endpoints; [Some false] fail-closes.
    - [Ollama] is accepted only when the selected model capability record
      reports [supports_structured_output]; Ollama-family model rows can differ
      even when the transport accepts a JSON-format field.
    - [Gemini], [Anthropic], and [DashScope] are accepted.
      DashScope (DashScope) exposes [response_format.json_schema] on its
      OpenAI-compatible endpoint; the field is forwarded by
      [backend_openai.ml] without additional host validation.
    - [Kimi] follows the same endpoint declaration path, but the native Kimi
      capability profile currently does not advertise strict schema output.
    - [Glm] is rejected: Z.AI's current official docs document JSON mode
      ([json_object]) only; [response_format.json_schema] is not listed.
    - CLI kinds are rejected.

    @since 0.163.0 *)
val validate_output_schema_request : t -> (unit, string) result

(** True when [request_path] targets the OpenAI Responses API item-based wire
    format rather than Chat Completions. *)
val request_path_targets_responses_api : string -> bool

(** Validate that [request_path] names a wire format implemented by this
    provider kind. OpenAI Responses API paths require [OpenAI_compat] and use a
    Responses-specific sync serializer/parser. *)
val validate_request_path : t -> (unit, string) result

(** Validate provider-specific [tool_choice] constraints before request-body
    construction. This catches unsupported runtime/provider contracts at the
    typed config boundary instead of letting serializers raise exceptions after
    a turn has started. *)
type tool_choice_request_rejection =
  | Unsupported_named_tool_choice of
      { provider_kind : provider_kind
      ; model_id : string
      ; tool_name : string
      }
  | Unsupported_required_tool_choice of
      { provider_kind : provider_kind
      ; model_id : string
      }
  | Unsupported_named_tool_choice_with_thinking of
      { provider_kind : provider_kind
      ; model_id : string
      ; tool_name : string
      }
  | Unsupported_required_tool_choice_with_thinking of
      { provider_kind : provider_kind
      ; model_id : string
      }

val tool_choice_request_rejection_to_message : tool_choice_request_rejection -> string
val validate_tool_choice_request_typed : t -> (unit, tool_choice_request_rejection) result

val validate_tool_choice_request_with_capabilities
  :  provider_kind:provider_kind
  -> model_id:string
  -> tool_choice:Types.tool_choice option
  -> Capabilities.capabilities
  -> (unit, tool_choice_request_rejection) result

val validate_tool_choice_request : t -> (unit, string) result

(** Validate provider/model-specific reasoning effort subsets before request
    serialization. The canonical effort vocabulary lives in
    {!Reasoning_effort}. A categorical effort is valid only when the selected
    model or explicit capability override declares an accepted subset; an
    absent declaration fails closed. *)
type reasoning_effort_request_rejection =
  | Unsupported_reasoning_effort of
      { provider_kind : provider_kind
      ; model_id : string
      ; effort : reasoning_effort
      ; accepted : reasoning_effort list
      }
  | Undeclared_reasoning_effort_capability of
      { provider_kind : provider_kind
      ; model_id : string
      ; effort : reasoning_effort
      }

val reasoning_effort_request_rejection_to_message
  :  reasoning_effort_request_rejection
  -> string

val validate_reasoning_effort_request_typed
  :  t
  -> (unit, reasoning_effort_request_rejection) result

val validate_reasoning_effort_request : t -> (unit, string) result

(** Whether the provider config points at a local loopback endpoint.
    This is the SSOT for locality checks derived from runtime configuration. *)
val is_local : t -> bool

(** Return only the auth-specific headers for a config.
    Callers merge this into [config.headers] at HTTP request time so that
    [Provider_config.t.headers] never carries sensitive tokens like API keys.
    Gemini keys are sent in the [x-goog-api-key] header and are never placed
    in the URL query string. *)
val auth_headers_for_config : t -> (string * string) list

(** Same as {!auth_headers_for_config} but takes the provider kind and raw key
    as separate arguments, so a caller does not need to construct a full
    [Provider_config.t] just to compute auth headers. *)
val auth_headers_for_kind_and_key
  :  kind:provider_kind
  -> api_key:string
  -> (string * string) list
