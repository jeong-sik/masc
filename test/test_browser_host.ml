(* The native host keeps a reply that lands as its window closes.

   [Browser_host.forward] raced the frame write and the reply against a
   timer with [Fiber.first], which keeps whichever arm finished first, and
   eio_posix runs an expired timer before a ready fd. The extension aborts a
   command at the very [deadlineMs] the host sent it, so its reply --
   "not_started" when the effect had not begun, which the server may retry
   -- and the host's own timer land together by design; when the timer's
   wake-up ran first, the reply was replaced by "extension reply timed out",
   an outcome the server treats as unknown and does not retry. The mock
   clock puts the timer's wake-up ahead of the reply's on purpose. *)
open Alcotest
module Host = Browser_host

let command : Host.command = { id = "cmd-1"; verb = Host.Page_interact; args = `Assoc [] }

(* The extension's own verdict at its deadline: nothing was started. *)
let reply_from_the_extension =
  `Assoc
    [ "id", `String "cmd-1"
    ; "ok", `Bool false
    ; "error", `String "browser_command_expired"
    ; "effectPhase", `String "not_started"
    ]
;;

let json = testable (fun fmt v -> Format.pp_print_string fmt (Yojson.Safe.to_string v)) ( = )

(* A window for the bounded-step helper alone. *)
let step_window_s = 1.0

let with_host f =
  Eio_mock.Backend.run
  @@ fun () ->
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 0.0;
  Eio.Switch.run
  @@ fun sw -> f ~sw ~clock
;;

let forward_in_background ~sw ~clock pending =
  let frames = Buffer.create 256 in
  let forwarded =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Host.forward ~clock ~stdout:(Eio.Flow.buffer_sink frames) pending command)
  in
  check bool "the command frame was written before any wait" true (Buffer.length frames > 0);
  forwarded
;;

let test_a_reply_that_lands_as_the_window_closes_is_the_reply () =
  with_host
  @@ fun ~sw ~clock ->
  let pending = Host.no_pending () in
  let forwarded = forward_in_background ~sw ~clock pending in
  (* The window closes first: the timer's wake-up is queued. The reply then
     lands, queuing the exchange's wake-up behind it. *)
  Eio_mock.Clock.set_time clock Host.extension_timeout_sec;
  (match Host.settle pending reply_from_the_extension with
   | Ok () -> ()
   | Error error -> fail error);
  match Eio.Promise.await_exn forwarded with
  | Host.Replied envelope -> check json "the extension's reply is the reply" reply_from_the_extension envelope
  | Host.Write_timed_out -> fail "the frame was written; the window closed on the reply"
;;

let test_a_reply_inside_the_window_is_the_reply () =
  with_host
  @@ fun ~sw ~clock ->
  let pending = Host.no_pending () in
  let forwarded = forward_in_background ~sw ~clock pending in
  Eio_mock.Clock.set_time clock (Host.extension_timeout_sec /. 2.0);
  (match Host.settle pending reply_from_the_extension with
   | Ok () -> ()
   | Error error -> fail error);
  match Eio.Promise.await_exn forwarded with
  | Host.Replied envelope -> check json "the extension's reply is the reply" reply_from_the_extension envelope
  | Host.Write_timed_out -> fail "the frame was written; the reply arrived inside the window"
;;

let test_a_window_that_closes_with_no_reply_is_the_hosts_failure () =
  with_host
  @@ fun ~sw ~clock ->
  let pending = Host.no_pending () in
  let forwarded = forward_in_background ~sw ~clock pending in
  Eio_mock.Clock.set_time clock Host.extension_timeout_sec;
  match Eio.Promise.await_exn forwarded with
  | Host.Replied envelope ->
    check
      json
      "the host's failure names the silent extension"
      (`Assoc
        [ "id", `String "cmd-1"; "ok", `Bool false; "error", `String "extension reply timed out" ])
      envelope
  | Host.Write_timed_out -> fail "the frame was written; only the reply was missing"
;;

(* A reply for another command is not this exchange's. *)
let test_a_reply_for_another_command_does_not_settle_the_exchange () =
  with_host
  @@ fun ~sw ~clock ->
  let pending = Host.no_pending () in
  let forwarded = forward_in_background ~sw ~clock pending in
  (match
     Host.settle
       pending
       (`Assoc [ "id", `String "someone-else"; "ok", `Bool true; "data", `Assoc [] ])
   with
   | Ok () -> ()
   | Error error -> fail error);
  Eio_mock.Clock.set_time clock Host.extension_timeout_sec;
  match Eio.Promise.await_exn forwarded with
  | Host.Replied envelope ->
    check
      json
      "the exchange still waited for its own reply"
      (`Assoc
        [ "id", `String "cmd-1"; "ok", `Bool false; "error", `String "extension reply timed out" ])
      envelope
  | Host.Write_timed_out -> fail "the frame was written; only the reply was missing"
;;

(* The helper every HTTP round trip and BiDi command runs under. *)
let test_a_step_that_finished_as_its_deadline_passed_is_the_steps_outcome () =
  with_host
  @@ fun ~sw ~clock ->
  let answered, answer = Eio.Promise.create () in
  let stepped =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Host.For_testing.within ~clock step_window_s (fun () -> Eio.Promise.await answered))
  in
  Eio_mock.Clock.set_time clock step_window_s;
  Eio.Promise.resolve answer "the answer";
  check (option string) "the step's outcome stands" (Some "the answer") (Eio.Promise.await_exn stepped)
;;

let test_a_step_still_running_at_its_deadline_is_none () =
  with_host
  @@ fun ~sw ~clock ->
  let stepped =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Host.For_testing.within ~clock step_window_s (fun () -> Eio.Fiber.await_cancel ()))
  in
  Eio_mock.Clock.set_time clock step_window_s;
  check (option string) "the deadline is the verdict" None (Eio.Promise.await_exn stepped)
;;

let () =
  Alcotest.run
    "browser_host"
    [ ( "forward"
      , [ test_case
            "a reply that lands as the window closes is the reply"
            `Quick
            test_a_reply_that_lands_as_the_window_closes_is_the_reply
        ; test_case
            "a reply inside the window is the reply"
            `Quick
            test_a_reply_inside_the_window_is_the_reply
        ; test_case
            "a window that closes with no reply is the host's failure"
            `Quick
            test_a_window_that_closes_with_no_reply_is_the_hosts_failure
        ; test_case
            "a reply for another command does not settle the exchange"
            `Quick
            test_a_reply_for_another_command_does_not_settle_the_exchange
        ] )
    ; ( "within"
      , [ test_case
            "a step that finished as its deadline passed is the step's outcome"
            `Quick
            test_a_step_that_finished_as_its_deadline_passed_is_the_steps_outcome
        ; test_case
            "a step still running at its deadline is None"
            `Quick
            test_a_step_still_running_at_its_deadline_is_none
        ] )
    ]
;;
