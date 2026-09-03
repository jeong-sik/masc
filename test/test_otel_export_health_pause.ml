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
     fine — activity here is driven by the health probe, not exports.

     The accept loop is a daemon: it exists only to serve the test body, and
     a daemon cannot keep [Eio.Switch.run] from returning once that body is
     done. *)
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
  let socket = Eio.Net.listen env#net ~sw ~reuse_addr:true ~backlog:8 addr in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    try
      while true do
        let flow, _ = Eio.Net.accept ~sw socket in
        Eio.Switch.run (fun csw ->
          Eio.Switch.on_release csw (fun () -> Eio.Flow.close flow);
          ())
      done;
      `Stop_daemon
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | _ -> `Stop_daemon);
  socket
;;

let test_outage_marks_inactive_then_restarts () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let clock = env#clock in
  (* Port 0 and read the bound address back, the way the other OTLP tests
     do. A pid-derived port collided under the parallel suite: another
     test's live server took it over after [first] closed, the probe kept
     answering against that foreign server, and the run wedged instead of
     observing an outage. The second listener reuses the exact port the
     first was given, because "the collector returns on the same port" is
     the behavior under test. *)
  let first = listen_probe_target ~sw env 0 in
  let port =
    match Eio.Net.listening_addr first with
    | `Tcp (_, port) -> port
    | _ -> Alcotest.fail "expected a TCP probe listener"
  in
  let endpoint = Printf.sprintf "http://127.0.0.1:%d" port in
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
  (* Collector returns on the same port: the probe supervisor restarts the
     exporter instead of leaving [exporter_active] latched false. *)
  let second = listen_probe_target ~sw env port in
  check bool "exporter restarts when collector returns"
    true
    (wait_until ~clock ~timeout:5.0 Otel_spans.is_exporter_active);
  (* Tear the fibers down so [Eio_main.run] can return: listeners closed
     (their accept loops exit), backend stopped, supervisor retired by the
     runtime disable. *)
  Eio.Flow.close second;
  Otel_spans.set_runtime_enabled false;
  Otel_spans.stop_current_export_backend ();
  Opentelemetry_client_cohttp_eio.remove_backend ();
  Eio.Time.sleep clock 0.7
;;

let contains ~needle haystack =
  let n = String.length needle
  and h = String.length haystack in
  let rec scan i = i + n <= h && (String.sub haystack i n = needle || scan (i + 1)) in
  n = 0 || scan 0
;;

(* Steady state is not news. The supervisor used to report every failed probe
   at WARN for the life of the process, long after it had already deactivated
   the exporter and said so at ERROR. One 19h window carried 1,133 of its
   1,686 WARN/ERROR lines from this one line, the last at 909 consecutive,
   which is what buried the other 553. The count itself is not lost: it keeps
   advancing and is served as [consecutive_failures] on the runtime route.

   The recovery path in the same function already states this contract in its
   own comment ("No WARN spam"); the supervisor was the loop that broke it. *)
let test_probe_failures_stop_warning_once_inactive () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let clock = env#clock in
  Log.set_level Log.Debug;
  Otel_spans.set_runtime_enabled true;
  let collector = listen_probe_target ~sw env 0 in
  let port =
    match Eio.Net.listening_addr collector with
    | `Tcp (_, port) -> port
    | _ -> Alcotest.fail "expected a TCP probe listener"
  in
  let endpoint = Printf.sprintf "http://127.0.0.1:%d" port in
  Otel_spans.setup_exporter ~endpoint ~probe_interval:0.05 ~sw env;
  check
    bool
    "exporter active with collector up"
    true
    (wait_until ~clock ~timeout:5.0 Otel_spans.is_exporter_active);
  Eio.Flow.close collector;
  (* Past the deactivation, not merely past the first miss: the transition
     fires on the third consecutive failure while still active, and those
     first three lines are the ones that should warn. *)
  check
    bool
    "the exporter reached its deactivation"
    true
    (wait_until ~clock ~timeout:5.0 (fun () -> Otel_spans.consecutive_failures () >= 5));
  let cursor = (Log.Ring.bounds ()).Log.Ring.total in
  let failures_before = Otel_spans.consecutive_failures () in
  Eio.Time.sleep clock 0.5;
  check
    bool
    "the probe kept running"
    true
    (Otel_spans.consecutive_failures () > failures_before);
  let health_lines min_level =
    Log.Ring.recent ~limit:500 ~min_level ~since_seq:(cursor - 1) ~order:`Oldest_first ()
    |> List.filter (fun (entry : Log.Ring.entry) ->
      contains ~needle:"OTLP health check failed" entry.Log.Ring.message)
  in
  check
    int
    "no WARN once the exporter is already inactive"
    0
    (List.length (health_lines (Log.level_to_int Log.Warn)));
  (* Not vacuous: the same window does carry those probes, below WARN. *)
  check
    bool
    "the failures are still recorded"
    true
    (List.length (health_lines (Log.level_to_int Log.Debug)) > 0);
  Otel_spans.set_runtime_enabled false;
  Otel_spans.stop_current_export_backend ();
  Opentelemetry_client_cohttp_eio.remove_backend ();
  Log.set_level Log.Info;
  Eio.Time.sleep clock 0.7
;;

let () =
  run
    "otel_export_health_pause"
    [ ( "health"
      , [ test_case
            "collector outage deactivates the exporter and restart restores it"
            `Quick
            test_outage_marks_inactive_then_restarts
        ; test_case
            "probe failures stop warning once the exporter is inactive"
            `Quick
            test_probe_failures_stop_warning_once_inactive
        ] )
    ]
;;
