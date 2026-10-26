(* This standalone fixture explicitly enables new Browser work. *)
let () = Browser_lane.install_activity_observer (Some (fun _ -> Browser_lane.Enabled))

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
  { client_id; browser; version = "1.0"; transport = Browser_lane.Web_extension; engine_version = "155.0.1" ;space=None}
;;

let payload = `Assoc [ "ok", `Bool true; "data", `String "the answer" ]

(* Under the mock clock a take window only passes when the clock is moved,
   so registering a client is a take whose window this function passes. *)
let connect ?(transport=Lane.Web_extension) ~sw ~clock browser =
  let client = { (info browser) with transport } in
  let registered =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Lane.take_command ~client_info:client ~window_sec:window_s)
  in
  Eio_mock.Clock.set_time clock (Eio.Time.now clock +. window_s);
  (match Eio.Promise.await_exn registered with
   | Ok None -> ()
   | Ok (Some _) -> fail "a fresh client was handed a command nobody issued"
   | Error refusal -> fail (Lane.registration_refusal_to_wire refusal));
  Eio.Switch.on_release sw (fun () -> ignore (Lane.disconnect_client ~client_id:client.client_id));
  client
;;

let live client =
  match Lane.resolve_target ~verb:Lane.Tabs_list (Lane.Live_route (Some client.Lane.client_id)) with
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
      Lane.issue_for_actor ~actor:None ~target:(live client) ~verb:Lane.Tabs_list ~timeout_sec:window_s)
  in
  let command =
    match Lane.take_command ~client_info:client ~window_sec:window_s with
    | Ok (Some command) -> command
    | Ok None -> fail "the issued command was not handed to its client"
    | Error refusal -> fail (Lane.registration_refusal_to_wire refusal)
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
      Lane.issue_for_actor ~actor:None ~target:(live client) ~verb:Lane.Tabs_list ~timeout_sec:(window_s *. 10.0))
  in
  let command =
    match Eio.Promise.await_exn taken with
    | Ok (Some command) -> command
    | Ok None -> fail "the command issued as the window passed was consumed and dropped"
    | Error refusal -> fail (Lane.registration_refusal_to_wire refusal)
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

let native_click = Lane.Page_interact {tab_id=1;frame_path=[];
  expected_url=Some "https://example.test/";action=Lane.Click "#save"}

let expect_answer promise = match Eio.Promise.await_exn promise with
  | Ok (Lane.Answered value) -> check bool "original result" true (value=payload)
  | Ok (Lane.Timed_out|Lane.Lane_absent|Lane.Refused _|Lane.Rejected_before_effect _) | Error _ ->
      fail "executor-owned native input lost its result"

let take_owned client = match Lane.take_command ~client_info:client ~window_sec:window_s with
  | Ok (Some command) -> command
  | Ok None | Error _ -> fail "expected the original queued command"

let test_ego_input_outlives_poll_lease () = with_lane @@ fun ~sw ~clock ->
  let info=connect ~transport:Lane.Ego_task_space ~sw ~clock Lane.Ego_lite in
  let target=live info in
  let client=match target with Lane.Live_client c -> c | Lane.Automation|Lane.Stagehand -> fail "live" in
  let issued=Eio.Fiber.fork_promise ~sw (fun () ->
    Lane.issue_for_actor ~actor:None ~target ~verb:native_click ~timeout_sec:window_s) in
  let command=take_owned info in
  client.liveness <- Lane.Polled (Monotonic_deadline.after ~seconds:0.);
  Eio_mock.Clock.set_time clock (Eio.Time.now clock +. Lane.lane_connected_window_sec +. window_s);
  check bool "running native work keeps its original connection" true
    (List.exists (fun (c:Lane.client_info) -> c.client_id=info.client_id) (Lane.active_clients ()));
  (match Lane.deliver_result ~client_id:info.client_id ~id:command.id ~payload with
   | Ok () -> () | Error detail -> fail detail);
  expect_answer issued;
  check int "settlement releases execution ownership" 0 (Hashtbl.length client.executor_work);
  check bool "delivery renews idle connection" true (Lane.connected client);
  client.liveness <- Lane.Polled (Monotonic_deadline.after ~seconds:0.);
  Eio_mock.Clock.set_time clock (Eio.Time.now clock +. Lane.lane_connected_window_sec +. window_s);
  ignore (Lane.active_clients ());
  check bool "idle expired connection still retires" true client.closed

let test_queued_native_work_is_not_liveness () = with_lane @@ fun ~sw ~clock ->
  let info=connect ~transport:Lane.Ego_task_space ~sw ~clock Lane.Ego_lite in
  let target=live info in
  let client=match target with Lane.Live_client c -> c | Lane.Automation|Lane.Stagehand -> fail "live" in
  let issued=Eio.Fiber.fork_promise ~sw (fun () ->
    Lane.issue_for_actor ~actor:None ~target ~verb:native_click ~timeout_sec:window_s) in
  (* Consume the queue without an authenticated client poll: no execution owner. *)
  ignore (Eio.Stream.take client.commands);
  client.liveness <- Lane.Polled (Monotonic_deadline.after ~seconds:0.);
  Eio_mock.Clock.set_time clock (Eio.Time.now clock +. Lane.lane_connected_window_sec +. window_s);
  ignore (Lane.active_clients ());
  check bool "queued work cannot hold a dead client alive" true client.closed;
  ignore (Eio.Promise.await_exn issued);
  check int "retirement releases executor bookkeeping" 0 (Hashtbl.length client.executor_work)

let test_native_input_cancellation_releases_owner () = with_lane @@ fun ~sw ~clock ->
  let info=connect ~transport:Lane.Ego_task_space ~sw ~clock Lane.Ego_lite in
  let target=live info in
  let client=match target with Lane.Live_client c -> c | Lane.Automation|Lane.Stagehand -> fail "live" in
  let started,start=Eio.Promise.create () in
  let issued=Eio.Fiber.fork_promise ~sw (fun () -> Eio.Cancel.sub (fun context ->
    Eio.Promise.resolve start context;
    Lane.issue_for_actor ~actor:None ~target ~verb:native_click ~timeout_sec:window_s)) in
  ignore (take_owned info);
  Eio.Cancel.cancel (Eio.Promise.await started) Exit;
  (match Eio.Promise.await issued with
   | Error (Eio.Cancel.Cancelled _) -> ()
   | Error exn -> fail (Printexc.to_string exn)
   | Ok _ -> fail "cancelled native input returned as successful");
  check int "cancellation removes waiter" 0 (Hashtbl.length client.waiters);
  check int "cancellation removes executor ownership" 0 (Hashtbl.length client.executor_work)

let test_running_native_disconnect_is_final () = with_lane @@ fun ~sw ~clock ->
  let info=connect ~transport:Lane.Ego_task_space ~sw ~clock Lane.Ego_lite in
  let target=live info in
  let client=match target with Lane.Live_client c -> c | Lane.Automation|Lane.Stagehand -> fail "live" in
  let issued=Eio.Fiber.fork_promise ~sw (fun () ->
    Lane.issue_for_actor ~actor:None ~target ~verb:native_click ~timeout_sec:window_s) in
  let command=take_owned info in
  client.liveness <- Lane.Polled (Monotonic_deadline.after ~seconds:0.);
  ignore (Lane.disconnect_client ~client_id:info.client_id);
  (match Eio.Promise.await_exn issued with
   | Ok (Lane.Answered (`Assoc fields)) ->
       check bool "original caller sees disconnection" true
         (List.assoc_opt "ok" fields=Some (`Bool false)
          && List.assoc_opt "error" fields=Some (`String "client_disconnected"))
   | Ok (Lane.Answered (`Null|`Bool _|`Int _|`Intlit _|`Float _|`String _|`List _)
        | Lane.Timed_out|Lane.Lane_absent|Lane.Refused _|Lane.Rejected_before_effect _) | Error _ ->
       fail "disconnect did not settle original caller as disconnected");
  check int "disconnect removes original waiter" 0 (Hashtbl.length client.waiters);
  check bool "disconnected client is absent from active inventory" false
    (List.exists (fun (c:Lane.client_info) -> c.client_id=info.client_id) (Lane.active_clients ()));
  check bool "explicit disconnect overrides running work" true client.closed;
  check int "disconnect releases running ownership" 0 (Hashtbl.length client.executor_work);
  check bool "late result cannot revive the original client" true
    (Result.is_error (Lane.deliver_result ~client_id:info.client_id ~id:command.id ~payload));
  check bool "same client ID cannot register again" true
    (Lane.take_command ~client_info:info ~window_sec:window_s=Error Lane.Client_retired)

let test_only_native_ego_inputs_delegate_waits () =
  let verify transport verb expected =
    check bool "transport-specific execution policy" true (Lane.live_reply_policy transport verb=expected) in
  List.iter (fun verb ->
    verify Lane.Ego_task_space verb Lane.Executor_owned;
    verify Lane.Web_extension verb Lane.Reply_window;
    verify Lane.Webdriver_bidi verb Lane.Reply_window)
    [Lane.Page_goto {url="https://example.test/";tab_id=Some 1};
     Lane.Page_act (Lane.Action.Open_tab "https://example.test/");
     Lane.Page_act (Lane.Action.On_tab {tab_id=1;frame_path=[];interaction=Lane.Action.Reload})];
  verify Lane.Ego_task_space (Lane.Page_act (Lane.Action.On_tab {tab_id=1;frame_path=[];interaction=Lane.Action.Back})) Lane.Reply_window;
  verify Lane.Ego_task_space native_click Lane.Executor_owned;
  verify Lane.Web_extension native_click Lane.Reply_window;
  verify Lane.Webdriver_bidi native_click Lane.Reply_window;
  let guarded=Lane.Page_interact {tab_id=1;frame_path=[];expected_url=None;action=Lane.Scroll {x=0;y=1}} in
  verify Lane.Ego_task_space guarded Lane.Reply_window

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
        ; test_case "native Ego input keeps ownership beyond a poll lease" `Quick test_ego_input_outlives_poll_lease
        ; test_case "queued native input cannot preserve a disconnected client" `Quick test_queued_native_work_is_not_liveness
        ; test_case "cancelling native input releases its ownership" `Quick test_native_input_cancellation_releases_owner
        ; test_case "running native input cannot override explicit disconnect" `Quick test_running_native_disconnect_is_final
        ; test_case "only native Ego input delegates wait ownership" `Quick test_only_native_ego_inputs_delegate_waits
        ] )
    ]
;;
