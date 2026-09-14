(* Work the pool races against a watcher keeps its own outcome.

   [Fiber.first] keeps whichever arm finished first and drops the other's
   result. When the watcher's wake-up is queued ahead of the work's in the
   same scheduler pass -- the answer's last byte and the deadline arriving
   together -- an answer that had arrived was reported as the watcher's
   verdict: "timeout after", "idle timeout after". The mock clock puts the
   two wake-ups in the run queue in that order on purpose: the work waits on
   a promise or a body stream, and that is completed right after the clock
   passes the window, so the watcher's wake-up is queued first and the
   work's second. *)
open Alcotest
module Pool = Masc_http_client.Pool

let window_s = 1.0

let test_an_answer_that_arrived_as_the_window_passed_is_the_result () =
  Eio_mock.Backend.run
  @@ fun () ->
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 0.0;
  Eio.Switch.run
  @@ fun sw ->
  let answer, arrive = Eio.Promise.create () in
  let work =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Pool.For_testing.with_request_timeout ~clock ~timeout_seconds:window_s (fun () ->
        Ok (Eio.Promise.await answer)))
  in
  (* The window passes first: the timer's wake-up is queued. The answer
     then arrives, queuing the work's wake-up behind it. *)
  Eio_mock.Clock.set_time clock window_s;
  Eio.Promise.resolve arrive "the answer";
  match Eio.Promise.await_exn work with
  | Ok answer -> check string "the answer that arrived is the result" "the answer" answer
  | Error message -> failf "an answer that arrived as the window passed was dropped: %s" message
;;

let test_an_answer_that_never_arrives_is_a_timeout () =
  Eio_mock.Backend.run
  @@ fun () ->
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 0.0;
  Eio.Switch.run
  @@ fun sw ->
  let never, _ = Eio.Promise.create () in
  let work =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Pool.For_testing.with_request_timeout ~clock ~timeout_seconds:window_s (fun () ->
        Ok (Eio.Promise.await never)))
  in
  Eio_mock.Clock.set_time clock window_s;
  match Eio.Promise.await_exn work with
  | Error message ->
    check string "the timeout names the window" "Pool.request: timeout after 1.0s" message
  | Ok () -> fail "nothing arrived, yet the wait did not end as a timeout"
;;

(* The same order on the idle watcher: the body's end and the idle window
   arrive together, and the body that ended is the body. *)
let test_a_body_that_ended_as_the_idle_window_passed_is_the_body () =
  Eio_mock.Backend.run
  @@ fun () ->
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 0.0;
  Eio.Switch.run
  @@ fun sw ->
  let stream, push = Piaf.Stream.create 16 in
  let body = Piaf.Body.of_string_stream stream in
  (* One chunk is already there when the read starts: the body fiber takes
     it and blocks on the next, and the watcher's first window opens with
     that chunk as the last one seen. *)
  push (Some "the body");
  let read =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Pool.For_testing.read_body_with_idle
        ~clock
        ~start_sec:(Eio.Time.now clock)
        ~idle_timeout_sec:window_s
        body)
  in
  (* The idle window passes with no further chunk: the watcher's wake-up
     is queued. The stream then ends, queuing the body fiber's wake-up
     behind it. *)
  Eio_mock.Clock.set_time clock window_s;
  push None;
  match Eio.Promise.await_exn read with
  | Ok (body, progress) ->
    check string "the body that ended is the result" "the body" body;
    check int "its bytes were counted" 8 progress.Pool.bytes_received
  | Error (message, _) -> failf "a body that ended as the window passed was dropped: %s" message
;;

let () =
  Alcotest.run
    "pool watched work"
    [ ( "the work's outcome stands"
      , [ test_case
            "an answer that arrived as the window passed is the result"
            `Quick
            test_an_answer_that_arrived_as_the_window_passed_is_the_result
        ; test_case
            "an answer that never arrives is a timeout"
            `Quick
            test_an_answer_that_never_arrives_is_a_timeout
        ; test_case
            "a body that ended as the idle window passed is the body"
            `Quick
            test_a_body_that_ended_as_the_idle_window_passed_is_the_body
        ] )
    ]
;;
