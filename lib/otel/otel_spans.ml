(** OTel Spans — OpenTelemetry span lifecycle for masc-mcp.

    When [MASC_OTEL_ENABLED=true], creates real OTel spans exported via OTLP.
    When disabled (default), all operations are zero-cost no-ops.

    @since 2.103.0 *)

module OT = Opentelemetry

let initialized = Atomic.make false
let exporter_active = Atomic.make false

let init () =
  if Otel_config.enabled && not (Atomic.get initialized) then begin
    Atomic.set initialized true;
    OT.Globals.service_name := Otel_config.service_name;
    (* ambient-context-eio storage is set automatically when the library is linked.
       Eio fiber-local context propagation works via Ambient_context_eio.storage. *)
    ignore (Ambient_context_eio.storage : Ambient_context.Storage.t)
  end

(** Setup OTLP exporter — registers the cohttp-eio backend that ships spans,
    metrics, and logs to the configured OTLP collector via HTTP/protobuf.
    Internally forks a 500ms tick fiber under [sw] for periodic batch flush.
    No-op when [MASC_OTEL_ENABLED] is not set. *)
let is_exporter_active () = Atomic.get exporter_active

let setup_exporter_with ?(enabled = Otel_config.enabled) ~endpoint ~setup () =
  if enabled then begin
    init ();
    try
      setup ();
      Atomic.set exporter_active true;
      Log.info ~ctx:"otel" "OTLP exporter started -> %s" endpoint
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
        Atomic.set exporter_active false;
        Log.warn ~ctx:"otel"
          "OTLP exporter unavailable, continuing without export (%s): %s"
          endpoint (Printexc.to_string exn)
  end

let setup_exporter ~sw (env : Eio_unix.Stdenv.base) =
  let endpoint = Otel_config.endpoint in
  let setup () =
    let config =
      Opentelemetry_client_cohttp_eio.Config.make ~url:endpoint ()
    in
    Opentelemetry_client_cohttp_eio.setup ~sw ~config env
  in
  setup_exporter_with ~endpoint ~setup ()

(** Flush pending spans and remove the OTLP backend.
    Safe to call when disabled (no-op). *)
let shutdown ?(enabled = Otel_config.enabled) () =
  if enabled && Atomic.get exporter_active then begin
    Opentelemetry_client_cohttp_eio.remove_backend ();
    Log.info ~ctx:"otel" "OTLP exporter stopped"
  end;
  Atomic.set exporter_active false;
  Atomic.set initialized false

(** Wrap a function in an OTel span. No-op when disabled.
    Returns the result of [f]. *)
let with_span ~name ?(attrs = []) f =
  if not Otel_config.enabled then f (fun () -> None)
  else
    OT.Trace.with_ name ~attrs (fun scope ->
      f (fun () ->
        let ctx = OT.Scope.to_span_ctx scope in
        Some (OT.Trace_id.to_hex (OT.Span_ctx.trace_id ctx))))

(** Get the current OTel trace ID as a hex string, or None if disabled / no active span. *)
let current_trace_id () =
  if not Otel_config.enabled then None
  else
    match OT.Scope.get_ambient_scope () with
    | Some scope ->
      let ctx = OT.Scope.to_span_ctx scope in
      Some (OT.Trace_id.to_hex (OT.Span_ctx.trace_id ctx))
    | None -> None
