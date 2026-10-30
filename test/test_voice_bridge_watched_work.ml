(* A Voice MCP answer that arrived as its window closed is the answer.

   [Voice_bridge] raced each MCP call against its window with
   [Fiber.first], which keeps whichever arm finished first; eio_posix runs
   an expired timer before a ready fd. A sentence the voice server had
   spoken was then reported as [Timed_out], an outcome its caller may act
   on by speaking again. The mock clock puts the timer's wake-up ahead of
   the answer's on purpose. *)
open Alcotest
open Masc

let window_s = 1.0

let error =
  testable
    (fun fmt e -> Format.pp_print_string fmt (Voice_bridge.mcp_call_error_to_string e))
    ( = )
;;

let with_clock f =
  Eio_mock.Backend.run
  @@ fun () ->
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 0.0;
  Eio.Switch.run
  @@ fun sw -> f ~sw ~clock
;;

let test_an_answer_that_arrived_as_the_window_closed_is_the_answer () =
  with_clock
  @@ fun ~sw ~clock ->
  let answered, answer = Eio.Promise.create () in
  let call =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Voice_bridge.For_testing.with_timeout ~clock ~timeout:window_s (fun () ->
        Ok (Eio.Promise.await answered)))
  in
  (* The window closes first: the timer's wake-up is queued. The answer
     then arrives, queuing the call's wake-up behind it. *)
  Eio_mock.Clock.set_time clock window_s;
  Eio.Promise.resolve answer "spoken";
  check
    (result string error)
    "the answer that arrived is the answer"
    (Ok "spoken")
    (Eio.Promise.await_exn call)
;;

let test_a_window_that_closes_with_no_answer_is_timed_out () =
  with_clock
  @@ fun ~sw ~clock ->
  let call =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Voice_bridge.For_testing.with_timeout ~clock ~timeout:window_s (fun () ->
        Ok (Eio.Fiber.await_cancel ())))
  in
  Eio_mock.Clock.set_time clock window_s;
  check
    (result string error)
    "the window is the verdict"
    (Error (Voice_bridge.Timed_out window_s))
    (Eio.Promise.await_exn call)
;;

let () =
  Alcotest.run
    "voice_bridge watched work"
    [ ( "with_timeout"
      , [ test_case
            "an answer that arrived as the window closed is the answer"
            `Quick
            test_an_answer_that_arrived_as_the_window_closed_is_the_answer
        ; test_case
            "a window that closes with no answer is Timed_out"
            `Quick
            test_a_window_that_closes_with_no_answer_is_timed_out
        ] )
    ]
;;
