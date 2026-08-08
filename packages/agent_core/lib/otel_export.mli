(** OTLP HTTP/JSON span exporter for {!Otel_tracer}.

    Periodically flushes completed spans to an OTLP-compatible collector
    via HTTP POST. Uses cohttp-eio directly (no dependency on
    {!Llm_provider.Http_client}).

    @stability Evolving
    @since 0.102.0 *)

(** {1 Configuration} *)

type export_config =
  { endpoint : string (** OTLP HTTP endpoint, e.g. ["http://localhost:4318/v1/traces"]. *)
  ; headers : (string * string) list (** Extra headers (auth tokens, etc.). *)
  ; flush_interval_sec : float (** Periodic flush interval. Default: 5.0. *)
  ; max_batch_size : int (** Max spans per export batch. Default: 512. *)
  ; max_retries : int (** Export retry attempts. Default: 3. *)
  ; timeout_sec : float (** Per-request timeout. Default: 10.0. *)
  }

val default_export_config : endpoint:string -> export_config

(** {1 Export result} *)

type export_result =
  | Exported of
      { span_count : int
      ; metric_count : int
      }
  | Partial_failure of
      { exported : int
      ; dropped : int
      ; metric_exported : int
      ; metric_dropped : int
      ; reason : string
      }
  | Failed of { reason : string }

(** {1 One-shot export} *)

(** Flush all completed spans and metrics from [instance] and POST them to the
    configured OTLP endpoint. Does not start a background fiber.

    Spans and metrics are dequeued from the tracer before export. On partial or
    total export failure the affected data is dropped (not re-queued);
    callers should treat [Partial_failure] and [Failed] as permanent
    telemetry loss for those batches. *)
val flush_to_collector
  :  sw:Eio.Switch.t
  -> clock:_ Eio.Time.clock
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> config:export_config
  -> Otel_tracer.instance
  -> export_result

(** {1 Background exporter} *)

type t

(** Start a background daemon fiber that periodically flushes spans.
    The fiber runs inside [sw] and stops when the switch exits.
    [on_export] is called after each export attempt for monitoring. *)
val start_daemon
  :  sw:Eio.Switch.t
  -> clock:_ Eio.Time.clock
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> config:export_config
  -> ?on_export:(export_result -> unit)
  -> Otel_tracer.instance
  -> t

(** Force an immediate flush outside the periodic schedule. *)
val force_flush
  :  sw:Eio.Switch.t
  -> clock:_ Eio.Time.clock
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> t
  -> export_result

(** Total telemetry items exported since start. *)
val total_exported : t -> int

(** {1 Testing helpers — exposed for unit tests} *)

(** Build an OTLP JSON body from a list of spans. *)
val build_otlp_body : service_name:string -> Otel_tracer.span list -> string

(** Build an OTLP JSON body from a list of metrics. *)
val build_otlp_metrics_body
  :  service_name:string
  -> Otel_tracer.metric_entry list
  -> string

(** Split a span list into batches of at most [max_size]. *)
val split_batches
  :  int
  -> Otel_tracer.span list list
  -> Otel_tracer.span list
  -> Otel_tracer.span list list
