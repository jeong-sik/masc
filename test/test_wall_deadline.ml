open Alcotest

let test_rearm_after_early_wake () =
  let now = ref 100.0 and waits = ref 0 in
  Wall_deadline.For_testing.sleep_until_with ~now:(fun () -> !now)
    ~wait_once:(fun deadline ->
      check (float 0.0) "same absolute deadline" 120.0 deadline;
      incr waits;
      now := if !waits = 1 then 90.0 else 130.0)
    120.0;
  check int "a backwards change rearms, a forward change completes" 2 !waits
;;

let test_native_deadline () =
  Eio_main.run (fun env ->
    let deadline = Unix.gettimeofday () +. 1.0 in
    let armed_at = ref None in
    Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5.0 (fun () ->
      Wall_deadline.sleep_until ~on_armed:(fun () -> armed_at := Some (Unix.gettimeofday ())) deadline);
    check bool "native timer reports arming before the deadline" true
      (match !armed_at with Some at -> at < deadline | None -> false);
    check bool "the wall deadline has passed" true (Unix.gettimeofday () >= deadline))
;;

let test_cancel_does_not_affect_other_waiter () =
  Eio_main.run (fun env ->
    let clock = Eio.Stdenv.clock env in
    let deadline = Unix.gettimeofday () +. 0.3 in
    let completed = ref false in
    Eio.Time.with_timeout_exn clock 5.0 (fun () ->
      Eio.Fiber.both
        (fun () ->
          for _ = 1 to 20 do
            Eio.Fiber.first
              (fun () -> Wall_deadline.sleep_until (Unix.gettimeofday () +. 10.0))
              (fun () -> Eio.Time.sleep clock 0.005)
          done)
        (fun () -> Wall_deadline.sleep_until deadline; completed := true));
    check bool "a separate timer still reaches its deadline" true !completed;
    check bool "the independent deadline has passed" true (Unix.gettimeofday () >= deadline))
;;

let test_invalid_deadline () =
  check_raises "NaN is rejected" (Invalid_argument "wall deadline must be finite")
    (fun () -> Wall_deadline.sleep_until nan)
;;

let () =
  run "wall deadline"
    [ "wait"
    , [ test_case "rearm after an early wake" `Quick test_rearm_after_early_wake
      ; test_case "native deadline" `Quick test_native_deadline
      ; test_case "cancellation isolates another waiter" `Quick test_cancel_does_not_affect_other_waiter
      ; test_case "reject invalid deadline" `Quick test_invalid_deadline
      ] ]
