open Alcotest

let record_all t lags = List.iter (fun lag_s -> Scheduler_lag.record t ~lag_s) lags

let test_percentiles_over_recorded_samples () =
  let t = Scheduler_lag.create ~interval_s:0.1 ~window:16 () in
  record_all t [ 0.001; 0.002; 0.003; 0.004; 0.005; 0.006; 0.007; 0.008; 0.009; 1.5 ];
  match Scheduler_lag.summarize t with
  | None -> fail "ten samples were recorded"
  | Some s ->
    check int "samples" 10 s.samples;
    (* nearest rank: ceil(0.5 * 10) = 5 -> the fifth smallest, 5ms *)
    check (float 1e-6) "p50" 5.0 s.p50_ms;
    (* ceil(0.95 * 10) = 10 and ceil(0.99 * 10) = 10 -> the largest *)
    check (float 1e-6) "p95" 1500.0 s.p95_ms;
    check (float 1e-6) "p99" 1500.0 s.p99_ms;
    check (float 1e-6) "max" 1500.0 s.max_ms;
    check int "stalls" 1 s.stalls
;;

let test_ring_keeps_only_the_window () =
  let t = Scheduler_lag.create ~interval_s:0.1 ~window:4 () in
  record_all t [ 9.0; 9.0; 0.1; 0.2; 0.3; 0.4 ];
  match Scheduler_lag.summarize t with
  | None -> fail "samples were recorded"
  | Some s ->
    check int "window" 4 s.samples;
    check (float 1e-6) "max after the two 9s were overwritten" 400.0 s.max_ms;
    check int "stalls" 0 s.stalls
;;

let test_empty_ring_has_no_percentiles () =
  let t = Scheduler_lag.create () in
  let fields = Scheduler_lag.to_fields t in
  check bool "samples 0" true (List.mem ("samples", `Int 0) fields);
  check bool "no p50" false (List.mem_assoc "p50_ms" fields);
  check bool "not started" true (List.mem ("probe", `String "not_started") fields)
;;

let test_invalid_shape_is_refused () =
  check_raises
    "zero interval"
    (Invalid_argument "Scheduler_lag.create: interval_s must be positive")
    (fun () -> ignore (Scheduler_lag.create ~interval_s:0.0 ()));
  check_raises
    "zero window"
    (Invalid_argument "Scheduler_lag.create: window must be positive")
    (fun () -> ignore (Scheduler_lag.create ~window:0 ()))
;;

let test_live_probe_records_on_the_scheduler () =
  Eio_main.run
  @@ fun env ->
  let t = Scheduler_lag.create ~interval_s:0.005 ~window:100 () in
  let mono_clock = Eio.Stdenv.mono_clock env in
  let clock = Eio.Stdenv.clock env in
  Eio.Fiber.first
    (fun () ->
      Eio.Switch.run (fun sw ->
        Scheduler_lag.start ~sw ~mono_clock t;
        Eio.Fiber.await_cancel ()))
    (fun () -> Eio.Time.sleep clock 0.1);
  match Scheduler_lag.summarize t with
  | None -> fail "the probe recorded nothing in 100ms"
  | Some s ->
    check bool "several samples" true (s.samples >= 3);
    check
      bool
      "running"
      true
      (List.mem ("probe", `String "running") (Scheduler_lag.to_fields t))
;;

let () =
  run
    "scheduler_lag"
    [ ( "ring"
      , [ test_case "percentiles" `Quick test_percentiles_over_recorded_samples
        ; test_case "window" `Quick test_ring_keeps_only_the_window
        ; test_case "empty" `Quick test_empty_ring_has_no_percentiles
        ; test_case "shape" `Quick test_invalid_shape_is_refused
        ] )
    ; "probe", [ test_case "live" `Quick test_live_probe_records_on_the_scheduler ]
    ]
;;
