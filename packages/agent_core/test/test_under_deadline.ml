(* A result that finished in the same scheduler pass its deadline expired
   stands. [Eio.Time.with_timeout] keeps whichever arm finished first: when
   the timer's wake-up is queued ahead of the work's, a response that had
   arrived was reported as one that had not. The mock clock puts the two
   wake-ups in the run queue in that order on purpose: the work waits on a
   promise, and the promise is resolved right after the clock passes the
   deadline, so the timer's wake-up is queued first and the work's second. *)
open Alcotest
module Under_deadline = Llm_provider.Under_deadline

let deadline_s = 1.0

let test_a_result_finished_as_the_deadline_passed_stands () =
  Eio_mock.Backend.run
  @@ fun () ->
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 0.0;
  Eio.Switch.run
  @@ fun sw ->
  let answer, arrive = Eio.Promise.create () in
  let work =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Under_deadline.run clock deadline_s (fun () -> Eio.Promise.await answer))
  in
  (* The deadline passes first: the timer's wake-up is queued. The answer
     then arrives, queuing the work's wake-up behind it. *)
  Eio_mock.Clock.set_time clock deadline_s;
  Eio.Promise.resolve arrive "the answer";
  match Eio.Promise.await_exn work with
  | Ok answer -> check string "the answer that arrived is the result" "the answer" answer
  | Error `Timeout -> fail "an answer that arrived as the deadline passed was dropped"
;;

(* The ordinary expiry: nothing arrives, and the deadline ends the wait. *)
let test_a_result_that_never_arrives_is_a_timeout () =
  Eio_mock.Backend.run
  @@ fun () ->
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 0.0;
  Eio.Switch.run
  @@ fun sw ->
  let never, _ = Eio.Promise.create () in
  let work =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Under_deadline.run clock deadline_s (fun () -> Eio.Promise.await never))
  in
  Eio_mock.Clock.set_time clock deadline_s;
  match Eio.Promise.await_exn work with
  | Error `Timeout -> ()
  | Ok () -> fail "nothing arrived, yet the wait did not end as a timeout"
;;

let () =
  Alcotest.run
    "under_deadline"
    [ ( "the deadline keeps a finished result"
      , [ test_case
            "a result finished as the deadline passed stands"
            `Quick
            test_a_result_finished_as_the_deadline_passed_stands
        ; test_case
            "a result that never arrives is a timeout"
            `Quick
            test_a_result_that_never_arrives_is_a_timeout
        ] )
    ]
;;
