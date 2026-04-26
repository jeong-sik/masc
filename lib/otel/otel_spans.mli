(** OTel Spans — OpenTelemetry span lifecycle for masc-mcp.

    When [MASC_OTEL_ENABLED=true], creates real OTel spans exported via OTLP.
    When disabled (default), all operations are zero-cost no-ops.

    @since 2.103.0 *)

(** Initialize OTel globals (service name, context propagation).
    Idempotent; safe to call repeatedly. *)
val init : unit -> unit

(** [is_exporter_active ()] reports whether an OTLP exporter backend is registered. *)
val is_exporter_active : unit -> bool

(** Setup OTLP exporter with a custom setup thunk.
    No-op when [enabled=false]. Sets [is_exporter_active] accordingly. *)
val setup_exporter_with
  :  ?enabled:bool
  -> endpoint:string
  -> setup:(unit -> unit)
  -> unit
  -> unit

(** Setup OTLP exporter using the cohttp-eio HTTP/protobuf backend.
    Forks a 500ms tick fiber under [sw] for periodic batch flush.
    No-op when [MASC_OTEL_ENABLED] is not set. *)
val setup_exporter : sw:Eio.Switch.t -> Eio_unix.Stdenv.base -> unit

(** Flush pending spans and remove the OTLP backend.
    Safe to call when disabled (no-op). Resets [is_exporter_active] to [false]. *)
val shutdown : ?enabled:bool -> unit -> unit

(** [with_span ~name ~attrs f] wraps [f] in an OTel span.
    When disabled, calls [f] with a no-op trace-id extractor.
    [f] receives a thunk that returns [Some trace_id_hex] inside a span,
    [None] otherwise. *)
val with_span
  :  name:string
  -> ?attrs:Opentelemetry.key_value list
  -> ((unit -> string option) -> 'a)
  -> 'a

(** [current_trace_id ()] returns the active OTel trace ID as hex, or [None]. *)
val current_trace_id : unit -> string option
