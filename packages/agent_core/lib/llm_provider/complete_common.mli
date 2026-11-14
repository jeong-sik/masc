(** What [Complete], [Complete_stream], [Complete_sync] and their callers share
    of the completion pipeline: latency counters, request admission checks,
    request serialization and the wire observers.

    Only the names something outside this module uses are listed. The compiler
    reports a helper nothing calls (warning 32), which it cannot for a value
    the module exports. [Complete_stream] and [Complete_sync] include this
    module, so what they re-export is this interface. *)

(** {1 Latency} *)

type latency_counter =
  | Unknown_latency
  | Monotonic_latency of Mtime_clock.counter
  | Eio_clock_latency :
      { clock : [> float Eio.Time.clock_ty ] Eio.Time.clock
      ; started_s : float
      }
      -> latency_counter

val start_latency_counter
  :  ?clock:[> float Eio.Time.clock_ty ] Eio.Time.clock
  -> unit
  -> latency_counter

val latency_ms_float : latency_counter -> float option
val latency_ms_int : latency_counter -> int option

(** {1 Responses} *)

val ensure_nonempty_completion
  :  (Types.api_response, Http_client.http_error) result
  -> (Types.api_response, Http_client.http_error) result

val patch_telemetry
  :  Types.api_response
  -> config:Provider_config.t
  -> ?ttfrc_ms:float option
  -> ?prefill_ms:float option
  -> ?reasoning_prefix:Types.Reasoning_prefix.t option
  -> int option
  -> Types.api_response
(** Request metadata and presentation fallback only. The raw parser's
    [reported_model] observation is preserved; this function cannot turn a
    configured fallback into provider-reported model evidence. *)

val emit_tool_call_metrics
  :  Metrics.t
  -> provider:string
  -> model_id:string
  -> Types.api_response
  -> unit

(** {1 Request admission} *)

val requires_non_http_transport : Provider_config.provider_kind -> bool

type thinking_control_request_rejection =
  | Enable_not_declared
  | Enable_not_encodable
  | Disable_not_encodable
  | Disable_outside_effort_ladder of { accepted : Reasoning_effort.t list option }
  | Request_control_invalid of Reasoning_dialect.request_control_rejection

val thinking_control_request_rejection
  :  ?anthropic_thinking_control:Capabilities.anthropic_thinking_control
  -> caps:Capabilities.capabilities
  -> Provider_config.t
  -> thinking_control_request_rejection option

val thinking_control_request_rejection_reason
  :  ?anthropic_thinking_control:Capabilities.anthropic_thinking_control
  -> Provider_config.t
  -> string option

val validate_all_with_thinking_control
  :  anthropic_thinking_control:Capabilities.anthropic_thinking_control option
  -> Provider_config.t
  -> (unit, Http_client.http_error) result

val request_admission : Provider_config.t -> (unit, string) result
(** The admission every non-exact request meets before dispatch: request path,
    output schema, tool choice, reasoning effort, the thinking control routed by
    provider kind, and the admission declaration. [Error] carries the
    operator-facing reason. Runtime configuration loading asks it of the request
    a binding's own thinking declaration makes, so a binding the turn would
    refuse is refused when its configuration is read. *)

val validate_all : Provider_config.t -> (unit, Http_client.http_error) result
(** [request_admission] with its reason as [Http_client.AcceptRejected]. *)

(** {1 Request serialization} *)

val request_tools_present : config:Provider_config.t -> tools:Yojson.Safe.t list -> bool
(** Whether this codec will actually send tools, after its tool-choice
    suppression. Shared by replay admission and transmitted-history projection. *)

(** [tools] is the same tool list supplied to serialization. The codec applies
    the same tool-choice suppression before resolving request-local replay. *)
val transmitted_history
  :  ?tools:Yojson.Safe.t list
  -> config:Provider_config.t
  -> 'source Types.message_with list
  -> ('source Types.message_with list, Reasoning_history_projection.error) result

val retained_prefix_reasoning_indices
  :  config:Provider_config.t
  -> tools:Yojson.Safe.t list
  -> Types.message list
  -> (int list option, Reasoning_history_projection.error) result

(** A single backend-built generation artifact. The output-token decision is
    extracted from the same opaque backend artifact as [body], never recomputed
    from config. Stream-field injection preserves that decision. This proves
    serialization, not dispatch or provider acceptance. *)
type serialized_http_request = private
  { http_codec : Provider_http_codec.t
  ; body : string
  ; body_sha256 : string
    (** Hex SHA-256 of [body], taken once when the record is built. *)
  ; output_token_receipt : Types.output_token_receipt
  }

(** The request body alone, with no digest and no artifact: for a caller
    that measures a body or wraps it in an artifact of its own and never
    dispatches it. *)
val serialize_http_request_body_with_thinking_control
  :  stream:bool
  -> anthropic_thinking_control:Capabilities.anthropic_thinking_control option
  -> config:Provider_config.t
  -> messages:Types.message list
  -> tools:Yojson.Safe.t list
  -> (string, Http_client.http_error) result

(** {!serialize_http_request_body_with_thinking_control} with the thinking
    control resolved from [config]. *)
val serialize_http_request_body
  :  stream:bool
  -> config:Provider_config.t
  -> messages:Types.message list
  -> tools:Yojson.Safe.t list
  -> (string, Http_client.http_error) result

val serialize_http_request
  :  stream:bool
  -> config:Provider_config.t
  -> messages:Types.message list
  -> tools:Yojson.Safe.t list
  -> (serialized_http_request, Http_client.http_error) result

val serialize_final_http_request_unadmitted
  :  stream:bool
  -> config:Provider_config.t
  -> messages:Types.message list
  -> tools:Yojson.Safe.t list
  -> (serialized_http_request, Http_client.http_error) result

(** The pre-dispatch observation of [serialized]: its byte count and the
    digest the record already carries. Equal to
    {!Request_wire_observer.observation} over the same body. *)
val serialization_observation
  :  capture_id:string option
  -> config:Provider_config.t
  -> stream:bool
  -> serialized_http_request
  -> Request_wire_observer.observation

val config_with_trace_context
  :  Provider_config.t
  -> (string * string) list
  -> Provider_config.t

(** {1 Wire observation and logging} *)

val with_request_metadata : body:String.t -> (unit -> 'a) -> 'a

val observe_pre_dispatch_serialization
  :  ?request_wire_observer:Request_wire_observer.try_observe
  -> Request_wire_observer.observation
  -> unit

val sanitize_url_for_log : string -> string

val http_error_diagnostic_body
  :  provider_name:string
  -> config:Provider_config.t
  -> url:string
  -> code:int
  -> body:string
  -> string

(** A refusal (a non-2xx answer) read by the wire codec that received it, while
    the provider identity is still known. The sync and stream completion seams
    and the Exact_output execution seam all read a refusal through this one
    rule, so the same body gets the same class on every path.

    GLM states its condition in its envelope's documented [code]
    ({!Backend_glm.provider_failure_of_glm_error}): a spent usage window
    answers [429], which the status alone reads as a rate limit, and a window
    refusal answers [400]. A promoted quota keeps the wait the refusal stated
    ([Retry.resolve_retry_after] over its body and [Retry-After] header). A
    code that names no typed failure, a body that did not arrive in the
    caller's window, and every other codec keep the refusal as it came.

    Pass the body as the provider sent it: a redacted copy may no longer parse
    as the envelope. Redact only what is shown or logged. *)
val provider_refusal
  :  http_codec:Provider_http_codec.t
  -> Http_client.http_error
  -> Http_client.http_error
