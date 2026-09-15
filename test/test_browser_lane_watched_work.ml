(* The browser lane's waits keep what arrived as their window passed.

   Each wait raced work against a timer with [Fiber.first], which keeps
   whichever arm finished first: a command taken from the stream as the
   take window passed was consumed and dropped, and an answer delivered as
   the issue timeout passed was reported as [Timed_out]. The mock clock,
   installed as the lane's clock, puts the timer's wake-up ahead of the
   work's in the run queue on purpose. *)
open Alcotest
module Lane = Browser_lane

let window_s = 1.0
let serial = ref 0

let info browser : Lane.client_info =
  incr serial;
  let raw = Printf.sprintf "00000000-0000-4000-8000-%012d" !serial in
  let client_id =
    match Lane.client_id_of_string raw with
    | Ok id -> id
    | Error error -> fail error
  in
  { client_id; browser; version = "1.0"; engine_version = "155.0.1" }
;;

let payload = `Assoc [ "ok", `Bool true; "data", `String "the answer" ]

(* Under the mock clock a take window only passes when the clock is moved,
   so registering a client is a take whose window this function passes. *)
let connect ~sw ~clock browser =
  let client = info browser in
  let registered =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Lane.take_command ~client_info:client ~window_sec:window_s)
  in
  Eio_mock.Clock.set_time clock (Eio.Time.now clock +. window_s);
  (match Eio.Promise.await_exn registered with
   | Ok None -> ()
   | Ok (Some _) -> fail "a fresh client was handed a command nobody issued"
   | Error error -> fail error);
  Eio.Switch.on_release sw (fun () -> ignore (Lane.disconnect_client ~client_id:client.client_id));
  client
;;

let live client =
  match Lane.resolve_target (Lane.Live_route (Some client.Lane.client_id)) with
  | Ok target -> target
  | Error error -> fail (Lane.selection_error_code error)
;;

let with_lane f =
  Eio_mock.Backend.run
  @@ fun () ->
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 0.0;
  Time_compat.set_clock (clock :> float Eio.Time.clock_ty Eio.Resource.t);
  Eio.Switch.run
  @@ fun sw -> f ~sw ~clock
;;

let test_an_answer_delivered_as_the_timeout_passed_is_the_answer () =
  with_lane
  @@ fun ~sw ~clock ->
  let client = connect ~sw ~clock Lane.Firefox in
  let issued =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Lane.issue_for ~target:(live client) ~verb:Lane.Tabs_list ~timeout_sec:window_s)
  in
  let command =
    match Lane.take_command ~client_info:client ~window_sec:window_s with
    | Ok (Some command) -> command
    | Ok None -> fail "the issued command was not handed to its client"
    | Error error -> fail error
  in
  (* The timeout passes first: the timer's wake-up is queued. The answer
     then arrives, queuing the issuer's wake-up behind it. *)
  Eio_mock.Clock.set_time clock (Eio.Time.now clock +. window_s);
  (match Lane.deliver_result ~client_id:client.client_id ~id:command.id ~payload with
   | Ok () -> ()
   | Error error -> fail error);
  match Eio.Promise.await_exn issued with
  | Ok (Lane.Answered value) -> check bool "the delivered answer is the answer" true (value = payload)
  | Ok Lane.Timed_out -> fail "an answer delivered as the timeout passed was dropped"
  | Ok (Lane.Lane_absent | Lane.Refused _ | Lane.Rejected_before_effect _) | Error _ ->
    fail "the issue ended before any answer could arrive"
;;

let test_a_command_taken_as_the_window_passed_is_delivered () =
  with_lane
  @@ fun ~sw ~clock ->
  let client = connect ~sw ~clock Lane.Firefox in
  (* The client is waiting for a command with nothing queued; its window
     passes first, then a command is issued. *)
  let taken =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Lane.take_command ~client_info:client ~window_sec:window_s)
  in
  Eio_mock.Clock.set_time clock (Eio.Time.now clock +. window_s);
  let issued =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Lane.issue_for ~target:(live client) ~verb:Lane.Tabs_list ~timeout_sec:(window_s *. 10.0))
  in
  let command =
    match Eio.Promise.await_exn taken with
    | Ok (Some command) -> command
    | Ok None -> fail "the command issued as the window passed was consumed and dropped"
    | Error error -> fail error
  in
  (match Lane.deliver_result ~client_id:client.client_id ~id:command.id ~payload with
   | Ok () -> ()
   | Error error -> fail error);
  match Eio.Promise.await_exn issued with
  | Ok (Lane.Answered value) -> check bool "the issuer got its answer" true (value = payload)
  | Ok (Lane.Timed_out | Lane.Lane_absent | Lane.Refused _ | Lane.Rejected_before_effect _) | Error _ ->
    fail "the issuer did not get the answer to the command its client took"
;;

let test_an_automation_answer_that_arrived_as_the_timeout_passed_stands () =
  with_lane
  @@ fun ~sw ~clock ->
  let answer, arrive = Eio.Promise.create () in
  Lane.install_automation_executor
    (Some (fun _verb -> Lane.Answered (Eio.Promise.await answer)));
  let issued =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Lane.issue_automation ~verb:Lane.Tabs_list ~timeout_sec:window_s)
  in
  Eio_mock.Clock.set_time clock (Eio.Time.now clock +. window_s);
  Eio.Promise.resolve arrive payload;
  match Eio.Promise.await_exn issued with
  | Lane.Answered value -> check bool "the executor's answer is the answer" true (value = payload)
  | Lane.Timed_out -> fail "an automation answer that arrived as the timeout passed was dropped"
  | Lane.Lane_absent | Lane.Refused _ | Lane.Rejected_before_effect _ ->
    fail "the issue ended before the executor answered"
;;

let () =
  Alcotest.run
    "browser lane watched work"
    [ ( "what arrived as the window passed stands"
      , [ test_case
            "an answer delivered as the timeout passed is the answer"
            `Quick
            test_an_answer_delivered_as_the_timeout_passed_is_the_answer
        ; test_case
            "a command taken as the window passed is delivered"
            `Quick
            test_a_command_taken_as_the_window_passed_is_delivered
        ; test_case
            "an automation answer that arrived as the timeout passed stands"
            `Quick
            test_an_automation_answer_that_arrived_as_the_timeout_passed_stands
        ] )
    ]
;;
