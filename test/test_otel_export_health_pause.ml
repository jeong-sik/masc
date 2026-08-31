(* Mid-run collector outage: the health loop marks the exporter inactive, and
   a returning collector restarts it. Before this behavior, [exporter_active]
   latched false forever after an outage while the export backend kept
   attempting sends against the dead endpoint — one full transport backtrace
   WARN per attempt, every export cycle, for the rest of the process life.

   The stop flag itself is the pre-existing [create_backend ~stop] mechanism
   (see test_otel_otlp_export_e2e); this suite proves the health-loop
   transitions that now drive it. *)

open Alcotest

let wait_until ~clock ~(timeout : float) (cond : unit -> bool) =
  let deadline = ref timeout in
  let ok = ref false in
  while !deadline > 0.0 && not !ok do
    if cond () then ok := true
    else (
      Eio.Time.sleep clock 0.02;
      deadline := !deadline -. 0.02)
  done;
  !ok
;;

let listen_probe_target ~sw (env : Eio_unix.Stdenv.base) port =
  (* Accept-and-close listener: TCP connect succeeds (the probe's success
     condition), no bytes are exchanged. Export POSTs that reach it get an
     immediate close; the emitter treats that as a failed export, which is
     fine — activity here is driven by the health probe, not exports. *)
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
  let socket = Eio.Net.listen env#net ~sw ~reuse_addr:true ~backlog:8 addr in
  Eio.Fiber.fork ~sw (fun () ->
    try
      while true do
        let flow, _ = Eio.Net.accept ~sw socket in
        Eio.Switch.run (fun csw ->
          Eio.Switch.on_release csw (fun () -> Eio.Flow.close flow);
          ())
      done
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | _ -> ());
  socket
;;

let test_outage_marks_inactive_then_restarts () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let clock = env#clock in
  let port = 19000 + Unix.getpid () mod 1000 in
  let endpoint = Printf.sprintf "http://127.0.0.1:%d" port in
  let first = listen_probe_target ~sw env port in
  Otel_spans.setup_exporter ~endpoint ~probe_interval:0.05 ~sw env;
  check bool "exporter active with collector up"
    true
    (wait_until ~clock ~timeout:5.0 Otel_spans.is_exporter_active);
  (* Collector dies: connections refused, three probes fail, exporter marks
     itself inactive. *)
  Eio.Flow.close first;
  check bool "exporter inactive after collector death"
    false
    (not (wait_until ~clock ~timeout:5.0
            (fun () -> not (Otel_spans.is_exporter_active ()))));
  (* Collector returns on the same port: the health probe restarts the
     exporter instead of leaving [exporter_active] latched false. *)
  ignore (listen_probe_target ~sw env port);
  check bool "exporter restarts when collector returns"
    true
    (wait_until ~clock ~timeout:5.0 Otel_spans.is_exporter_active);
  Opentelemetry_client_cohttp_eio.remove_backend ()
;;

let () =
  run
    "otel_export_health_pause"
    [ ( "health loop"
      , [ test_case
            "collector outage deactivates the exporter and restart restores it"
            `Quick
            test_outage_marks_inactive_then_restarts
        ] )
    ]
;;
