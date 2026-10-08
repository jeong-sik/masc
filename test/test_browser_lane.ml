(* This standalone fixture explicitly enables new Browser work. *)
let () = Browser_lane.install_activity_observer (Some (fun _ -> Browser_lane.Enabled))

open Alcotest
module Lane = Browser_lane
let serial = ref 0
let info browser : Lane.client_info =
  incr serial;
  let raw = Printf.sprintf "00000000-0000-4000-8000-%012d" !serial in
  let client_id = match Lane.client_id_of_string raw with Ok id -> id | Error error -> fail error in
  {client_id; browser; version="1.0"; transport=Browser_lane.Web_extension; engine_version="155.0.1"}
let target id = match Lane.resolve_target ~verb:Lane.Tabs_list (Lane.Live_route (Some id)) with
  | Ok value -> value | Error error -> fail (Lane.selection_error_code error)
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
  | Ok (Ok (Lane.Answered value)) -> check bool "owned response" true (value = payload expected)
  | _ -> fail "request did not receive its owned response"
let test_colliding_tabs_are_isolated () = with_clients (fun sw connect ->
  let firefox = connect Lane.Firefox and zen = connect Lane.Zen in
  check bool "multiple clients require selection" true
    (Lane.resolve_target ~verb:Lane.Tabs_list (Lane.Live_route None)
     = Error (Lane.Ambiguous_clients [firefox.client_id; zen.client_id]));
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
    (Lane.issue_for ~target:pinned ~verb:Lane.Tabs_list ~timeout_sec:0.1
     = Error (Lane.Selected_client_disconnected old.client_id));
  check bool "retired native identity cannot re-register" true
    (Lane.take_command ~client_info:old ~window_sec:0.001 = Error "client_disconnected"))
let test_expired_resolved_target_is_pre_dispatch () = with_clients (fun _ connect ->
  let info = connect Lane.Firefox in
  let pinned = target info.client_id in
  let client = match pinned with Lane.Live_client client -> client | Lane.Automation | Lane.Stagehand -> fail "expected live target" in
  (* Expire the captured target between resolution and issue, without sleeps
     or a clock-dependent scheduling race. No command has been dispatched. *)
  client.connected_until <- Monotonic_deadline.after ~seconds:0.;
  let answer = Lane.issue_for ~target:pinned
    ~verb:(Lane.Page_interact {tab_id=1;expected_url=Some "https://example.org";
      action=Lane.Scroll {x=0;y=120}}) ~timeout_sec:1. in
  check bool "expiry after target resolution is the same selection failure" true
    (answer = Error (Lane.Selected_client_disconnected info.client_id));
  check int "no waiter was installed" 0 (Hashtbl.length client.waiters);
  check bool "no command was enqueued" true (Eio.Stream.take_nonblocking client.commands = None))
let test_timed_out_queue_is_not_executed () = with_clients (fun _ connect ->
  let client = connect Lane.Firefox in
  check bool "unconsumed action times out" true
    (Lane.issue_for ~target:(target client.client_id)
      ~verb:(Lane.Page_interact {tab_id=1; expected_url=None; action=Lane.Scroll {x=0;y=10}})
      ~timeout_sec:0.001 = Ok Lane.Timed_out);
  check bool "later poll drops timed-out queued action" true
    (Lane.take_command ~client_info:client ~window_sec:0.002 = Ok None))
let test_disconnect_releases_waiter () = with_clients (fun sw connect ->
  let client = connect Lane.Zen in
  let result = Eio.Fiber.fork_promise ~sw (fun () -> Lane.issue_for
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
  List.iter (fun verb -> match Lane.issue_for ~target:(target client.client_id) ~verb ~timeout_sec:0.1 with
    | Ok (Lane.Rejected_before_effect _) -> () | _ -> fail "live session/navigation must be rejected before effect")
    [Lane.Page_goto {url="https://example.org";tab_id=None}; Lane.Session_open {headless=None}];
  Lane.install_automation_executor None;
  check bool "automation still needs its native executor" true
    (Lane.issue_automation ~verb:Lane.Tabs_list ~timeout_sec:0.1 = Lane.Lane_absent))

(* One live verb for each capability, so a capability added to the lane has
   to be given a verb here before this file's table checks pass. *)
let viewport : Lane.Pointer.viewport =
  {document_id="observed-page"; width=800.; height=600.; scroll_x=0.; scroll_y=0.}
let point : Lane.Pointer.point = {x=0.5;y=0.5}
let interact action = Lane.Page_interact {tab_id=2; expected_url=Some "https://example.org"; action}
let verb_asking_for : Lane.live_capability -> Lane.verb = Lane.(function
  | Tab_listing -> Tabs_list
  | Text_read -> Page_read {tab_id=Some 2; max_chars=None}
  | Document_source -> Page_document {tab_id=2}
  | Element_inventory -> Page_elements {tab_id=Some 2}
  | Viewport_capture -> Page_capture {tab_id=2}
  | Scene_read -> Page_scene {tab_id=2; max_chars=1000; view=Content; scope=None}
  | Dom_interaction -> interact (Click "#button")
  | Point_click -> interact (Click_at {point;viewport})
  | Point_scroll -> interact (Scroll_at {point;viewport;x=0;y=120})
  | Trusted_hover -> interact (Hover_at {point;viewport})
  | Trusted_drag -> interact (Drag {from=point;to_=point;viewport})
  | Tab_activation -> interact Activate_tab)

let capability = testable
  (fun ppf value -> Format.pp_print_string ppf (Lane.live_capability_to_wire value)) ( = )

let test_transport_table () =
  let unserved transport = List.filter (fun capability ->
    not (Lane.live_transport_serves transport capability)) Lane.all_of_live_capability in
  check (list capability) "the extension has no pointer the browser trusts"
    Lane.[Trusted_hover; Trusted_drag] (unserved Lane.Web_extension);
  check (list capability) "the BiDi peer has no document source, element inventory or tab activation"
    Lane.[Document_source; Element_inventory; Tab_activation] (unserved Lane.Webdriver_bidi);
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
  List.iter (fun (info : Lane.client_info) ->
    let selected = target info.client_id in
    let client = match selected with Lane.Live_client client -> client
      | Lane.Automation | Lane.Stagehand -> fail "expected live target" in
    List.iter (fun capability ->
      let verb = verb_asking_for capability in
      let name = Lane.live_transport_to_string info.transport ^ " " ^ Lane.live_capability_to_wire capability in
      if Lane.live_transport_serves info.transport capability then begin
        let result = Eio.Fiber.fork_promise ~sw (fun () ->
          Lane.issue_for ~target:selected ~verb ~timeout_sec:1.) in
        let command = take info in
        check bool (name ^ " reaches the connection") true (command.verb_json = Lane.verb_json verb);
        ignore (Lane.deliver_result ~client_id:info.client_id ~id:command.id ~payload:(payload name));
        answered result name
      end else begin
        check bool (name ^ " is refused as a selection") true
          (Lane.issue_for ~target:selected ~verb ~timeout_sec:1.
             = Error (Lane.Transport_unsupported
                 {client_id=info.client_id; transport=info.transport; capability}));
        check int (name ^ " left no waiter") 0 (Hashtbl.length client.waiters);
        check int (name ^ " queued no command") 0 (Eio.Stream.length client.commands)
      end) Lane.all_of_live_capability)
    [extension; bidi];
  let bidi_target = target bidi.client_id in
  check bool "the optional document read is refused on BiDi the same way" true
    (Lane.issue_document_if_idle ~target:bidi_target ~tab_id:2 ~timeout_sec:1.
       = Error (Lane.Transport_unsupported
           {client_id=bidi.client_id; transport=Webdriver_bidi; capability=Document_source})))

let test_unsupported_message_names_the_serving_transport () =
  let client_id = (info Lane.Firefox).client_id in
  check string "hover on the extension points at BiDi"
    "live_transport_unsupported: this browser is connected over web_extension, which does not serve \
     trusted_hover; a webdriver_bidi connection does"
    (Lane.selection_error_message (Lane.Transport_unsupported
       {client_id; transport=Web_extension; capability=Trusted_hover}));
  check string "tab activation on BiDi points at the extension"
    "live_transport_unsupported: this browser is connected over webdriver_bidi, which does not serve \
     tab_activation; a web_extension connection does"
    (Lane.selection_error_message (Lane.Transport_unsupported
       {client_id; transport=Webdriver_bidi; capability=Tab_activation}))

let test_optional_document_preserves_existing_work () = with_clients (fun sw connect ->
  let info = connect Lane.Firefox in
  let selected = target info.client_id in
  let primary = Eio.Fiber.fork_promise ~sw (fun () ->
    Lane.issue_for ~target:selected ~verb:Lane.Tabs_list ~timeout_sec:1.) in
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
    Lane.issue_for ~target:selected ~verb:Lane.Tabs_list ~timeout_sec:1.) in
  ignore (take info);
  client.connected_until <- Monotonic_deadline.after ~seconds:0.;
  check bool "expired client is not counted" true
    (Lane.inventory_observation Lane.Lane_name.Live = {Lane.activity=Enabled;backend=Lane.Live_clients 0});
  check bool "inventory did not retire client" false client.closed;
  check int "inventory did not finish waiting request" 1 (Hashtbl.length client.waiters);
  ignore (Lane.disconnect_client ~client_id:info.client_id);
  match Eio.Promise.await pending with
  | Ok (Ok (Lane.Answered _)) -> ()
  | _ -> fail "explicit disconnect must still settle the request")

let () = run "browser client routing" ["ownership", [
  test_case "each live transport serves its part of the table" `Quick test_transport_table;
  test_case "unserved live work is refused before queue admission" `Quick test_unserved_work_queues_nothing;
  test_case "an unserved request names the transport that serves it" `Quick test_unsupported_message_names_the_serving_transport;
  test_case "inventory observes without pruning a pending client" `Quick test_inventory_does_not_prune;
  test_case "optional document preserves existing work" `Quick test_optional_document_preserves_existing_work;
  test_case "colliding tab IDs and spoofed results" `Quick test_colliding_tabs_are_isolated;
  test_case "single selection and stale identity" `Quick test_single_and_stale_selection;
  test_case "resolved target expires before dispatch" `Quick test_expired_resolved_target_is_pre_dispatch;
  test_case "expired queued actions do not execute" `Quick test_timed_out_queue_is_not_executed;
  test_case "disconnect releases pending caller" `Quick test_disconnect_releases_waiter;
  test_case "source and live command policy" `Quick test_sources_and_live_policy]]
