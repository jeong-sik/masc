(** OTel Spans — OpenTelemetry span lifecycle for masc.

    When [MASC_OTEL_ENABLED=true] (default), creates real OTel spans exported via OTLP.
    When explicitly disabled, all operations are zero-cost no-ops.

    @since 2.103.0 *)

module OT = Opentelemetry

let initialized = Atomic.make false
let exporter_active = Atomic.make false
let enabled_override : bool option ref = ref None

let _last_successful_export = Atomic.make None
let _consecutive_failures = Atomic.make 0

let event_emitter_override
      : (name:string -> attrs:OT.key_value list -> unit) option ref
  =
  ref None
;;

let enabled () =
  match !enabled_override with
  | Some value -> value
  | None -> Otel_config.enabled
;;

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
    No-op when OTel is explicitly disabled. *)
let is_exporter_active () = Atomic.get exporter_active
let last_successful_export () = Atomic.get _last_successful_export
let consecutive_failures () = Atomic.get _consecutive_failures

let setup_exporter_with ?(enabled = Otel_config.enabled) ~endpoint ~setup () =
  if enabled then begin
    init ();
    try
      setup ();
      Atomic.set exporter_active true;
      Atomic.set _last_successful_export (Some (Unix.gettimeofday ()));
      Atomic.set _consecutive_failures 0;
      Log.Otel.info "OTLP exporter started -> %s" endpoint
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
        Atomic.set exporter_active false;
        Log.Otel.warn "OTLP exporter unavailable, continuing without export (%s): %s"
          endpoint (Printexc.to_string exn)
  end

(** Probe OTLP collector endpoint via TCP connect with DNS resolution.
    Lightweight: resolves host, opens connection, and immediately closes.
    Returns [true] if the collector is reachable. *)
let probe_endpoint ~(env : Eio_unix.Stdenv.base) endpoint =
  try
    let uri = Uri.of_string endpoint in
    let host = Option.value (Uri.host uri) ~default:"localhost" in
    let port = Option.value (Uri.port uri) ~default:4318 in
    let net = env#net in
    let addrs = Eio.Net.getaddrinfo_stream net host ~service:(string_of_int port) in
    match addrs with
    | [] -> false
    | addr :: _ ->
      Eio.Switch.run (fun sw ->
        let conn = Eio.Net.connect ~sw net addr in
        Eio.Flow.close conn);
      true
  with
  | _ -> false

let setup_exporter ~sw (env : Eio_unix.Stdenv.base) =
  let endpoint = Otel_config.endpoint in
  let clock = Eio.Stdenv.clock env in
  let rec try_setup attempt =
    if not (enabled ()) then ()
    else begin
      init ();
      let setup () =
        let config =
          Opentelemetry_client_cohttp_eio.Config.make ~url:endpoint ()
        in
        Opentelemetry_client_cohttp_eio.setup ~sw ~config env
      in
      if not (probe_endpoint ~env endpoint) then
        if attempt < 5 then begin
          let delay = Float.of_int (1 lsl attempt) in
          Log.Otel.warn "OTLP collector unreachable (%s), retry %d/5 in %.1fs"
            endpoint (attempt + 1) delay;
          Eio.Time.sleep clock delay;
          try_setup (attempt + 1)
        end else begin
          Log.Otel.warn "OTLP collector unreachable after 5 retries (%s), continuing without export"
            endpoint;
          Atomic.set exporter_active false
        end
      else
        try
          setup ();
          Atomic.set exporter_active true;
          Atomic.set _last_successful_export (Some (Unix.gettimeofday ()));
          Atomic.set _consecutive_failures 0;
          Log.Otel.info "OTLP exporter started -> %s" endpoint;
          (* Health check fiber: probe collector every 30s *)
          let rec health_loop () =
            Eio.Time.sleep clock 30.0;
            if probe_endpoint ~env endpoint then begin
              Atomic.set _consecutive_failures 0;
              health_loop ()
            end else begin
              let failures = Atomic.get _consecutive_failures + 1 in
              Atomic.set _consecutive_failures failures;
              Log.Otel.warn "OTLP health check failed (%d consecutive) -> %s"
                failures endpoint;
              if Atomic.get exporter_active && failures >= 3 then begin
                Log.Otel.error "OTLP exporter marked inactive after %d consecutive failures -> %s"
                  failures endpoint;
                Atomic.set exporter_active false
              end;
              health_loop ()
            end
          in
          Eio.Fiber.fork ~sw health_loop
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn when attempt < 5 ->
          let delay = Float.of_int (1 lsl attempt) in
          Log.Otel.warn "OTLP exporter attempt %d/6 failed, retry in %.1fs: %s"
            (attempt + 1) delay (Printexc.to_string exn);
          Eio.Time.sleep clock delay;
          try_setup (attempt + 1)
        | exn ->
          Atomic.set exporter_active false;
          Log.Otel.warn "OTLP exporter unavailable after 6 attempts (%s): %s"
            endpoint (Printexc.to_string exn)
    end
  in
  try_setup 0

(** Flush pending spans and remove the OTLP backend.
    Safe to call when disabled (no-op). *)
let shutdown ?(enabled = Otel_config.enabled) () =
  if enabled && Atomic.get exporter_active then begin
    Opentelemetry_client_cohttp_eio.remove_backend ();
    Log.Otel.info "OTLP exporter stopped"
  end;
  Atomic.set exporter_active false;
  Atomic.set initialized false;
  Atomic.set _last_successful_export None;
  Atomic.set _consecutive_failures 0

(** Wrap a function in an OTel span. No-op when disabled.
    Returns the result of [f]. *)
let with_span ~name ?(attrs = []) f =
  if not Otel_config.enabled then f (fun () -> None)
  else
    OT.Trace.with_ name ~attrs (fun scope ->
      f (fun () ->
        let ctx = OT.Scope.to_span_ctx scope in
        Some (OT.Trace_id.to_hex (OT.Span_ctx.trace_id ctx))))

(** Add an event to the active OTel span. No-op when disabled or when no
    ambient span exists. *)
let add_event ~name ?(attrs = []) () =
  if enabled ()
  then
    match !event_emitter_override with
    | Some emit -> emit ~name ~attrs
    | None ->
      (match OT.Scope.get_ambient_scope () with
       | Some scope ->
         OT.Scope.add_event scope (fun () -> OT.Event.make ~attrs name)
       | None -> ())
;;

let with_test_event_emitter ~enabled:enabled_value ~emit_event f =
  let prev_enabled = !enabled_override in
  let prev_emitter = !event_emitter_override in
  enabled_override := Some enabled_value;
  event_emitter_override := Some emit_event;
  Eio_guard.protect
    ~finally:(fun () ->
      enabled_override := prev_enabled;
      event_emitter_override := prev_emitter)
    f
;;

(** Get the current OTel trace ID as a hex string, or None if disabled / no active span. *)
let current_trace_id () =
  if not Otel_config.enabled then None
  else
    match OT.Scope.get_ambient_scope () with
    | Some scope ->
      let ctx = OT.Scope.to_span_ctx scope in
      Some (OT.Trace_id.to_hex (OT.Span_ctx.trace_id ctx))
    | None -> None
