(** OpenTelemetry-compatible tracing with OTLP JSON export.

    Provides span lifecycle management, event recording, and
    OTLP JSON serialization. Supports both Stdlib.Mutex (non-Eio)
    and Eio.Mutex backends.

    @stability Evolving
    @since 0.93.1 *)

(** Raised when the operating-system entropy source cannot mint a valid
    OpenTelemetry trace or span identifier. No clock, counter, or PRNG
    fallback is used. *)
exception Entropy_unavailable of string

(** {1 Types} *)

type otel_span_kind =
  | Internal
  | Client
  | Server
  | Producer
  | Consumer

type otel_event =
  { event_name : string
  ; timestamp_ns : Int64.t
  ; attributes : (string * string) list
  }

type otel_link =
  { trace_id : string
  ; span_id : string
  }

type span =
  { trace_id : string
  ; span_id : string
  ; parent_span_id : string option
  ; name : string
  ; kind : otel_span_kind
  ; start_time_ns : Int64.t
  ; end_time_ns : Int64.t option
  ; status : bool option
  ; attributes : (string * string) list
  ; events : otel_event list
  ; mutable links : otel_link list
  }

type config =
  { service_name : string
  ; endpoint : string option
  }

(** {1 Metric types} *)

type metric_type =
  | Counter
  | Gauge
  | Histogram

type metric_entry =
  { m_name : string
  ; m_value : float
  ; m_type : metric_type
  }

type mutex_impl =
  | Stdlib_mu of Mutex.t
  | Eio_mu of Eio.Mutex.t

type instance =
  { config : config
  ; mu : mutex_impl
  ; fiber_key : span list ref Eio.Fiber.key option
  ; mutable current_spans : span list
  ; mutable completed_spans : span list
  ; mutable metrics : metric_entry list
  }

(** {1 Config} *)

(** Default service name used when no config is supplied. *)
val default_service_name : string

(** Environment variable name read by [default_config_from_env] and by the
    constructors below when [config] is omitted. *)
val otel_endpoint_env_var : string

(** Environment-free baseline config. *)
val default_config : config

(** Build the default config using the provided environment lookup at call time. *)
val default_config_from_env : ?getenv:(string -> string option) -> unit -> config

val otel_span_kind_to_int : otel_span_kind -> int

(** {1 Utilities} *)

val now_ns : unit -> Int64.t
val map_span_kind : Tracing.span_kind -> otel_span_kind
val semantic_attrs : Tracing.span_attrs -> (string * string) list
val span_kind_to_string : Tracing.span_kind -> string
val make_span_name : Tracing.span_attrs -> string

(** {1 Instance operations} *)

(** Create a stdlib-mutex backed instance.

    If [config] is omitted, [default_config_from_env ()] is called at creation
    time, which reads [otel_endpoint_env_var] from the environment.
    [getenv] is forwarded to [default_config_from_env] and is useful for tests. *)
val create_instance
  :  ?config:config
  -> ?getenv:(string -> string option)
  -> unit
  -> instance

(** Create an Eio-mutex backed instance.

    If [config] is omitted, [default_config_from_env ()] is called at creation
    time, which reads [otel_endpoint_env_var] from the environment.
    [getenv] is forwarded to [default_config_from_env] and is useful for tests. *)
val create_instance_eio
  :  ?config:config
  -> ?getenv:(string -> string option)
  -> unit
  -> instance

(** Start a span or raise {!Entropy_unavailable}. Callers that require tracing
    to be non-interfering should use [Tracing.with_span] with a tracer returned
    by {!create} or {!create_eio}; those boundaries execute the operation
    untraced and record [otel.id_entropy_failures] when ID creation fails. *)
val inst_start_span : instance -> Tracing.span_attrs -> span

val inst_end_span : instance -> span -> ok:bool -> unit
val inst_add_event : instance -> span -> string -> unit
val inst_add_attrs : instance -> span -> (string * string) list -> unit
val inst_add_link : instance -> span -> trace_id:string -> span_id:string -> unit
val inst_flush : instance -> span list
val inst_reset : instance -> unit
val inst_completed_count : instance -> int
val inst_active_count : instance -> int
val inst_current_span : instance -> span option
val traceparent_of_span : ?sampled:bool -> span -> string

val trace_context_headers_of_span
  :  ?sampled:bool
  -> ?tracestate:string
  -> span
  -> (string * string) list

val inst_trace_context_headers
  :  ?sampled:bool
  -> ?tracestate:string
  -> instance
  -> (string * string) list

(** {1 Instance metric operations} *)

(** Record a metric (counter, gauge, or histogram) on the instance. *)
val inst_record_metric
  :  instance
  -> name:string
  -> value:float
  -> metric_type:metric_type
  -> unit

(** Retrieve all recorded metrics as [(name, value, type)] triples. *)
val inst_get_metrics : instance -> (string * float * metric_type) list

(** Drain and clear all recorded metrics from the instance. *)
val inst_drain_metrics : instance -> metric_entry list

(** Clear all recorded metrics from the instance. *)
val inst_clear_metrics : instance -> unit

(** Convert metric type to its OTLP string representation. *)
val metric_type_to_string : metric_type -> string

(** {1 Global operations} *)

val start_span : Tracing.span_attrs -> span
val end_span : span -> ok:bool -> unit
val add_event : span -> string -> unit
val add_attrs : span -> (string * string) list -> unit
val add_link : span -> trace_id:string -> span_id:string -> unit

(** Run within a span. If the entropy source cannot mint a valid W3C ID, record
    [otel.id_entropy_failures] and run the operation untraced. *)
val with_span : Tracing.span_attrs -> (unit -> 'a) -> 'a

val current_span : unit -> span option
val flush : unit -> span list
val reset : unit -> unit
val completed_count : unit -> int
val active_count : unit -> int

(** {1 Global metric operations} *)

(** Record a metric on the global instance. *)
val record_metric : name:string -> value:float -> metric_type:metric_type -> unit

(** Retrieve all metrics from the global instance. *)
val get_metrics : unit -> (string * float * metric_type) list

(** Clear all metrics from the global instance. *)
val clear_metrics : unit -> unit

(** {1 JSON serialization} *)

val attrs_to_json : (string * string) list -> Yojson.Safe.t
val event_to_json : otel_event -> Yojson.Safe.t
val status_to_json : span -> Yojson.Safe.t
val span_to_json : span -> Yojson.Safe.t
val metric_entry_to_json : metric_entry -> Yojson.Safe.t
val to_otlp_json : config -> Yojson.Safe.t

(** {1 First-class module constructors} *)

val tracer_of_instance : instance -> Tracing.t

(** Build a first-class tracer backed by a stdlib-mutex instance.

    If [config] is omitted, [default_config_from_env ()] is called at creation
    time, which reads [otel_endpoint_env_var] from the environment.
    [getenv] is forwarded to [default_config_from_env] and is useful for tests.
    Its [with_span] operation degrades only the observation span on
    {!Entropy_unavailable}; the wrapped operation still runs. *)
val create : ?config:config -> ?getenv:(string -> string option) -> unit -> Tracing.t

(** Build a first-class tracer backed by an Eio-mutex instance.

    If [config] is omitted, [default_config_from_env ()] is called at creation
    time, which reads [otel_endpoint_env_var] from the environment.
    [getenv] is forwarded to [default_config_from_env] and is useful for tests.
    Its [with_span] operation degrades only the observation span on
    {!Entropy_unavailable}; the wrapped operation still runs. *)
val create_eio : ?config:config -> ?getenv:(string -> string option) -> unit -> Tracing.t
