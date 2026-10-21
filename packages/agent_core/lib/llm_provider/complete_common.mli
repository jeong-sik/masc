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

val validate_all : Provider_config.t -> (unit, Http_client.http_error) result

(** {1 Request serialization} *)

val transmitted_history
  :  config:Provider_config.t
  -> Types.message list
  -> (Types.message list, Reasoning_history_projection.error) result

val retained_prefix_reasoning_indices
  :  config:Provider_config.t
  -> tools:Yojson.Safe.t list
  -> Types.message list
  -> (int list option, Reasoning_history_projection.error) result

val serialize_http_request_with_thinking_control
  :  stream:bool
  -> anthropic_thinking_control:Capabilities.anthropic_thinking_control option
  -> config:Provider_config.t
  -> messages:Types.message list
  -> tools:Yojson.Safe.t list
  -> (Provider_http_codec.t * string, Http_client.http_error) result

val serialize_http_request
  :  stream:bool
  -> config:Provider_config.t
  -> messages:Types.message list
  -> tools:Yojson.Safe.t list
  -> (Provider_http_codec.t * string, Http_client.http_error) result

val serialize_final_http_request_unadmitted
  :  stream:bool
  -> config:Provider_config.t
  -> messages:Types.message list
  -> tools:Yojson.Safe.t list
  -> (Provider_http_codec.t * string, Http_client.http_error) result

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

val observe_request_wire
  :  ?request_wire_observer:Request_wire_observer.try_observe
  -> capture_id:string option
  -> config:Provider_config.t
  -> http_codec:Provider_http_codec.t
  -> stream:bool
  -> body:string
  -> unit
  -> unit

val sanitize_url_for_log : string -> string

val http_error_diagnostic_body
  :  provider_name:string
  -> config:Provider_config.t
  -> url:string
  -> code:int
  -> body:string
  -> string
