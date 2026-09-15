(* A dashboard compute that finished as its window closed is the answer.

   [Dashboard_cache] raced each compute against its timeout with
   [Eio.Time.with_timeout], which keeps whichever arm finished first, and
   eio_posix runs an expired timer before a ready fd. A payload the compute
   had already produced was reported as a timeout -- and this timeout is not
   a one-off: three of them open the key's circuit, after which reads answer
   "circuit_open" without computing at all, for as long as the circuit
   stands. The mock clock puts the timer's wake-up ahead of the compute's on
   purpose. *)
open Alcotest
module Cache = Dashboard_cache

let window_s = 1.0
let key = "compute-window"

let with_clock f =
  Eio_mock.Backend.run
  @@ fun () ->
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 0.0;
  Eio.Switch.run @@ fun sw -> f ~sw ~clock
;;

let test_a_compute_that_finished_as_the_window_closed_is_the_answer () =
  with_clock
  @@ fun ~sw ~clock ->
  let computed, finish = Eio.Promise.create () in
  let running =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Cache.For_testing.compute_under_timeout ~clock ~timeout_sec:window_s ~key (fun () ->
        Eio.Promise.await computed))
  in
  (* The window closes first: the timer's wake-up is queued. The compute
     then finishes, queuing its wake-up behind it. *)
  Eio_mock.Clock.set_time clock window_s;
  Eio.Promise.resolve finish "the payload";
  match Eio.Promise.await running with
  | Ok payload -> check string "the payload that was computed is the answer" "the payload" payload
  | Error (Cache.Compute_timeout (key, _)) ->
    failf "a payload computed as the window closed was reported as a timeout on %S" key
  | Error exn -> raise exn
;;

let test_a_compute_that_never_finishes_is_a_timeout () =
  with_clock
  @@ fun ~sw ~clock ->
  let never, _ = Eio.Promise.create () in
  let running =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Cache.For_testing.compute_under_timeout ~clock ~timeout_sec:window_s ~key (fun () ->
        Eio.Promise.await never))
  in
  Eio_mock.Clock.set_time clock window_s;
  match Eio.Promise.await running with
  | Error (Cache.Compute_timeout (timed_out_key, waiting)) ->
    check string "the timeout names its key" key timed_out_key;
    check bool "the owner timed out, not a waiter" false waiting
  | Ok () -> fail "nothing was computed, yet the window did not end the compute"
  | Error exn -> raise exn
;;

let () =
  Alcotest.run
    "dashboard compute window"
    [ ( "compute_under_timeout"
      , [ test_case
            "a compute that finished as the window closed is the answer"
            `Quick
            test_a_compute_that_finished_as_the_window_closed_is_the_answer
        ; test_case
            "a compute that never finishes is a timeout"
            `Quick
            test_a_compute_that_never_finishes_is_a_timeout
        ] )
    ]
;;
