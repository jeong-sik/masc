(** OTel Spans — OpenTelemetry span lifecycle for masc.

    When [MASC_OTEL_ENABLED=true] (default), creates real OTel spans exported via OTLP.
    When explicitly disabled, all operations are zero-cost no-ops.

    @since 2.103.0 *)

(** Initialize OTel globals (service name, context propagation).
    Idempotent; safe to call repeatedly. *)
val init : unit -> unit

(** [is_exporter_active ()] reports whether an OTLP exporter backend is registered. *)
val is_exporter_active : unit -> bool

(** [is_exporter_degraded ()] reports whether the exporter backend exists but
    its tick fiber stopped after an unrecoverable internal error. *)
val is_exporter_degraded : unit -> bool

(** [last_degradation_error ()] returns the last exporter degradation cause. *)
val last_degradation_error : unit -> string option

(** [last_successful_export ()] returns the Unix timestamp of the last
    successful export, or [None] if the exporter has never been active. *)
val last_successful_export : unit -> float option

(** [consecutive_failures ()] returns the number of consecutive health check
    or export failures since the last successful connection. *)
val consecutive_failures : unit -> int

(** Setup OTLP exporter with a custom setup thunk.
    No-op when [enabled=false]. Sets [is_exporter_active] accordingly. *)
val setup_exporter_with :
  ?enabled:bool -> endpoint:string -> setup:(unit -> unit) -> unit -> unit

(** Setup OTLP exporter using the cohttp-eio HTTP/protobuf backend.
    Forks a 500ms tick fiber under [sw] for periodic batch flush.
    No-op when OTel is explicitly disabled. *)
val setup_exporter : sw:Eio.Switch.t -> Eio_unix.Stdenv.base -> unit

(** Flush pending spans and remove the OTLP backend.
    Safe to call when disabled (no-op). Resets [is_exporter_active] to [false]. *)
val shutdown : ?enabled:bool -> unit -> unit

(** [with_span ~name ~attrs f] wraps [f] in an OTel span.
    When disabled, calls [f] with a no-op trace-id extractor.
    [f] receives a thunk that returns [Some trace_id_hex] inside a span,
    [None] otherwise.

    [force_new_trace_id] starts a fresh trace root instead of nesting under
    the ambient parent. Use at operation boundaries to keep traces small. *)
val with_span :
  name:string ->
  ?attrs:Opentelemetry.key_value list ->
  ?force_new_trace_id:bool ->
  ((unit -> (string * string) option) -> 'a) ->
  'a

(** [add_event ~name ~attrs ()] appends an event to the active OTel span.
    No-op when OTel is disabled or when no ambient span exists. *)
val add_event :
  name:string -> ?attrs:Opentelemetry.key_value list -> unit -> unit

(** [add_attrs ~attrs ()] appends attributes to the active OTel span.
    No-op when OTel is disabled or when no ambient span exists. *)
val add_attrs : ?attrs:Opentelemetry.key_value list -> unit -> unit

(** [set_status status] sets the active span status.
    No-op when OTel is disabled or when no ambient span exists. *)
val set_status : Opentelemetry.Span_status.t -> unit

(** [record_error ~message ~error_type] marks the active span as errored and
    emits the GenAI exception event. *)
val record_error :
  ?attrs:Opentelemetry.key_value list ->
  message:string ->
  error_type:string ->
  unit ->
  unit

(** Temporarily override event emission for focused tests. *)
val with_test_event_emitter :
  enabled:bool ->
  emit_event:(name:string -> attrs:Opentelemetry.key_value list -> unit) ->
  ?emit_attrs:(attrs:Opentelemetry.key_value list -> unit) ->
  ?set_status:(Opentelemetry.Span_status.t -> unit) ->
  (unit -> 'a) ->
  'a

(** [current_trace_id ()] returns the active OTel trace ID as hex, or [None]. *)
val current_trace_id : unit -> string option
