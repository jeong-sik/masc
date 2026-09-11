open Alcotest
module Lane = Browser_lane
let serial = ref 0
let info browser : Lane.client_info =
  incr serial;
  let raw = Printf.sprintf "00000000-0000-4000-8000-%012d" !serial in
  let client_id = match Lane.client_id_of_string raw with Ok id -> id | Error error -> fail error in
  {client_id; browser; version="1.0"; engine_version="155.0.1"}
let target id = match Lane.resolve_target ~lane_name:"live" ~client_id:(Some id) with
  | Ok value -> value | Error error -> fail error
let with_clients f = Eio_main.run (fun env ->
  Time_compat.set_clock (Eio.Stdenv.clock env);
  Eio.Switch.run (fun sw ->
    let connect browser =
      let client = info browser in
      ignore (Lane.take_command ~client_info:client ~window_sec:0.001);
      Eio.Switch.on_release sw (fun () -> ignore (Lane.disconnect_client ~client_id:client.client_id));
      client in
    f sw connect))
let take client = match Lane.take_command ~client_info:client ~window_sec:1. with
  | Ok (Some command) -> command | _ -> fail "client did not receive its command"
let payload name = `Assoc ["ok", `Bool true; "data", `String name]
let answered promise expected = match Eio.Promise.await promise with
  | Ok (Lane.Answered value) -> check bool "owned response" true (value = payload expected)
  | _ -> fail "request did not receive its owned response"
let test_colliding_tabs_are_isolated () = with_clients (fun sw connect ->
  let firefox = connect Lane.Firefox and zen = connect Lane.Zen in
  check bool "multiple clients require selection" true
    (Lane.resolve_target ~lane_name:"live" ~client_id:None = Error "ambiguous_browser_clients");
  let result = Eio.Fiber.fork_promise ~sw (fun () -> Lane.issue_for
    ~target:(target firefox.client_id)
    ~verb:(Lane.Page_interact {tab_id=1; expected_url=None; action=Lane.Click "#button"}) ~timeout_sec:1.) in
  check bool "Zen cannot consume Firefox's tab-1 click" true
    (Lane.take_command ~client_info:zen ~window_sec:0.01 = Ok None);
  let command = take firefox in
  check bool "another client's result cannot settle Firefox" true
    (Lane.deliver_result ~client_id:zen.client_id ~id:command.id ~payload:(payload "wrong")
     = Error "request_not_owned_by_client");
  ignore (Lane.deliver_result ~client_id:firefox.client_id ~id:command.id ~payload:(payload "firefox"));
  answered result "firefox")
let test_single_and_stale_selection () = with_clients (fun _ connect ->
  let old = connect Lane.Firefox in
  check bool "one live client auto-resolves" true
    (Result.is_ok (Lane.resolve_target ~lane_name:"live" ~client_id:None));
  let pinned = target old.client_id in
  ignore (Lane.disconnect_client ~client_id:old.client_id);
  ignore (connect Lane.Zen);
  check bool "old identity never selects new single client" true
    (Lane.resolve_target ~lane_name:"live" ~client_id:(Some old.client_id) = Error "client_not_connected");
  check bool "captured target also stays disconnected" true
    (Lane.issue_for ~target:pinned ~verb:Lane.Tabs_list ~timeout_sec:0.1 = Lane.Rejected_before_effect "client_not_connected");
  check bool "retired native identity cannot re-register" true
    (Lane.take_command ~client_info:old ~window_sec:0.001 = Error "client_disconnected"))
let test_expired_resolved_target_is_pre_dispatch () = with_clients (fun _ connect ->
  let info = connect Lane.Firefox in
  let pinned = target info.client_id in
  let client = match pinned with Lane.Live_client client -> client | Lane.Automation -> fail "expected live target" in
  (* Expire the captured target between resolution and issue, without sleeps
     or a clock-dependent scheduling race. No command has been dispatched. *)
  client.connected_until <- Monotonic_deadline.after ~seconds:0.;
  let answer = Lane.issue_for ~target:pinned
    ~verb:(Lane.Page_interact {tab_id=1;expected_url=Some "https://example.org";
      action=Lane.Scroll {x=0;y=120}}) ~timeout_sec:1. in
  check bool "expiry after target resolution is proven pre-effect" true
    (answer = Lane.Rejected_before_effect "client_not_connected");
  check int "no waiter was installed" 0 (Hashtbl.length client.waiters);
  check bool "no command was enqueued" true (Eio.Stream.take_nonblocking client.commands = None))
let test_timed_out_queue_is_not_executed () = with_clients (fun _ connect ->
  let client = connect Lane.Firefox in
  check bool "unconsumed action times out" true
    (Lane.issue_for ~target:(target client.client_id)
      ~verb:(Lane.Page_interact {tab_id=1; expected_url=None; action=Lane.Scroll {x=0;y=10}})
      ~timeout_sec:0.001 = Lane.Timed_out);
  check bool "later poll drops timed-out queued action" true
    (Lane.take_command ~client_info:client ~window_sec:0.002 = Ok None))
let test_disconnect_releases_waiter () = with_clients (fun sw connect ->
  let client = connect Lane.Zen in
  let result = Eio.Fiber.fork_promise ~sw (fun () -> Lane.issue_for
    ~target:(target client.client_id) ~verb:Lane.Tabs_list ~timeout_sec:1.) in
  let command = take client in
  ignore (Lane.disconnect_client ~client_id:client.client_id);
  (match Eio.Promise.await result with
   | Ok (Lane.Answered (`Assoc fields)) -> check bool "disconnect is visible" true
      (List.assoc_opt "ok" fields = Some (`Bool false))
   | _ -> fail "disconnect left waiter blocked");
  check bool "late result refused" true
    (Result.is_error (Lane.deliver_result ~client_id:client.client_id ~id:command.id ~payload:(payload "late"))))
let test_sources_and_live_policy () = with_clients (fun _ connect ->
  let client = connect Lane.Firefox in
  check bool "automation rejects live identity" true
    (Lane.resolve_target ~lane_name:"automation" ~client_id:(Some client.client_id) = Error "client_id_requires_live");
  check bool "unknown source is refused" true
    (Lane.resolve_target ~lane_name:"other" ~client_id:None = Error "unknown_lane");
  check bool "missing transport UUID rejected" true (Result.is_error (Lane.client_id_of_string ""));
  List.iter (fun verb -> match Lane.issue_for ~target:(target client.client_id) ~verb ~timeout_sec:0.1 with
    | Lane.Rejected_before_effect _ -> () | _ -> fail "live session/navigation must be rejected before effect")
    [Lane.Page_goto {url="https://example.org";tab_id=None}; Lane.Session_open {headless=None}];
  Lane.install_automation_executor None;
  check bool "automation still needs its native executor" true
    (Lane.issue ~lane_name:"automation" ~verb:Lane.Tabs_list ~timeout_sec:0.1 = Lane.Lane_absent))

let test_optional_document_preserves_existing_work () = with_clients (fun sw connect ->
  let info = connect Lane.Firefox in
  let selected = target info.client_id in
  let primary = Eio.Fiber.fork_promise ~sw (fun () ->
    Lane.issue_for ~target:selected ~verb:Lane.Tabs_list ~timeout_sec:1.) in
  let primary_command = take info in
  let client = match selected with Lane.Live_client client -> client | Lane.Automation -> fail "live target expected" in
  check bool "optional observation refuses while primary request waits" true
    (Lane.issue_document_if_idle ~target:selected ~tab_id:1 ~timeout_sec:1.
       = Lane.Refused "optional_document_observation_busy");
  check int "primary waiter remains owned" 1 (Hashtbl.length client.waiters);
  check int "optional observation queued nothing" 0 (Eio.Stream.length client.commands);
  ignore (Lane.deliver_result ~client_id:info.client_id ~id:primary_command.id ~payload:(payload "primary"));
  answered primary "primary";
  let observation = Eio.Fiber.fork_promise ~sw (fun () ->
    Lane.issue_document_if_idle ~target:selected ~tab_id:1 ~timeout_sec:1.) in
  let command = take info in
  check bool "source uses the existing page.read transport" true
    (Yojson.Safe.Util.(command.verb_json |> member "verb") = `String "page.read");
  check bool "only the optional read asks for HTML" true
    (Yojson.Safe.Util.(command.verb_json |> member "args" |> member "includeHtml") = `Bool true);
  ignore (Lane.deliver_result ~client_id:info.client_id ~id:command.id
    ~payload:(`Assoc ["ok", `Bool true; "data", `Assoc ["documentId", `String "document"]]));
  (match Eio.Promise.await observation with
   | Ok (Lane.Answered json) ->
     check string "actual native client is carried with source" (Lane.client_id_to_string info.client_id)
       Yojson.Safe.Util.(json |> member "data" |> member "clientId" |> to_string)
   | _ -> fail "idle optional document did not complete");
  check int "optional waiter was released" 0 (Hashtbl.length client.waiters))

let () = run "browser client routing" ["ownership", [
  test_case "optional document preserves existing work" `Quick test_optional_document_preserves_existing_work;
  test_case "colliding tab IDs and spoofed results" `Quick test_colliding_tabs_are_isolated;
  test_case "single selection and stale identity" `Quick test_single_and_stale_selection;
  test_case "resolved target expires before dispatch" `Quick test_expired_resolved_target_is_pre_dispatch;
  test_case "expired queued actions do not execute" `Quick test_timed_out_queue_is_not_executed;
  test_case "disconnect releases pending caller" `Quick test_disconnect_releases_waiter;
  test_case "source and live command policy" `Quick test_sources_and_live_policy]]
