(** Anthropic Claude API response parsing and request building.

    Pure functions operating on {!Llm_provider.Types}.

    @stability Internal
    @since 0.93.1 *)
val project_history
  :  Provider_config.t
  -> Types.message list
  -> (Reasoning_history_projection.t, Reasoning_history_projection.error) result
(** The history this codec will actually serialize: reasoning blocks it cannot
    carry, and blocks the config's replay policy excludes, are already gone.

    Exported so a caller that must size a request before building it asks the
    same function the wire does, rather than keeping a second opinion about
    which blocks survive. Pure — the diagnostic [observe] belongs to whoever
    dispatches. *)


val parse_response : Yojson.Safe.t -> Types.api_response

(** Build the canonical {!Types.api_usage} from Anthropic Messages wire
    counts. The wire's [input_tokens] is exclusive — it counts only tokens
    after the last cache breakpoint (official contract: total input =
    cache_read + cache_creation + input_tokens) — while
    {!Types.api_usage.input_tokens} is the inclusive prompt total, so this
    constructor adds the cache components in. Every parse of this wire shape
    (sync response, SSE [message_start]) must build through it; bypassing it
    reintroduces the exclusive/inclusive mix that under-prices regular input
    and under-reports context occupancy. *)
val usage_of_wire_counts
  :  input_tokens:int
  -> output_tokens:int
  -> cache_creation_input_tokens:int
  -> cache_read_input_tokens:int
  -> Types.api_usage

type request_artifact

val request_payload : request_artifact -> string
val request_output_token_receipt : request_artifact -> Types.output_token_receipt

(** Provider-correct Claude thinking request field for a model family.
    Shared by the Anthropic request builders so manual-budget and adaptive
    thinking use the same dispatch. *)
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
