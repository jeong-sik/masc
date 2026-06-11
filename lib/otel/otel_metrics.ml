(** OTel Metrics — OpenTelemetry metrics adapter for masc-mcp.

    Provides the same API surface as [Prometheus.*] but backed by OTel's
    [Opentelemetry.Metrics] protocol.  During the migration window this module
    dual-writes to both OTel and the in-memory Prometheus store so the
    /metrics text endpoint continues to work.

    When [MASC_OTEL_ENABLED=true] and the exporter is active, metrics are
    accumulated and flushed via OTLP.  When disabled (default), the module
    silently drops OTel-side writes and only populates the Prometheus store.

    @since 2.150.0
*)

module OT = Opentelemetry

(* ------------------------------------------------------------------ *)
(*  Prometheus sink — keep alive until facade removal                  *)
(* ------------------------------------------------------------------ *)

module Prometheus_sink = struct
  let inc_counter = Prometheus_store.inc_counter
  let set_gauge   = Prometheus_store.set_gauge
  let inc_gauge   = Prometheus_store.inc_gauge
  let dec_gauge   = Prometheus_store.dec_gauge
  let observe_histogram = Prometheus_store.observe_histogram
  let register_counter   = Prometheus_store.register_counter
  let register_gauge     = Prometheus_store.register_gauge
  let register_histogram = Prometheus_store.register_histogram
end

(* ------------------------------------------------------------------ *)
(*  OTel side — accumulated and batch-exported                         *)
(* ------------------------------------------------------------------ *)

module OTel_sink = struct
  (* Lock-free append-only accumulator.  Each [inc_counter], [set_gauge],
     [observe_histogram] appends a record; the exporter drains on each
     flush cycle. *)
  type record =
    | R_counter of { name : string; labels : (string * string) list; value : float }
    | R_gauge   of { name : string; labels : (string * string) list; value : float }
    | R_histogram of { name : string; labels : (string * string) list; value : float }

  let enabled () = Otel_config.enabled

  let records : record list ref = ref []
  let records_mutex = Stdlib.Mutex.create ()

  let push r =
    if enabled () then begin
      Stdlib.Mutex.lock records_mutex;
      records := r :: !records;
      Stdlib.Mutex.unlock records_mutex
    end

  let drain () =
    Stdlib.Mutex.lock records_mutex;
    let batch = List.rev !records in
    records := [];
    Stdlib.Mutex.unlock records_mutex;
    batch

  let flush_batch () =
    let batch = drain () in
    if batch <> [] && enabled () then begin
      (* Build a single ResourceMetrics from accumulated records.
         The OTel proto expects [resource_metrics] containing
         [scope_metrics] containing [metric] entries. *)
      let metrics =
        List.map (fun (r : record) ->
            match r with
            | R_counter x ->
              OT.Proto.Metrics.make_counter
                ~name:x.name
                ~data:(OT.Proto.Metrics.Counter.make ~value:x.value ())
                ()
            | R_gauge x ->
              OT.Proto.Metrics.make_gauge
                ~name:x.name
                ~data:(OT.Proto.Metrics.Gauge.make ~value:x.value ())
                ()
            | R_histogram x ->
              OT.Proto.Metrics.make_histogram
                ~name:x.name
                ~data:(OT.Proto.Metrics.Histogram.make
                         ~sum:x.value
                         ~count:1L
                         ~explicit_bounds:[]
                         ~bucket_counts:[]
                         ())
                ())
          batch
      in
      let scope_metrics =
        OT.Proto.Metrics.ScopeMetrics.make ~metrics ()
      in
      let resource_metrics =
        OT.Metrics.make_resource_metrics ~scope_metrics ()
      in
      Opentelemetry_client_cohttp_eio.GC_metrics.add resource_metrics
    end
end

(* ------------------------------------------------------------------ *)
(*  Public API — identical shape to [Prometheus.*]                     *)
(* ------------------------------------------------------------------ *)

let enabled () = OTel_sink.enabled ()

let register_counter ~name ~help ?(labels = []) () =
  Prometheus_sink.register_counter ~name ~help ~labels ()

let register_gauge ~name ~help ?(labels = []) () =
  Prometheus_sink.register_gauge ~name ~help ~labels ()

let register_histogram ~name ~help ?(labels = []) () =
  Prometheus_sink.register_histogram ~name ~help ~labels ()

let inc_counter name ?(labels = []) ?(delta = 1.0) () =
  Prometheus_sink.inc_counter name ~labels ~delta ();
  OTel_sink.push (R_counter { name; labels; value = delta })

let set_gauge name ?(labels = []) value =
  Prometheus_sink.set_gauge name ~labels value;
  OTel_sink.push (R_gauge { name; labels; value })

let inc_gauge name ?(labels = []) ?(delta = 1.0) () =
  Prometheus_sink.inc_gauge name ~labels ~delta ();
  OTel_sink.push (R_gauge { name; labels; value = delta })

let dec_gauge name ?(labels = []) ?(delta = 1.0) () =
  Prometheus_sink.dec_gauge name ~labels ~delta ();
  OTel_sink.push (R_gauge { name; labels; value = ~-.delta })

let observe_histogram name ?(labels = []) value =
  Prometheus_sink.observe_histogram name ~labels value;
  OTel_sink.push (R_histogram { name; labels; value })

(* ------------------------------------------------------------------ *)
(*  Periodic flush — called from the exporter loop                     *)
(* ------------------------------------------------------------------ *)

let flush () = OTel_sink.flush_batch ()

(* ------------------------------------------------------------------ *)
(*  /metrics text — delegates to Prometheus until facade removal       *)
(* ------------------------------------------------------------------ *)

let to_prometheus_text () =
  Prometheus_store.to_prometheus_text ()