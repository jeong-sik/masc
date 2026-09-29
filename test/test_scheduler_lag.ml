open Alcotest

let record_all t lags =
  List.iter (fun lag_s -> Scheduler_lag.For_testing.record t ~lag_s) lags
;;

let has_field fields key value = List.mem (key, value) fields

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

(* What the summary must report, computed the plain way: sort a copy and read
   the nearest ranks off it. *)
let sorted_reference lags =
  let xs = Array.of_list lags in
  Array.sort Float.compare xs;
  let n = Array.length xs in
  let at p =
    let rank = int_of_float (Float.ceil (p *. Float.of_int n)) in
    xs.(Int.max 0 (Int.min (n - 1) (rank - 1)))
  in
  at 0.50, at 0.95, at 0.99, xs.(n - 1)
;;

(* Sample sets shaped like a ring can hold: sizes around the ranks' rounding
   edges and the default window, heavy duplicates, runs already in order or
   reversed, and a tail of stalls. *)
let reference_cases () =
  let state = Random.State.make [| 20260929 |] in
  let random_lags n ~distinct =
    List.init n (fun _ ->
      if Random.State.int state 100 < 3
      then 1.0 +. Random.State.float state 4.0
      else Float.of_int (Random.State.int state distinct) *. 0.0005)
  in
  let sizes = [ 1; 2; 3; 4; 5; 19; 20; 21; 99; 100; 101; 599; 600 ] in
  let shaped n =
    let lags = random_lags n ~distinct:1000 in
    [ lags
    ; random_lags n ~distinct:3
    ; List.init n (fun _ -> 0.002)
    ; List.sort Float.compare lags
    ; List.rev (List.sort Float.compare lags)
    ]
  in
  List.concat_map shaped sizes
  @ List.init 200 (fun _ ->
    random_lags (1 + Random.State.int state 600) ~distinct:(1 + Random.State.int state 50))
;;

let test_percentiles_match_a_full_sort () =
  List.iteri
    (fun case lags ->
       let n = List.length lags in
       let t = Scheduler_lag.create ~interval_s:0.1 ~window:n () in
       record_all t lags;
       let p50, p95, p99, largest = sorted_reference lags in
       let ms seconds = seconds *. 1000.0 in
       match Scheduler_lag.summarize t with
       | None -> fail (Printf.sprintf "case %d: %d samples were recorded" case n)
       | Some s ->
         let exact label expected actual =
           check (float 0.0) (Printf.sprintf "case %d (n=%d) %s" case n label) expected actual
         in
         exact "p50" (ms p50) s.p50_ms;
         exact "p95" (ms p95) s.p95_ms;
         exact "p99" (ms p99) s.p99_ms;
         exact "max" (ms largest) s.max_ms)
    (reference_cases ())
;;

let test_empty_ring_has_no_percentiles () =
  let t = Scheduler_lag.create () in
  let fields = Scheduler_lag.to_fields t in
  check bool "samples 0" true (has_field fields "samples" (`Int 0));
  check bool "no p50" false (List.mem_assoc "p50_ms" fields);
  check bool "not started" true (has_field fields "probe" (`String "not_started"))
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

(* The probe records on a real scheduler, says [running] while it does, and
   says [cancelled] once the switch that owned it is gone. The wait is a
   deadline, not a fixed sleep: a loaded test runner may stall the domain
   for longer than a few probe periods. *)
let live_probe_wait_deadline_s = 5.0

let test_live_probe_records_then_reports_cancelled () =
  Eio_main.run
  @@ fun env ->
  let t = Scheduler_lag.create ~interval_s:0.005 ~window:100 () in
  let mono_clock = Eio.Stdenv.mono_clock env in
  let clock = Eio.Stdenv.clock env in
  Eio.Fiber.first
    (fun () ->
      Eio.Switch.run (fun sw ->
        Scheduler_lag.start ~sw ~mono_clock t;
        check
          bool
          "running once started"
          true
          (has_field (Scheduler_lag.to_fields t) "probe" (`String "running"));
        Eio.Fiber.await_cancel ()))
    (fun () ->
      let deadline = Eio.Time.now clock +. live_probe_wait_deadline_s in
      let rec wait () =
        match Scheduler_lag.summarize t with
        | Some s when s.samples >= 3 -> ()
        | Some _ | None ->
          if Eio.Time.now clock < deadline
          then begin
            Eio.Time.sleep clock 0.01;
            wait ()
          end
          else fail "the probe recorded fewer than three samples before the deadline"
      in
      wait ());
  check
    bool
    "cancelled once the switch is gone"
    true
    (has_field (Scheduler_lag.to_fields t) "probe" (`String "cancelled"))
;;

let () =
  run
    "scheduler_lag"
    [ ( "ring"
      , [ test_case "percentiles" `Quick test_percentiles_over_recorded_samples
        ; test_case "window" `Quick test_ring_keeps_only_the_window
        ; test_case "same ranks as a full sort" `Quick test_percentiles_match_a_full_sort
        ; test_case "empty" `Quick test_empty_ring_has_no_percentiles
        ; test_case "shape" `Quick test_invalid_shape_is_refused
        ] )
    ; ( "probe"
      , [ test_case "live" `Quick test_live_probe_records_then_reports_cancelled ] )
    ]
;;
