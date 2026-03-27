(** OTel Spans — OpenTelemetry span lifecycle for masc-mcp.

    When [MASC_OTEL_ENABLED=true], creates real OTel spans exported via OTLP.
    When disabled (default), all operations are zero-cost no-ops.

    @since 2.103.0 *)

module OT = Opentelemetry

let initialized = ref false

let init () =
  if Otel_config.enabled && not !initialized then begin
    initialized := true;
    OT.Globals.service_name := Otel_config.service_name;
    (* ambient-context-eio storage is set automatically when the library is linked.
       Eio fiber-local context propagation works via Ambient_context_eio.storage. *)
    ignore (Ambient_context_eio.storage : Ambient_context.Storage.t)
  end

let setup_exporter env =
  if Otel_config.enabled && !initialized then begin
    let config =
      Opentelemetry_client_cohttp_eio.Config.make
        ~url:Otel_config.endpoint
        ()
    in
    Opentelemetry_client_cohttp_eio.setup ~config env
  end

let shutdown () =
  if Otel_config.enabled && !initialized then
    Opentelemetry_client_cohttp_eio.remove_exporter ()

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
