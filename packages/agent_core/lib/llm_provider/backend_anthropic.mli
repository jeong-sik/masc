(** Anthropic Claude API response parsing and request building.

    Pure functions operating on {!Llm_provider.Types}.

    @stability Internal
    @since 0.93.1 *)

val parse_response : Yojson.Safe.t -> Types.api_response

type request_artifact

val request_payload : request_artifact -> string
val request_output_token_receipt : request_artifact -> Types.output_token_receipt

(** Provider-correct Claude thinking request field for a model family.
    Exposed so the legacy Agent SDK Anthropic builder can share the same
    manual-budget vs adaptive-thinking dispatch as this backend. *)
val thinking_config_for_config
  :  Capabilities.anthropic_thinking_control
  -> Provider_config.t
  -> Yojson.Safe.t option

(** Validate that categorical effort and numeric budget target the selected
    Anthropic thinking wire exactly. *)
val validate_thinking_controls
  :  Capabilities.anthropic_thinking_control
  -> Provider_config.t
  -> (unit, string) result

(** Validate the legacy/non-exact request against the current catalog or
    manifest policy. The resolver remains private to this backend; exact output
    uses the separately supplied frozen policy instead. *)
val validate_nonexact_thinking_controls : Provider_config.t -> (unit, string) result

(** Optional Claude [output_config], including adaptive [effort] and native
    JSON-schema format when requested. *)
val output_config_for_config
  :  Capabilities.anthropic_thinking_control
  -> Provider_config.t
  -> Yojson.Safe.t option

(** Optional-envelope resolver re-exported from
    {!Backend_openai_request.effective_max_output_tokens}: caller override
    clamped to the model capability (one-shot WARN), [None] on caller
    [None] — the ceiling is never injected as a request value. *)
val effective_max_output_tokens : Provider_config.t -> int option

(** Resolve the Messages required [max_tokens] decision. Caller [None] falls
    back to a model-catalog ceiling or an explicit capability-override ceiling,
    preserving the source in the resulting receipt. *)
val required_output_token_receipt
  :  Provider_config.t
  -> (Types.output_token_receipt, Types.required_output_token_error) result

(** Render a typed required-output-token rejection with the selected model
    context. Internal completion boundaries use this to preserve the
    [AcceptRejected] result contract instead of crossing the compatibility
    [Invalid_argument] projection below. *)
val required_output_token_error_message
  :  Provider_config.t
  -> Types.required_output_token_error
  -> string

(** Compatibility projection of {!required_output_token_receipt}. Raises
    [Invalid_argument] naming the model when no explicit value, catalog
    ceiling, or capability-override ceiling exists. *)
val required_max_output_tokens : Provider_config.t -> int

(** Build one immutable Messages request artifact. Missing required
    [max_tokens] metadata is returned as a typed error before any HTTP payload
    can be observed. Other pre-existing request validation failures retain
    their explicit [Invalid_argument] contract. *)
val build_request_artifact
  :  ?stream:bool
  -> config:Provider_config.t
  -> messages:Types.message list
  -> ?tools:Yojson.Safe.t list
  -> unit
  -> (request_artifact, Types.required_output_token_error) result

(** Exact/private request boundary. Unlike {!build_request_artifact}, this
    never resolves process-global catalog or manifest state: the caller must
    provide the thinking policy frozen into its immutable target snapshot,
    including an explicit [None]. *)
val build_request_artifact_with_thinking_control
  :  ?stream:bool
  -> anthropic_thinking_control:Capabilities.anthropic_thinking_control option
  -> config:Provider_config.t
  -> messages:Types.message list
  -> ?tools:Yojson.Safe.t list
  -> unit
  -> (request_artifact, Types.required_output_token_error) result

val build_request
  :  ?stream:bool
  -> config:Provider_config.t
  -> messages:Types.message list
  -> ?tools:Yojson.Safe.t list
  -> unit
  -> string

(** Build an Anthropic-compatible Messages count-tokens request from the same
    provider-specific canonical input projection as {!build_request}.
    Anthropic and Kimi are supported; completion-only output and sampling
    fields are omitted. *)
val build_count_tokens_request
  :  config:Provider_config.t
  -> messages:Types.message list
  -> ?tools:Yojson.Safe.t list
  -> unit
  -> string
