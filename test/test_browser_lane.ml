(* This standalone fixture explicitly enables new Browser work. *)
let () = Browser_lane.install_activity_observer (Some (fun _ -> Browser_lane.Enabled))

open Alcotest
module Lane = Browser_lane
let serial = ref 0
let info ?(transport=Browser_lane.Web_extension) browser : Lane.client_info =
  incr serial;
  let raw = Printf.sprintf "00000000-0000-4000-8000-%012d" !serial in
  let client_id = match Lane.client_id_of_string raw with Ok id -> id | Error error -> fail error in
  {client_id; browser; version="1.0"; transport; engine_version="155.0.1";space=None}
let target id = match Lane.resolve_target ~verb:Lane.Tabs_list (Lane.Live_route (Some id)) with
  | Ok value -> value | Error error -> fail (Lane.selection_error_code error)
let with_clients f = Eio_main.run (fun env ->
  Time_compat.set_clock (Eio.Stdenv.clock env);
  Eio.Switch.run (fun sw ->
    let connect ?transport browser =
      let client = info ?transport browser in
      ignore (Lane.take_command ~client_info:client ~window_sec:0.001);
      Eio.Switch.on_release sw (fun () -> ignore (Lane.disconnect_client ~client_id:client.client_id));
      client in
    f sw connect))
let take client = match Lane.take_command ~client_info:client ~window_sec:1. with
  | Ok (Some command) -> command | _ -> fail "client did not receive its command"
let payload name = `Assoc ["ok", `Bool true; "data", `String name]
let answered promise expected = match Eio.Promise.await promise with
  | Ok (Ok (Lane.Answered value)) -> check bool "owned response" true (value = payload expected)
  | _ -> fail "request did not receive its owned response"
let test_colliding_tabs_are_isolated () = with_clients (fun sw connect ->
  let firefox = connect Lane.Firefox and zen = connect Lane.Zen in
  check bool "multiple clients require selection" true
    (Lane.resolve_target ~verb:Lane.Tabs_list (Lane.Live_route None)
     = Error (Lane.Ambiguous_clients [firefox.client_id; zen.client_id]));
  let result = Eio.Fiber.fork_promise ~sw (fun () -> Lane.issue_for_actor ~actor:None
    ~target:(target firefox.client_id)
    ~verb:(Lane.Page_interact {frame_path=[];tab_id=1; expected_url=None; action=Lane.Click "#button"}) ~timeout_sec:1.) in
  check bool "Zen cannot consume Firefox's tab-1 click" true
    (Lane.take_command ~client_info:zen ~window_sec:0.01 = Ok None);
  let command = take firefox in
  check bool "another client's result cannot settle Firefox" true
    (Lane.deliver_result ~client_id:zen.client_id ~id:command.id ~payload:(payload "wrong")
     = Error "request_not_owned_by_client");
  ignore (Lane.deliver_result ~client_id:firefox.client_id ~id:command.id ~payload:(payload "firefox"));
  answered result "firefox")
(* A result that arrives after its caller stopped waiting is refused, and the
   next command's caller gets only its own result: each issue has its own id. *)
let test_late_result_reaches_no_other_waiter () = with_clients (fun sw connect ->
  let client = connect Lane.Firefox in
  let first = Eio.Fiber.fork_promise ~sw (fun () -> Lane.issue_for_actor ~actor:None
    ~target:(target client.client_id) ~verb:Lane.Tabs_list ~timeout_sec:0.05) in
  let late = take client in
  check bool "the first caller stops waiting" true
    (match Eio.Promise.await first with Ok (Ok Lane.Timed_out) -> true | _ -> false);
  let second = Eio.Fiber.fork_promise ~sw (fun () -> Lane.issue_for_actor ~actor:None
    ~target:(target client.client_id) ~verb:Lane.Tabs_list ~timeout_sec:1.) in
  let current = take client in
  check bool "the late result is refused" true
    (Lane.deliver_result ~client_id:client.client_id ~id:late.id ~payload:(payload "late")
     = Error "request_not_owned_by_client");
  ignore (Lane.deliver_result ~client_id:client.client_id ~id:current.id ~payload:(payload "second"));
  answered second "second")
let test_single_and_stale_selection () = with_clients (fun _ connect ->
  check bool "no connected browser is its own answer" true
    (Lane.resolve_target ~verb:Lane.Tabs_list (Lane.Live_route None) = Error Lane.No_live_client);
  let old = connect Lane.Firefox in
  check bool "one live client auto-resolves" true
    (Result.is_ok (Lane.resolve_target ~verb:Lane.Tabs_list (Lane.Live_route None)));
  let pinned = target old.client_id in
  ignore (Lane.disconnect_client ~client_id:old.client_id);
  ignore (connect Lane.Zen);
  check bool "old identity never selects new single client" true
    (Lane.resolve_target ~verb:Lane.Tabs_list (Lane.Live_route (Some old.client_id))
     = Error (Lane.Selected_client_disconnected old.client_id));
  check bool "captured target also stays disconnected" true
    (Lane.issue_for_actor ~actor:None ~target:pinned ~verb:Lane.Tabs_list ~timeout_sec:0.1
     = Error (Lane.Selected_client_disconnected old.client_id));
  check bool "retired native identity cannot re-register" true
    (Lane.take_command ~client_info:old ~window_sec:0.001 = Error Lane.Client_retired))
(* A connection the worker runs itself is ended by that worker, not by the
   no-poll window, which counts system sleep on macOS. The worker holds its
   client while it is connected; after the window passes the next poll
   retires a polled client and still serves the held one, and neither a poll
   nor a delivered result turns the held client back into a timed one. *)
let test_worker_held_client_outlives_the_poll_window () = with_clients (fun sw connect ->
  let polled = connect ~transport:Lane.Webdriver_bidi Lane.Firefox
  and held = connect ~transport:Lane.Webdriver_bidi Lane.Zen
  and extension = connect Lane.Firefox in
  let live (info : Lane.client_info) = match target info.client_id with
    | Lane.Live_client client -> client
    | Lane.Automation | Lane.Stagehand -> fail "expected live target" in
  let polled_client = live polled and held_client = live held in
  let is_held () = match held_client.liveness with Lane.Worker_held -> true | Lane.Polled _ -> false in
  check bool "the worker holds its own connected client" true (Lane.hold_client ~client_id:held.client_id = Ok ());
  check bool "no worker runs a browser extension, so it is not held" true
    (Result.is_error (Lane.hold_client ~client_id:extension.client_id));
  polled_client.liveness <- Lane.Polled (Monotonic_deadline.after ~seconds:0.);
  Hashtbl.replace polled_client.executor_work "running" Lane.Interaction_running;
  check bool "a client past its window is not held, even while its request runs" true
    (Result.is_error (Lane.hold_client ~client_id:polled.client_id));
  Hashtbl.remove polled_client.executor_work "running";
  check bool "a polled client whose window passed is retired on its next poll" true
    (Lane.take_command ~client_info:polled ~window_sec:0.001 = Error Lane.Client_retired);
  check bool "the held client's next poll still serves it" true
    (Lane.take_command ~client_info:held ~window_sec:0.001 = Ok None);
  check bool "and leaves it held" true (is_held ());
  let result = Eio.Fiber.fork_promise ~sw (fun () -> Lane.issue_for_actor ~actor:None
    ~target:(target held.client_id) ~verb:Lane.Tabs_list ~timeout_sec:1.) in
  let command = take held in
  ignore (Lane.deliver_result ~client_id:held.client_id ~id:command.id ~payload:(payload "held"));
  answered result "held";
  check bool "a delivered result leaves it held" true (is_held ());
  check bool "the retired polled client is no longer connected" true
    (List.map (fun (client : Lane.client_info) -> client.client_id) (Lane.connected_clients ())
     |> List.sort compare = List.sort compare [held.client_id; extension.client_id]);
  check bool "a retired client cannot be held" true
    (Result.is_error (Lane.hold_client ~client_id:polled.client_id)))
let test_expired_resolved_target_is_pre_dispatch () = with_clients (fun _ connect ->
  let info = connect Lane.Firefox in
  let pinned = target info.client_id in
  let client = match pinned with Lane.Live_client client -> client | Lane.Automation | Lane.Stagehand -> fail "expected live target" in
  (* Expire the captured target between resolution and issue, without sleeps
     or a clock-dependent scheduling race. No command has been dispatched. *)
  client.liveness <- Lane.Polled (Monotonic_deadline.after ~seconds:0.);
  let answer = Lane.issue_for_actor ~actor:None ~target:pinned
    ~verb:(Lane.Page_interact {frame_path=[];tab_id=1;expected_url=Some "https://example.org";
      action=Lane.Scroll {x=0;y=120}}) ~timeout_sec:1. in
  check bool "expiry after target resolution is the same selection failure" true
    (answer = Error (Lane.Selected_client_disconnected info.client_id));
  check int "no waiter was installed" 0 (Hashtbl.length client.waiters);
  check bool "no command was enqueued" true (Eio.Stream.take_nonblocking client.commands = None))
let test_timed_out_queue_is_not_executed () = with_clients (fun _ connect ->
  let client = connect Lane.Firefox in
  check bool "unconsumed action times out" true
    (Lane.issue_for_actor ~actor:None ~target:(target client.client_id)
      ~verb:(Lane.Page_interact {frame_path=[];tab_id=1; expected_url=None; action=Lane.Scroll {x=0;y=10}})
      ~timeout_sec:0.001 = Ok Lane.Timed_out);
  check bool "later poll drops timed-out queued action" true
    (Lane.take_command ~client_info:client ~window_sec:0.002 = Ok None))
let test_queued_time_reduces_the_original_window () = with_clients (fun sw connect ->
  let client = connect Lane.Firefox in
  let selected = target client.client_id in
  let result = Eio.Fiber.fork_promise ~sw (fun () ->
    Lane.issue_for_actor ~actor:None ~target:selected ~verb:Lane.Tabs_list ~timeout_sec:2.) in
  Time_compat.sleep 0.15;
  let command = take client in
  (match Lane.live_request_window ~client_id:client.client_id ~id:command.id with
   | Lane.Live_waiting_until deadline ->
       let remaining = Monotonic_deadline.remaining_seconds deadline in
       check bool "the queued wait consumed the original window" true (remaining > 0. && remaining < 1.95)
   | Lane.No_live_waiter | Lane.Live_executor_owned -> fail "the original waiter disappeared");
  ignore (Lane.deliver_result ~client_id:client.client_id ~id:command.id ~payload:(payload "queued"));
  answered result "queued";
  check bool "a settled request has no remaining authority" true
    (Lane.live_request_window ~client_id:client.client_id ~id:command.id = Lane.No_live_waiter))
let test_disconnect_releases_waiter () = with_clients (fun sw connect ->
  let client = connect Lane.Zen in
  let result = Eio.Fiber.fork_promise ~sw (fun () -> Lane.issue_for_actor ~actor:None
    ~target:(target client.client_id) ~verb:Lane.Tabs_list ~timeout_sec:1.) in
  let command = take client in
  ignore (Lane.disconnect_client ~client_id:client.client_id);
  (match Eio.Promise.await result with
   | Ok (Ok (Lane.Answered (`Assoc fields))) -> check bool "disconnect is visible" true
      (List.assoc_opt "ok" fields = Some (`Bool false))
   | _ -> fail "disconnect left waiter blocked");
  check bool "late result refused" true
    (Result.is_error (Lane.deliver_result ~client_id:client.client_id ~id:command.id ~payload:(payload "late"))))
let test_sources_and_live_policy () = with_clients (fun _ connect ->
  let client = connect Lane.Firefox in
  check bool "missing transport UUID rejected" true (Result.is_error (Lane.client_id_of_string ""));
  (match Lane.issue_for_actor ~actor:None ~target:(target client.client_id) ~verb:(Lane.Session_open {headless=None}) ~timeout_sec:0.1 with
   | Ok (Lane.Rejected_before_effect _) -> () | _ -> fail "a live session must be rejected before effect");
  (* Navigation is BiDi work on a tab that connection opened; the extension is
     refused as a selection, with nothing queued. *)
  check bool "extension navigation is refused as a selection" true
    (Lane.issue_for_actor ~actor:None ~target:(target client.client_id) ~verb:(Lane.Page_goto {url="https://example.org";tab_id=Some 2})
       ~timeout_sec:0.1
     = Error (Lane.Transport_unsupported
         {client_id=client.client_id; transport=client.transport; capability=Lane.Tab_navigation}));
  Lane.install_automation_executor None;
  check bool "automation still needs its native executor" true
    (Lane.issue_automation ~verb:Lane.Tabs_list ~timeout_sec:0.1 = Lane.Lane_absent))

(* One live verb for each capability, so a capability added to the lane has
   to be given a verb here before this file's table checks pass. *)
let viewport : Lane.Pointer.viewport =
  {document_id="observed-page"; width=800.; height=600.; scroll_x=0.; scroll_y=0.}
let point : Lane.Pointer.point = {x=0.5;y=0.5}
let interact action = Lane.Page_interact {frame_path=[];tab_id=2; expected_url=Some "https://example.org"; action}
let verb_asking_for : Lane.live_capability -> Lane.verb = Lane.(function
  | Tab_listing -> Tabs_list
  | Text_read -> Page_read {tab_id=Some 2; max_chars=None}
  | Document_source -> Page_document {tab_id=2}
  | Element_inventory -> Page_elements {tab_id=Some 2;filter={within=None;selector=None}}
  | Viewport_capture -> Page_capture {tab_id=2;options=None}
  | Scene_read -> Page_scene {tab_id=2; max_chars=1000; view=Content; scope=None}
  | Accessibility_snapshot -> Page_snapshot {tab_id=2; max_chars=1000; scope=Snapshot_viewport}
  | Native_workflow ->
      (match Native_workflow.of_json (`Assoc ["tabId",`Int 2;"expectedUrl",`String "https://example.org";
        "steps",`List [];"maxChars",`Int 1000]) with
       | Ok request -> Page_native_workflow request | Error detail -> fail detail)
  | Snapshot_target_input -> interact (Click_target (Target_ref 12))
  | Dom_interaction -> interact (Click "#button")
  | Point_click -> interact (Click_at {point;viewport;button=Pointer.Primary})
  | Point_scroll -> interact (Scroll_at {point;viewport;x=0;y=120})
  | Trusted_hover -> interact (Hover_at {point;viewport})
  | Trusted_drag -> interact (Drag {from=point;to_=point;viewport;via=[];duration_ms=0})
  | Trusted_double_click -> interact (Double_click_at {point;viewport})
  | Trusted_button_click -> interact (Click_at {point;viewport;button=Pointer.Secondary})
  | Viewport_resize -> interact (Set_viewport (Fit {width=800;height=600}))
  | Touch_input -> interact (Tap_at {point;viewport})
  | Trusted_keyboard -> interact (Type_text {document_id=viewport.document_id;text="hello"})
      | Browser_zoom -> interact (Set_zoom {factor=1.5})
  | Tab_history -> Page_act (Action.On_tab {tab_id=2;frame_path=[];interaction=Action.Back})
  | Tab_closing -> Page_act (Action.On_tab {tab_id=2;frame_path=[];interaction=Action.Close_tab})
  | Tab_navigation -> Page_goto {url="https://example.test/next";tab_id=Some 2}
  | Tab_activation -> interact Activate_tab
  | Tab_creation -> Page_act (Action.Open_tab "https://example.test/new")
  | Dialog_answer -> Page_act (Action.On_tab {tab_id=2;frame_path=[];interaction=Action.Dismiss_dialog})
  | Frame_read -> Page_context {tab_id=2;frame_path=["#frame"];mode=`Frames}
  | Operator_handoff -> Page_act (Action.Control Action.Hand_off)
    | Page_management -> Page_act (Action.Control (Action.Adopt_tab {tab_id=2;label=None}))
  | Download_listing -> Page_downloads {tab_id=2}
  | File_upload -> Page_act (Action.On_tab {tab_id=2;frame_path=[];interaction=Action.Upload {target=Action.File_input "#file";paths=["/tmp/note.txt"]}}))

let capability = testable
  (fun ppf value -> Format.pp_print_string ppf (Lane.live_capability_to_wire value)) ( = )

let test_transport_table () =
  let unserved transport = List.filter (fun capability ->
    not (Lane.live_transport_serves transport capability)) Lane.all_of_live_capability in
  check (list capability) "the extension has no pointer the browser trusts"
    Lane.[Accessibility_snapshot; Snapshot_target_input; Native_workflow; Trusted_hover; Trusted_drag; Trusted_double_click; Trusted_button_click; Touch_input; Trusted_keyboard; Viewport_resize; Tab_history; Tab_navigation; Tab_closing; Tab_creation; Dialog_answer; Frame_read; Operator_handoff; Page_management; Download_listing; File_upload] (unserved Lane.Web_extension);
  check (list capability) "the BiDi peer has no ego snapshot, browser zoom, hand-off, download list or upload"
    Lane.[Accessibility_snapshot; Snapshot_target_input; Native_workflow; Browser_zoom; Operator_handoff; Page_management; Download_listing; File_upload] (unserved Lane.Webdriver_bidi);
  check (list capability) "the ego connection has no document source, touch, zoom, resize or frame reads"
    Lane.[Document_source; Touch_input; Browser_zoom; Viewport_resize; Frame_read]
    (unserved Lane.Ego_task_space);
  check bool "native Ego activation uses SDK execution ownership" true
    (Lane.ego_reply_policy (Lane.Page_interact {tab_id=1;frame_path=[];
      expected_url=Some "https://example.org/";action=Lane.Activate_tab})=Lane.Executor_owned);
  List.iter (fun capability ->
    check bool (Lane.live_capability_to_wire capability ^ " is reachable on some connection") true
      (Lane.live_transports_serving capability <> []);
    check bool (Lane.live_capability_to_wire capability ^ " is what its verb asks for") true
      (Lane.live_capability (verb_asking_for capability) = Some capability))
    Lane.all_of_live_capability

(* Every transport and capability: served work reaches that connection's
   queue, and unserved work is answered before anything is queued. *)
let test_unserved_work_queues_nothing () = with_clients (fun sw connect ->
  let extension = connect Lane.Firefox in
  let bidi = { (info Lane.Firefox) with transport=Lane.Webdriver_bidi } in
  ignore (Lane.take_command ~client_info:bidi ~window_sec:0.001);
  Eio.Switch.on_release sw (fun () -> ignore (Lane.disconnect_client ~client_id:bidi.client_id));
  let ego = { (info Lane.Ego_lite) with transport=Lane.Ego_task_space;space=Some {id=51;name="fixture Space"} } in
  ignore (Lane.take_command ~client_info:ego ~window_sec:0.001);
  Eio.Switch.on_release sw (fun () -> ignore (Lane.disconnect_client ~client_id:ego.client_id));
  List.iter (fun (info : Lane.client_info) ->
    let selected = target info.client_id in
    let client = match selected with Lane.Live_client client -> client
      | Lane.Automation | Lane.Stagehand -> fail "expected live target" in
    List.iter (fun capability ->
      let verb = verb_asking_for capability in
      let name = Lane.live_transport_to_string info.transport ^ " " ^ Lane.live_capability_to_wire capability in
      if Lane.live_transport_serves info.transport capability then begin
        let result = Eio.Fiber.fork_promise ~sw (fun () ->
          Lane.issue_for_actor ~actor:None ~target:selected ~verb ~timeout_sec:1.) in
        let command = take info in
        check bool (name ^ " reaches the connection") true (command.verb_json = Lane.verb_json verb);
        (match Lane.live_reply_policy info.transport verb,
            Lane.live_request_window ~client_id:info.client_id ~id:command.id with
         | Lane.Reply_window, Lane.Live_waiting_until deadline ->
             check bool (name ^ " keeps the issuer's remaining window") true
               (Monotonic_deadline.remaining_seconds deadline > 0.)
         | Lane.Executor_owned, Lane.Live_executor_owned -> ()
         | Lane.Reply_window, (Lane.No_live_waiter | Lane.Live_executor_owned)
         | Lane.Executor_owned, (Lane.No_live_waiter | Lane.Live_waiting_until _) ->
             failf "%s lost its reply policy in the queue" name);
        ignore (Lane.deliver_result ~client_id:info.client_id ~id:command.id ~payload:(payload name));
        answered result name
      end else begin
        check bool (name ^ " is refused as a selection") true
          (Lane.issue_for_actor ~actor:None ~target:selected ~verb ~timeout_sec:1.
             = Error (Lane.Transport_unsupported
                 {client_id=info.client_id; transport=info.transport; capability}));
        check int (name ^ " left no waiter") 0 (Hashtbl.length client.waiters);
        check int (name ^ " queued no command") 0 (Eio.Stream.length client.commands)
      end) Lane.all_of_live_capability)
    [extension; bidi; ego];
  (* The optional document read asks the same table. The extension and BiDi
     serve it, so on BiDi it reaches that connection's queue. *)
  let bidi_target = target bidi.client_id in
  let document = Eio.Fiber.fork_promise ~sw (fun () ->
    Lane.issue_document_if_idle ~target:bidi_target ~tab_id:2 ~timeout_sec:1.) in
  let command = take bidi in
  check bool "the optional document read reaches the BiDi connection" true
    (command.verb_json = Lane.verb_json (Lane.Page_document {tab_id=2}));
  ignore (Lane.deliver_result ~client_id:bidi.client_id ~id:command.id ~payload:(payload "document"));
  answered document "document")

(* A successful answer states its connection through one function: a live
   browser's client ID and transport, a null client for the server's own
   browsers. Where an answer is rebuilt around those fields, a value the page
   or browser supplied under the same names is dropped. *)
let test_answers_state_their_connection () = with_clients (fun sw connect ->
  let extension = connect Lane.Firefox in
  let bidi = { (info Lane.Firefox) with transport=Lane.Webdriver_bidi } in
  ignore (Lane.take_command ~client_info:bidi ~window_sec:0.001);
  Eio.Switch.on_release sw (fun () -> ignore (Lane.disconnect_client ~client_id:bidi.client_id));
  let stated (client : Lane.client_info) = Lane.target_connection_fields (target client.client_id) in
  let expected (client : Lane.client_info) transport =
    ["clientId", `String (Lane.client_id_to_string client.client_id); "transport", `String transport] in
  check bool "an extension answer names its client and its transport" true
    (stated extension = expected extension "web_extension");
  check bool "a BiDi answer names its own" true (stated bidi = expected bidi "webdriver_bidi");
  check bool "the server's own browsers have no client and no transport" true
    (Lane.target_connection_fields Lane.Automation = ["clientId", `Null]
     && Lane.target_connection_fields Lane.Stagehand = ["clientId", `Null]);
  let supplied = ["transport", `String "carrier_pigeon"; "tabId", `Int 2; "clientId", `String "forged";
    "browserSpace",`Assoc ["id",`Int 999;"name",`String "forged"]] in
  check bool "a value supplied under those names is replaced, not kept beside the route's" true
    (Lane.with_connection_fields (target bidi.client_id) supplied = expected bidi "webdriver_bidi" @ ["tabId", `Int 2]);
  check bool "also for the server's own browsers" true
    (Lane.with_connection_fields Lane.Automation supplied = ["clientId", `Null; "tabId", `Int 2]);
  (* A holder that keeps only checked fields reads back exactly what was
     stated, and refuses half a live connection. *)
  List.iter (fun (name, written) ->
    check bool (name ^ " reads back as written") true
      (Lane.connection_fields_of_json (written @ ["tabId", `Int 2]) = Ok written))
    ["an extension connection", stated extension; "a BiDi connection", stated bidi;
     "the server's own browser", Lane.target_connection_fields Lane.Automation;
     "an answer that states no connection", []];
  let client_id = `String (Lane.client_id_to_string bidi.client_id) in
  List.iter (fun (name, fields, expected) ->
    check (result reject string) name (Error expected) (Lane.connection_fields_of_json fields))
    ["a client without its transport", ["clientId", client_id], "client_without_transport";
     "a transport without its client", ["transport", `String "webdriver_bidi"], "invalid_connection_fields";
     "a transport on the server's own browser",
     ["clientId", `Null; "transport", `String "webdriver_bidi"], "invalid_connection_fields";
     "a transport no connection has",
     ["clientId", client_id; "transport", `String "carrier_pigeon"], "unsupported_browser_transport";
     "a client that is not an ID",
     ["clientId", `String "forged"; "transport", `String "webdriver_bidi"], "invalid_client_id";
     "a client of another JSON type", ["clientId", `Int 7], "invalid_connection_fields"];
  (* The live optional document read attaches the same fields. The automation
     lane's keeps the session ID its own observer wrote, which the document
     source requires. *)
  let document = Eio.Fiber.fork_promise ~sw (fun () ->
    Lane.issue_document_if_idle ~target:(target bidi.client_id) ~tab_id:2 ~timeout_sec:1.) in
  let command = take bidi in
  ignore (Lane.deliver_result ~client_id:bidi.client_id ~id:command.id
    ~payload:(`Assoc ["ok", `Bool true; "data", `Assoc ["html", `String "<html></html>"; "transport", `String "forged"]]));
  match Eio.Promise.await document with
  | Ok (Ok (Lane.Answered (`Assoc fields))) ->
    check bool "the document answer states the BiDi connection once" true
      (List.assoc_opt "data" fields
       = Some (`Assoc (expected bidi "webdriver_bidi" @ ["html", `String "<html></html>"])))
  | _ -> fail "the document read did not answer")

let test_unsupported_message_names_the_serving_transport () =
  let client_id = (info Lane.Firefox).client_id in
  check string "hover on the extension points at BiDi and ego"
    "live_transport_unsupported: this browser is connected over web_extension, which does not serve \
     trusted_hover; a webdriver_bidi or ego_task_space connection does"
    (Lane.selection_error_message (Lane.Transport_unsupported
       {client_id; transport=Web_extension; capability=Trusted_hover}));
  check string "browser zoom on BiDi points at the extension"
    "live_transport_unsupported: this browser is connected over webdriver_bidi, which does not serve \
     browser_zoom; a web_extension connection does"
    (Lane.selection_error_message (Lane.Transport_unsupported
       {client_id; transport=Webdriver_bidi; capability=Browser_zoom}))

let test_optional_document_preserves_existing_work () = with_clients (fun sw connect ->
  let info = connect Lane.Firefox in
  let selected = target info.client_id in
  let primary = Eio.Fiber.fork_promise ~sw (fun () ->
    Lane.issue_for_actor ~actor:None ~target:selected ~verb:Lane.Tabs_list ~timeout_sec:1.) in
  let primary_command = take info in
  let client = match selected with Lane.Live_client client -> client | Lane.Automation | Lane.Stagehand -> fail "live target expected" in
  check bool "optional observation refuses while primary request waits" true
    (Lane.issue_document_if_idle ~target:selected ~tab_id:1 ~timeout_sec:1.
       = Ok (Lane.Refused "optional_document_observation_busy"));
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
   | Ok (Ok (Lane.Answered json)) ->
     check string "actual native client is carried with source" (Lane.client_id_to_string info.client_id)
       Yojson.Safe.Util.(json |> member "data" |> member "clientId" |> to_string)
   | _ -> fail "idle optional document did not complete");
  check int "optional waiter was released" 0 (Hashtbl.length client.waiters))

let test_inventory_does_not_prune () = with_clients (fun sw connect ->
  let info = connect Lane.Firefox in
  let selected = target info.client_id in
  let client = match selected with Lane.Live_client client -> client
    | Lane.Automation | Lane.Stagehand -> fail "expected live target" in
  let pending = Eio.Fiber.fork_promise ~sw (fun () ->
    Lane.issue_for_actor ~actor:None ~target:selected ~verb:Lane.Tabs_list ~timeout_sec:1.) in
  ignore (take info);
  client.liveness <- Lane.Polled (Monotonic_deadline.after ~seconds:0.);
  check bool "expired client is not counted" true
    (Lane.inventory_observation Lane.Lane_name.Live = {Lane.activity=Enabled;backend=Lane.Live_clients 0});
  check bool "inventory did not retire client" false client.closed;
  check int "inventory did not finish waiting request" 1 (Hashtbl.length client.waiters);
  ignore (Lane.disconnect_client ~client_id:info.client_id);
  match Eio.Promise.await pending with
  | Ok (Ok (Lane.Answered _)) -> ()
  | _ -> fail "explicit disconnect must still settle the request")

let test_duplicate_result_after_lost_ack_is_accepted () = with_clients (fun sw connect ->
  let info = connect Lane.Firefox in
  let pending = Eio.Fiber.fork_promise ~sw (fun () ->
    Lane.issue_for_actor ~actor:None ~target:(target info.client_id) ~verb:Lane.Tabs_list ~timeout_sec:1.) in
  let command = take info in
  let result = payload "delivered" in
  check bool "first result is delivered" true
    (Lane.deliver_result ~client_id:info.client_id ~id:command.id ~payload:result = Ok ());
  answered pending "delivered";
  check bool "same result retry is acknowledged" true
    (Lane.deliver_result ~client_id:info.client_id ~id:command.id ~payload:result = Ok ());
  check bool "same ID cannot acknowledge a changed result" true
    (Lane.deliver_result ~client_id:info.client_id ~id:command.id ~payload:(payload "changed")
     = Error "result_id_reused_with_different_payload"))

let activity_ok = function Ok x -> x | Error _ -> failwith "unexpected refusal"
let test_agent_activity () = Browser_lane.install_activity_observer (Some (fun _ -> Browser_lane.Enabled));
 Eio_main.run @@ fun env -> Time_compat.set_clock (Eio.Stdenv.clock env); Eio.Switch.run @@ fun sw ->
 let info : Browser_lane.client_info = {client_id=activity_ok (Browser_lane.client_id_of_string "11111111-1111-4111-8111-111111111118");browser=Firefox;version="fixture";engine_version="fixture";transport=Webdriver_bidi;space=None} in
 let client=activity_ok (Browser_lane.register info) in
 let viewport : Browser_lane.Pointer.viewport = {document_id="owned";width=100.;height=100.;scroll_x=0.;scroll_y=0.} in
 let point : Browser_lane.Pointer.point = {x=0.5;y=0.5} in
 let verb=Browser_lane.Page_interact {frame_path=[];tab_id=1;expected_url=Some "https://example.org/";action=Hover_at {point;viewport}} in
 let queued=Eio.Fiber.fork_promise ~sw (fun () -> Browser_lane.issue_for_actor ~actor:(Some "fixture-keeper") ~target:(Live_client client) ~verb ~timeout_sec:20.) in
 let rec admitted () = match Browser_lane.client_interactions client with [] -> Eio.Fiber.yield ();admitted () | _::_ -> () in admitted ();
 let activity=Browser_lane.client_interactions client in
 (match activity with [work] -> assert(work.actor=Some "fixture-keeper" && work.phase=Interaction_queued) | _ -> failwith "missing queued activity");
 let issued=Option.get (activity_ok (Browser_lane.take_command ~client_info:info ~window_sec:0.1)) in
 (match issued.verb_json with `Assoc fields -> assert(List.assoc_opt "actor" fields=Some (`String "fixture-keeper"))|_ -> assert false);
 (match Browser_lane.client_interactions client with [work] -> assert(work.phase=Interaction_running) | _ -> failwith "missing running activity");
 ignore(activity_ok (Browser_lane.deliver_result ~client_id:info.client_id ~id:issued.id ~payload:(`Assoc ["ok",`Bool true;"data",`Assoc []])));
 ignore(Eio.Promise.await_exn queued);
 assert(Browser_lane.client_interactions client=[]);
 let active=Eio.Fiber.fork_promise ~sw (fun () -> Browser_lane.issue_for_actor ~actor:(Some "fixture-keeper") ~target:(Live_client client) ~verb ~timeout_sec:20.) in
 let rec admitted () = match Browser_lane.client_interactions client with [] -> Eio.Fiber.yield ();admitted () | _::_ -> () in admitted ();
 assert(List.length (Browser_lane.client_interactions client)=1);
 ignore(activity_ok (Browser_lane.disconnect_client ~client_id:info.client_id));
 ignore(Eio.Promise.await_exn active);
 assert(Browser_lane.client_interactions client=[]);
 ()

let test_read_activity () =
 Browser_lane.install_activity_observer (Some (fun _ -> Browser_lane.Enabled));
 Eio_main.run @@ fun env -> Time_compat.set_clock (Eio.Stdenv.clock env); Eio.Switch.run @@ fun sw ->
 let info : Lane.client_info = {client_id=activity_ok (Lane.client_id_of_string "11111111-1111-4111-8111-111111111119");
   browser=Ego_lite;version="fixture";engine_version="fixture";transport=Ego_task_space;space=Some ({id=51;name="fixture Space"} : Browser_lane.ego_space)} in
 let client=activity_ok (Lane.register info) in
 let run actor verb payload =
   let pending=Eio.Fiber.fork_promise ~sw (fun () -> Lane.issue_for_actor ~actor:(Some actor)
     ~target:(Live_client client) ~verb ~timeout_sec:20.) in
   let issued=Option.get (activity_ok (Lane.take_command ~client_info:info ~window_sec:1.)) in
   (match Lane.client_interactions client with
    | [work] -> check bool "reads expose their exact caller and optional tab" true
        (work.actor=Some actor && work.tab_id=Lane.activity_scope verb && work.phase=Lane.Interaction_running)
    | _ -> fail "read activity missing or duplicated");
   ignore (activity_ok (Lane.deliver_result ~client_id:info.client_id ~id:issued.id ~payload));
   ignore (Eio.Promise.await_exn pending);
   check int "returned reads are no longer running" 0 (List.length (Lane.client_interactions client)) in
 run "keeper/reader" (Lane.Page_snapshot {tab_id=7;max_chars=1000;scope=Lane.Snapshot_viewport})
   (`Assoc ["ok",`Bool true;"data",`Assoc []]);
 run "operator" Lane.Tabs_list (`Assoc ["ok",`Bool true;"data",`List []]);
 let _,settled=Lane.activity_for info in
 check int "operator observation does not erase the Keeper's last activity" 2 (List.length settled);
 let last=List.find (fun (row : Lane.settled_activity) -> row.work.actor=Some "keeper/reader") settled in
 check bool "snapshot has a settled returned receipt" true
   (last.work.action="page.snapshot" && last.work.tab_id=Some 7 && last.outcome=Lane.Activity_returned);
 run "keeper/reader" (Lane.Page_read {tab_id=Some 7;max_chars=Some 1000})
   (`Assoc ["ok",`Bool false;"error",`String "uncertain"]);
 let _,settled=Lane.activity_for info in
 let last=List.find (fun (row : Lane.settled_activity) -> row.work.actor=Some "keeper/reader") settled in
 check bool "failed observation is not projected as completion" true (last.outcome=Lane.Activity_unknown);
 check bool "activity wire roundtrips tab-less scope" true
   (List.for_all (fun row -> Lane.settled_activity_of_json (Lane.settled_activity_json row)=Ok row) settled);
 let valid=Lane.interaction_activity_json last.work in
 (match valid with
  | `Assoc fields -> List.iter (fun invalid ->
      check bool "malformed activity cannot become an observed caller or phase" true
        (Result.is_error (Lane.interaction_activity_of_json invalid)))
      [`Assoc (("actor",`String "spoof")::fields);
       `Assoc (("phase",`String "finished")::List.remove_assoc "phase" fields);
       `Assoc (("requestId",`String "")::List.remove_assoc "requestId" fields);
       `Assoc (("tabId",`Int (-1))::List.remove_assoc "tabId" fields)]
  | `Null|`Bool _|`Int _|`Intlit _|`Float _|`String _|`List _ -> fail "activity is not an object");
 ignore (activity_ok (Lane.disconnect_client ~client_id:info.client_id))

let test_space_identity_cannot_take_queued_work () = with_clients (fun sw _ ->
  let space : Lane.ego_space = {id=51;name="SDK Space"} in
  let original={ (info Lane.Ego_lite) with transport=Lane.Ego_task_space;space=Some space} in
  ignore (Lane.take_command ~client_info:original ~window_sec:0.);
  Eio.Switch.on_release sw (fun () -> ignore (Lane.disconnect_client ~client_id:original.client_id));
  let changed={original with space=Some {space with id=52}} in
  let renamed={original with space=Some {space with name="Renamed Space"}} in
  let result=Eio.Fiber.fork_promise ~sw (fun () -> Lane.issue_for_actor ~actor:None
    ~target:(target original.client_id) ~verb:(Lane.Page_read {tab_id=Some 1;max_chars=None}) ~timeout_sec:1.) in
  Eio.Fiber.yield ();
  check bool "another Space cannot register under an existing client UUID" true
    (match Lane.register changed with Error Lane.Client_identity_changed -> true | Ok _|Error _ -> false);
  check bool "another Space cannot consume the original queued read" true
    (Lane.take_command ~client_info:changed ~window_sec:0. = Error Lane.Client_identity_changed);
  let command=take renamed in
  ignore (Lane.deliver_result ~client_id:original.client_id ~id:command.id ~payload:(payload "original Space"));
  answered result "original Space")

let test_space_connection_context () =
  let space : Lane.ego_space = {id=51;name="SDK Space"} in
  let json=Lane.ego_space_to_json space in
  check bool "Space identity roundtrips" true (Lane.ego_space_of_json json=Ok space);
  List.iter (fun value -> check bool "malformed Space context is refused" true
    (Result.is_error (Lane.ego_space_of_json value)))
    [`Null;`Assoc ["id",`Int (-1);"name",`String "x"];
     `Assoc ["id",`Int max_int;"name",`String "x"];
     `Assoc ["id",`Int 51;"name",`String " "];
     `Assoc ["id",`Int 51;"id",`Int 52;"name",`String "x"];
     `Assoc ["id",`Int 51;"name",`String "x";"ownership",`String "agent"]];
  let client_id=(info Lane.Ego_lite).client_id in
  let fields=Lane.live_connection_fields ~client_id ~transport:Lane.Ego_task_space ~space:(Some space) in
  check bool "an Ego connection preserves its bound Space" true
    (Lane.connection_fields_of_json fields=Ok fields);
  List.iter (fun fields -> check bool "Space context cannot cross transports or omit its binding" true
    (Result.is_error (Lane.connection_fields_of_json fields)))
    [List.remove_assoc "browserSpace" fields;
     ("browserSpace",json)::fields;
     ("transport",`String "webdriver_bidi")::List.remove_assoc "transport" fields;
     ["browserSpace",json];["clientId",`Null;"browserSpace",json]]

let test_native_control_wait_contract () =
  let status=Lane.Action.Control Lane.Action.Space_status in
  check bool "Space metadata has a closed no-argument action" true
    (Lane.Action.parse (Lane.Action.to_json status)=Ok status);
  check bool "Space metadata refuses control or tab arguments" true
    (Result.is_error (Lane.Action.parse (`Assoc ["action",`String "space_status";"tabId",`Int 1])));
  check bool "Space metadata uses the SDK reply clock" true
    (Lane.ego_reply_policy (Lane.Page_act status)=Lane.Executor_owned);
  check string "Space status activity names its metadata operation" "space_status" (Lane.activity_name (Lane.Page_act status));
  let finish=Lane.Action.Control (Lane.Action.Finish_space (Lane.Action.Keep_labels ["p2"])) in
  check bool "Space completion retains requested permanent labels" true
    (Lane.Action.parse (Lane.Action.to_json finish)=Ok finish);
  check bool "Space completion uses native execution and explicit live identity" true
    (Lane.ego_reply_policy (Lane.Page_act finish)=Lane.Executor_owned
      && Lane.live_capability (Lane.Page_act finish)=Some Lane.Operator_handoff);
  check (option int) "completion has Space scope" None (Lane.activity_scope (Lane.Page_act finish));
  check string "completion activity" "finish_space" (Lane.activity_name (Lane.Page_act finish));
  let keep_all=Lane.Action.Control (Lane.Action.Finish_space Lane.Action.Keep_all) in
  check bool "native all policy round-trips without enumerating labels" true
    (Lane.Action.parse (Lane.Action.to_json keep_all)=Ok keep_all);
  check bool "omission keeps default empty-label policy" true
    (Lane.Action.parse (`Assoc ["action",`String "finish_space"])
      =Ok (Lane.Action.Control (Lane.Action.Finish_space (Lane.Action.Keep_labels []))));
  List.iter (fun fields -> check bool "invalid retention policy is refused" true
    (Result.is_error (Lane.Action.parse (`Assoc (("action",`String "finish_space")::fields)))))
    [["keepPages",`Null];["keepPages",`String "ALL"];["keepPages",`String "p1"];
     ["keepPages",`List [`String " "]];
     ["keepPages",`List [`String "p1";`String "p1"]];["tabId",`Int 1]];
  let parse fields=Lane.Action.parse (`Assoc (("action",`String "wait_for_control")::fields)) in
  let defaults=Lane.Action.Control (Lane.Action.Wait_for_control {interval_ms=None;timeout_ms=None}) in
  check bool "missing wait options keep SDK defaults" true (parse []=Ok defaults);
  let action=Result.get_ok (parse ["controlOptions",`Assoc ["interval",`Float 0.5;"timeout",`Int 100000]]) in
  check bool "positive SDK milliseconds retain their values" true
    (Lane.Action.parse (Lane.Action.to_json action)=Ok action);
  let verb=Lane.Page_act action in
  check bool "native wait owns its reply clock" true (Lane.ego_reply_policy verb=Lane.Executor_owned);
  check string "wait activity names the Space operation" "wait_for_control" (Lane.activity_name verb);
  check (option int) "wait has Space scope" None (Lane.activity_scope verb);
  check bool "other browser backends refuse Space waits" true
    (Option.is_some (Lane.automation_refusal verb) && not (Lane.verb_allowed_on_stagehand verb)
      && not (Lane.live_transport_serves Lane.Web_extension Lane.Operator_handoff)
      && not (Lane.live_transport_serves Lane.Webdriver_bidi Lane.Operator_handoff));
  List.iter (fun fields -> check bool "invalid wait input fails before dispatch" true
    (Result.is_error (parse fields)))
    [ ["tabId",`Int 1];["controlOptions",`Null];
      ["controlOptions",`Assoc ["interval",`Int 0]];
      ["controlOptions",`Assoc ["timeout",`Float nan]];
      ["controlOptions",`Assoc ["timeout",`Int (-1)]];
      ["controlOptions",`Assoc ["timeout",`Int 1;"timeout",`Int 2]];
      ["controlOptions",`Assoc ["claim",`Bool true]];
      ["controlOptions",`Assoc [];"controlOptions",`Assoc []] ]

let test_native_page_management_contract () =
  let parse action fields=Lane.Action.parse (`Assoc (("action",`String action)::fields)) in
  List.iter (fun action ->
    let encoded=Lane.Action.to_json action in
    check bool "Page management retains its exact tab and label" true (Lane.Action.parse encoded=Ok action);
    let verb=Lane.Page_act action in
    check (option int) "activity belongs to the observed tab" (Some 2) (Lane.activity_scope verb);
    check bool "native SDK owns management execution" true (Lane.ego_reply_policy verb=Lane.Executor_owned);
    check bool "only Ego serves Page management" true
      (Lane.live_capability verb=Some Lane.Page_management
        && Lane.live_transport_serves Ego_task_space Page_management
        && not (Lane.live_transport_serves Webdriver_bidi Page_management)
        && not (Lane.live_transport_serves Web_extension Page_management)
        && not (Lane.verb_allowed_on_automation verb) && not (Lane.verb_allowed_on_stagehand verb)))
    [Lane.Action.Control (Adopt_tab {tab_id=2;label=None});Control (Adopt_tab {tab_id=2;label=Some "login"});Control (Release_tab 2)];
  List.iter (fun (action,fields) -> check bool "invalid lifecycle input is refused" true
    (Result.is_error (parse action fields)))
    ["adopt_tab",[];"adopt_tab",["tabId",`Int (-1)];
     "adopt_tab",["tabId",`Int 2;"pageLabel",`String " "];
     "adopt_tab",["tabId",`Int 2;"framePath",`List []];
     "adopt_tab",["tabId",`Int 2;"tabId",`Int 3];
     "release_tab",["tabId",`Int 2;"pageLabel",`String "login"]]

let () = run "browser client routing" ["ownership", [
  test_case "native Page management retains exact tab binding" `Quick test_native_page_management_contract;
  test_case "native Space wait keeps SDK ownership and options" `Quick test_native_control_wait_contract;
  test_case "reads retain caller, scope and settled results" `Quick test_read_activity;
  test_case "agent activity follows queue ownership and cleanup" `Quick test_agent_activity;
  test_case "each live transport serves its part of the table" `Quick test_transport_table;
  test_case "unserved live work is refused before queue admission" `Quick test_unserved_work_queues_nothing;
  test_case "an unserved request names the transport that serves it" `Quick test_unsupported_message_names_the_serving_transport;
  test_case "inventory observes without pruning a pending client" `Quick test_inventory_does_not_prune;
  test_case "optional document preserves existing work" `Quick test_optional_document_preserves_existing_work;
  test_case "colliding tab IDs and spoofed results" `Quick test_colliding_tabs_are_isolated;
  test_case "duplicate result after lost acknowledgement" `Quick test_duplicate_result_after_lost_ack_is_accepted;
  test_case "a late result reaches no other waiter" `Quick test_late_result_reaches_no_other_waiter;
  test_case "single selection and stale identity" `Quick test_single_and_stale_selection;
  test_case "resolved target expires before dispatch" `Quick test_expired_resolved_target_is_pre_dispatch;
  test_case "a worker-held client outlives the poll window" `Quick test_worker_held_client_outlives_the_poll_window;
  test_case "expired queued actions do not execute" `Quick test_timed_out_queue_is_not_executed;
  test_case "queue time consumes the issuer's window" `Quick test_queued_time_reduces_the_original_window;
  test_case "disconnect releases pending caller" `Quick test_disconnect_releases_waiter;
  test_case "source and live command policy" `Quick test_sources_and_live_policy;
  test_case "a replacement Space cannot take queued work" `Quick test_space_identity_cannot_take_queued_work;
  test_case "Space context follows its authoritative connection" `Quick test_space_connection_context;
  test_case "answers state their connection" `Quick test_answers_state_their_connection]]
