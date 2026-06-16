(** OTel Spans — OpenTelemetry span lifecycle for masc.

    When [MASC_OTEL_ENABLED=true] (default), creates real OTel spans exported via OTLP.
    When explicitly disabled, all operations are zero-cost no-ops.

    @since 2.103.0 *)

module OT = Opentelemetry

let initialized = Atomic.make false
let exporter_active = Atomic.make false
let enabled_override : bool option Atomic.t = Atomic.make None

let _last_successful_export = Atomic.make None
let _consecutive_failures = Atomic.make 0

let event_emitter_override
      : (name:string -> attrs:OT.key_value list -> unit) option Atomic.t
  =
  Atomic.make None
;;

let attrs_emitter_override : (attrs:OT.key_value list -> unit) option Atomic.t =
  Atomic.make None
;;

let status_emitter_override : (OT.Span_status.t -> unit) option Atomic.t = Atomic.make None

let enabled () =
  match Atomic.get enabled_override with
  | Some value -> value
  | None -> Otel_config.enabled
;;

let init () =
  if Otel_config.enabled && not (Atomic.get initialized) then begin
    Atomic.set initialized true;
    OT.Globals.service_name := Otel_config.service_name;
    (* Disable the opentelemetry library's internal self-instrumentation
       ("encode-proto" spans emitted by Self_trace.with_ in client/signal.ml).
       When the exporter encodes a batch while running on a keeper fiber, the
       self-span nests into that fiber's active ambient scope and attaches to
       the live invoke_agent (keeper-turn) trace. Measured on a post-deploy
       production trace (commit c36e0d1, masc service): 2260 of 2283 spans
       (99%) were encode-proto noise. These carry no application signal. *)
    Opentelemetry_client.Self_trace.set_enabled false;
    (* ambient-context-eio storage is set automatically when the library is linked.
       Eio fiber-local context propagation works via Ambient_context_eio.storage. *)
    ignore (Ambient_context_eio.storage : Ambient_context.Storage.t)
  end

(** Setup OTLP exporter — registers the cohttp-eio backend that ships spans,
    metrics, and logs to the configured OTLP collector via HTTP/protobuf.
    Internally forks a 500ms tick fiber under [sw] for periodic batch flush.
    No-op when OTel is explicitly disabled. *)
let is_exporter_degraded () = Opentelemetry_client_cohttp_eio.tick_degraded ()
let last_degradation_error () = Opentelemetry_client_cohttp_eio.last_tick_poisoned_error ()

let is_exporter_active () =
  Atomic.get exporter_active && not (is_exporter_degraded ())
;;

let last_successful_export () = Atomic.get _last_successful_export
let consecutive_failures () = Atomic.get _consecutive_failures

let setup_exporter_with ?(enabled = Otel_config.enabled) ~endpoint ~setup () =
  if enabled then begin
    Opentelemetry_client_cohttp_eio.reset_tick_health ();
    try
      init ();
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

(** [port_of_uri uri] returns the explicit port of [uri], falling back to the
    configured OTLP default ([Masc_network_defaults.otel_default_port]) when the
    URI omits one. Keeps the OTLP port in a single source of truth. *)
let port_of_uri uri =
  Option.value (Uri.port uri) ~default:Masc_network_defaults.otel_default_port

(** Probe OTLP collector endpoint via TCP connect with DNS resolution.
    Lightweight: resolves host, opens connection, and immediately closes.
    Returns [true] if the collector is reachable. *)
let probe_endpoint ~(env : Eio_unix.Stdenv.base) endpoint =
  try
    let uri = Uri.of_string endpoint in
    let host = Option.value (Uri.host uri) ~default:"localhost" in
    let port = port_of_uri uri in
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
  Opentelemetry_client_cohttp_eio.reset_tick_health ();
  (* Shared setup: init library, register OTLP backend, fork health-check fiber.
     Called only after probe confirms collector is reachable. *)
  let start_exporter () =
    (* Initialize the OTel library only when we have a reachable collector.
       Calling [init] before probe would start the internal tick loop even
       when no collector exists, producing WARN spam on every export cycle. *)
    init ();
    let config =
      Opentelemetry_client_cohttp_eio.Config.make ~url:endpoint ()
    in
    Opentelemetry_client_cohttp_eio.setup ~sw ~config env;
    Atomic.set exporter_active true;
    Atomic.set _last_successful_export (Some (Unix.gettimeofday ()));
    Atomic.set _consecutive_failures 0;
    Log.Otel.info "OTLP exporter started -> %s" endpoint;
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
  in
  let rec try_setup attempt =
    if not (enabled ()) then ()
    else if not (probe_endpoint ~env endpoint) then
      if attempt < 5 then begin
        let delay = Float.of_int (1 lsl attempt) in
        Log.Otel.warn "OTLP collector unreachable (%s), retry %d/5 in %.1fs"
          endpoint (attempt + 1) delay;
        Eio.Time.sleep clock delay;
        try_setup (attempt + 1)
      end else begin
        Log.Otel.warn
          "OTLP collector unreachable after 5 retries (%s), recovery probe every 30s"
          endpoint;
        Atomic.set exporter_active false;
        (* Recovery fiber: masc typically starts before Docker containers.
           Probe every 30s and call [start_exporter] when collector becomes
           available.  No WARN spam — [init] is deferred until success. *)
        let rec recovery_loop () =
          Eio.Time.sleep clock 30.0;
          if not (enabled ()) then ()
          else if probe_endpoint ~env endpoint then
            (try start_exporter () with
             | Eio.Cancel.Cancelled _ as e -> raise e
             | exn ->
               Atomic.set exporter_active false;
               Log.Otel.warn "OTLP recovery setup failed (%s): %s, retrying in 30s"
                 endpoint (Printexc.to_string exn);
               recovery_loop ())
          else recovery_loop ()
        in
        Eio.Fiber.fork ~sw recovery_loop
      end
    else
      try start_exporter () with
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
  in
  try_setup 0

(** Flush pending spans and remove the OTLP backend.
    Safe to call when disabled (no-op). *)
let shutdown ?(enabled = Otel_config.enabled) () =
  if enabled && Atomic.get exporter_active then begin
    Opentelemetry_client_cohttp_eio.remove_backend ();
    Log.Otel.info "OTLP exporter stopped"
  end;
  Opentelemetry_client_cohttp_eio.reset_tick_health ();
  Atomic.set exporter_active false;
  Atomic.set initialized false;
  Atomic.set _last_successful_export None;
  Atomic.set _consecutive_failures 0

(** Wrap a function in an OTel span. No-op when disabled.
    Returns the result of [f].
    When [force_new_trace_id] is true, starts a fresh trace root instead
    of nesting under the ambient parent span. Use at operation boundaries
    (e.g. each tool dispatch) to keep traces small and readable. *)
let with_span ~name ?(attrs = []) ?(force_new_trace_id = false) f =
  if not Otel_config.enabled then f (fun () -> None)
  else
    OT.Trace.with_ ~force_new_trace_id name ~attrs (fun scope ->
      f (fun () ->
        let ctx = OT.Scope.to_span_ctx scope in
        let trace_id = OT.Trace_id.to_hex (OT.Span_ctx.trace_id ctx) in
        let span_id = OT.Span_id.to_hex (OT.Span_ctx.parent_id ctx) in
        Some (trace_id, span_id)))

(** Add an event to the active OTel span. No-op when disabled or when no
    ambient span exists. *)
let add_event ~name ?(attrs = []) () =
  if enabled ()
  then
    match Atomic.get event_emitter_override with
    | Some emit -> emit ~name ~attrs
    | None ->
      (match OT.Scope.get_ambient_scope () with
       | Some scope ->
         OT.Scope.add_event scope (fun () -> OT.Event.make ~attrs name)
       | None -> ())
;;

let add_attrs ?(attrs = []) () =
  if enabled ()
  then
    match Atomic.get attrs_emitter_override with
    | Some emit -> emit ~attrs
    | None ->
      (match OT.Scope.get_ambient_scope () with
       | Some scope -> OT.Scope.add_attrs scope (fun () -> attrs)
       | None -> ())
;;

let set_status status =
  if enabled ()
  then
    match Atomic.get status_emitter_override with
    | Some emit -> emit status
    | None ->
      (match OT.Scope.get_ambient_scope () with
       | Some scope -> OT.Scope.set_status scope status
       | None -> ())
;;

let record_error ?(attrs = []) ~message ~error_type () =
  let status =
    OT.Span_status.make ~message ~code:OT.Span_status.Status_code_error
  in
  let span_attrs = ("error.type", `String error_type) :: attrs in
  set_status status;
  add_attrs ~attrs:span_attrs ();
  add_event
    ~name:"gen_ai.client.operation.exception"
    ~attrs:
      [ "exception.message", `String message
      ; "exception.type", `String error_type
      ]
    ()
;;

let with_test_event_emitter
      ~enabled:enabled_value
      ~emit_event
      ?emit_attrs
      ?set_status:set_status_hook
      f
  =
  let prev_enabled = Atomic.get enabled_override in
  let prev_emitter = Atomic.get event_emitter_override in
  let prev_attrs_emitter = Atomic.get attrs_emitter_override in
  let prev_status_emitter = Atomic.get status_emitter_override in
  Atomic.set enabled_override (Some enabled_value);
  Atomic.set event_emitter_override (Some emit_event);
  Atomic.set attrs_emitter_override emit_attrs;
  Atomic.set status_emitter_override set_status_hook;
  Eio_guard.protect
    ~finally:(fun () ->
      Atomic.set enabled_override prev_enabled;
      Atomic.set event_emitter_override prev_emitter;
      Atomic.set attrs_emitter_override prev_attrs_emitter;
      Atomic.set status_emitter_override prev_status_emitter)
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
