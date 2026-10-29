(** Anthropic Claude API response parsing and request building.

    Pure functions operating on {!Llm_provider.Types}.

    @stability Internal
    @since 0.93.1 *)
(** [tools_present] is the effective outgoing tools-array presence. Omission
    describes a request without tools; sizing callers must pass the same fact
    as serialization. *)
val project_history
  :  ?tools_present:bool
  -> Provider_config.t
  -> 'source Types.message_with list
  -> ('source Reasoning_history_projection.projection, Reasoning_history_projection.error) result
(** The history this codec will actually serialize, before prefix-binding
    verification: reasoning blocks it cannot carry, and blocks the config's
    replay policy excludes, are already gone, and on the Anthropic kind the
    fold can only remove further reasoning, so sizing from this answer
    stays conservative.

    Exported so a caller that must size a request before building it asks the
    same function the wire does, rather than keeping a second opinion about
    which blocks survive. Pure — the diagnostic [observe] belongs to whoever
    dispatches. *)

val retained_prefix_reasoning_indices
  :  config:Provider_config.t
  -> tools:Yojson.Safe.t list
  -> Types.message list
  -> (int list option, Reasoning_history_projection.error) result
(** Pure observation of the exact project/merge/prefix-verification path used
    by the serializer. [Some indices] identifies retained reasoning by its
    original input message occurrence, before either projection or merging.
    [None] means this provider kind does not bind reasoning to a request prefix.
    This neither observes diagnostics nor changes stored provenance. *)


val parse_response : Yojson.Safe.t -> Types.api_response

val drop_block_env_var : string
(** Name of the environment switch that withholds
    [thinking.block_binding.prefix_mismatch_behavior = "drop_block"] when set
    to a false value. Unset keeps the default (send it). Measurement only. *)

val request_headers : body:string -> (string * string) list -> (string * string) list
(** Add the binding-controls beta only when this exact serialized request
    contains [thinking.block_binding]. Add the turn-scoped-context beta when
    messages carry [clear_at]. Preserve other caller beta values. *)

val observe_input_transformations : Yojson.Safe.t -> unit
(** Record provider-reported thinking transformations without recording block
    contents or signatures. Accepts a response or an SSE message_start body. *)

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

(** Which thinking wire a request is built for. Two providers share this codec
    and do not share a thinking contract: Anthropic carries the adaptive policy
    its catalog entry declares, and Kimi carries an on/off flag because
    [Capabilities.kimi_capabilities] declares [No_thinking_control]. Naming them
    apart is what stops a change to one from rewriting the other's wire.
    [Anthropic_no_policy] is the Anthropic wire for a model no catalog or
    manifest row declares a policy for: it serializes no [thinking] block and
    rejects an explicit [enable_thinking], instead of standing in for
    [Anthropic_adaptive_default]. *)
type thinking_wire =
  | Anthropic_control of Capabilities.anthropic_thinking_control
  | Anthropic_no_policy
  | Kimi_flag

(** The thinking request field for a model family, on the wire that family
    actually accepts. *)
val thinking_config_for_config
  :  thinking_wire
  -> Provider_config.t
  -> Yojson.Safe.t option

(** Validate that a categorical effort targets the selected thinking wire
    exactly. *)
val validate_thinking_controls
  :  thinking_wire
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

(** Creation-prefix identity for a response produced by this wire: the digest
    chain over the API-checked head members plus every projected, merged
    message, and over the response content. Returns [None] for kinds
    this backend serves without a binding (Kimi), for responses without
    reasoning, and when the history refuses projection. Every [None] fails
    closed at replay instead of recording a digest the wire cannot honor.
    Pure: it replays the same projection, merge, and fold {!build_request}
    runs on the same messages and tools, so the value matches the bytes the
    provider verified, for a request whose body was admitted before dispatch
    as for one serialized at dispatch. *)
val transmitted_reasoning_prefix
  :  config:Provider_config.t
  -> messages:Types.message list
  -> tools:Yojson.Safe.t list
  -> response_content:Types.content_block list
  -> unit
  -> Types.Reasoning_prefix.t option

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
