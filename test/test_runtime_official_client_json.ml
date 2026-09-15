(* The official-client idle window keeps a line that arrived as it passed.

   [Runtime_official_client_json.Make(E).with_idle_timeout] bounds every
   read of the claude code, codex app-server and antigravity lanes. It raced
   the read against a timer with [Eio.Time.with_timeout], which keeps
   whichever arm finished first: a line that arrived as the window passed
   ended the turn as an idle timeout. The mock clock queues the timer's
   wake-up ahead of the read's on purpose. *)
open Alcotest

module Shared_json = Runtime_official_client_json.Make (struct
    type t = string

    let protocol ~stage ~detail = stage ^ ": " ^ detail
  end)

let window_s = 1.0

let test_a_line_that_arrived_as_the_window_passed_is_the_line () =
  Eio_mock.Backend.run
  @@ fun () ->
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 0.0;
  Eio.Switch.run
  @@ fun sw ->
  let line, arrive = Eio.Promise.create () in
  let read =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Shared_json.with_idle_timeout clock window_s (fun () -> Eio.Promise.await line))
  in
  Eio_mock.Clock.set_time clock window_s;
  Eio.Promise.resolve arrive {|{"type":"result"}|};
  match Eio.Promise.await read with
  | Ok line -> check string "the line that arrived is the result" {|{"type":"result"}|} line
  | Error (Shared_json.Idle_timeout seconds) ->
    failf "a line that arrived as the %.1fs window passed was dropped" seconds
  | Error exn -> raise exn
;;

let test_a_read_nothing_answers_is_an_idle_timeout () =
  Eio_mock.Backend.run
  @@ fun () ->
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 0.0;
  Eio.Switch.run
  @@ fun sw ->
  let never, _ = Eio.Promise.create () in
  let read =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Shared_json.with_idle_timeout clock window_s (fun () -> Eio.Promise.await never))
  in
  Eio_mock.Clock.set_time clock window_s;
  match Eio.Promise.await read with
  | Error (Shared_json.Idle_timeout seconds) -> check (float 0.0) "the window it names" window_s seconds
  | Ok () -> fail "nothing arrived, yet the read did not end as an idle timeout"
  | Error exn -> raise exn
;;

let () =
  Alcotest.run
    "runtime official client json"
    [ ( "the idle window"
      , [ test_case
            "a line that arrived as the window passed is the line"
            `Quick
            test_a_line_that_arrived_as_the_window_passed_is_the_line
        ; test_case
            "a read nothing answers is an idle timeout"
            `Quick
            test_a_read_nothing_answers_is_an_idle_timeout
        ] )
    ]
;;
