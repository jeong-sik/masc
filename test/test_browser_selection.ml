open Alcotest
module Selection = Masc.Browser_selection
module Lane = Browser_lane
let work session : Selection.work_browser = {activity=Lane.Enabled;registered=true;session;locate=false}
let empty : Selection.snapshot = {live_activity=Lane.Enabled;live_clients=[];
  stagehand=work Lane.Browser_closed;automation=work Lane.Browser_closed}
let client digit transport : Lane.client_info =
  let id="00000000-0000-4000-8000-00000000000" ^ digit in
  let client_id = match Lane.client_id_of_string id with Ok id -> id | Error error -> fail error in
  {client_id;browser=Lane.Firefox;version="fixture";engine_version="fixture";transport}
let route info = Lane.Live_route (Some info.Lane.client_id)
let choose ?(verb=Lane.Tabs_list) ?(bound=false) snapshot = Selection.choose ~verb ~bound ~snapshot Selection.Automatic
let selected (expected : Selection.selected) = function
  | Ok actual -> check bool "selected route and reason" true (actual=expected)
  | Error error -> fail (Selection.error_message error)
let test_connections_and_sessions () =
  let bidi=client "1" Lane.Webdriver_bidi and extension=client "2" Lane.Web_extension in
  let opened={empty with stagehand=work Lane.Browser_open} in
  selected {route=route bidi;reason=Selection.Existing_login} (choose {opened with live_clients=[extension;bidi]});
  selected {route=Lane.Stagehand_route;reason=Selection.Existing_work_session} (choose {opened with live_clients=[extension]});
  selected {route=route extension;reason=Selection.Available_connected_browser} (choose {empty with live_clients=[extension]});
  check bool "registration does not invent an open session" true (choose empty=Error Selection.No_available_browser);
  List.iter (fun session -> check bool "unknown/changing is not open" true
    (choose {empty with stagehand=work session}=Error Selection.No_available_browser))
    [Lane.Browser_unknown;Lane.Browser_changing];
  let second=client "3" Lane.Webdriver_bidi in
  check bool "connected identity ambiguity needs a browser choice" true
    (choose {opened with live_clients=[bidi;second]}=Error (Selection.Ambiguous_browsers [route bidi;route second]));
  check bool "two owned browsers are ambiguous" true
    (choose {opened with automation=work Lane.Browser_open}=
     Error (Selection.Ambiguous_browsers [Lane.Stagehand_route;Lane.Automation_route]))
let test_explicit_binding () =
  check bool "automatic bound request cannot change browser" true (choose ~bound:true empty=Error Selection.Binding_required);
  let explicit=Lane.Live_route (Some (client "1" Lane.Webdriver_bidi).client_id) in
  selected {route=explicit;reason=Selection.Explicit_browser}
    (Selection.choose ~verb:Lane.Tabs_list ~bound:true ~snapshot:empty (Selection.Exact explicit));
  selected {route=explicit;reason=Selection.Explicit_browser}
    (Selection.resolve ~verb:Lane.Tabs_list ~bound:true (Selection.Exact explicit));
  let unnamed=Selection.Exact (Lane.Live_route None) in
  List.iter (fun info ->
    check bool "an unbound live lane cannot adopt a different client's observed tab" true
      (Selection.choose ~verb:(Lane.Page_read {tab_id=Some 0;max_chars=None}) ~bound:true
        ~snapshot:{empty with live_clients=[info]} unnamed=Error Selection.Binding_required))
    [client "1" Lane.Webdriver_bidi;client "2" Lane.Webdriver_bidi];
  check bool "bound live lane requires client identity before runtime observation" true
    (Selection.resolve ~verb:Lane.Tabs_list ~bound:true unnamed=Error Selection.Binding_required);
  selected {route=Lane.Live_route None;reason=Selection.Explicit_browser}
    (Selection.choose ~verb:Lane.Tabs_list ~bound:false ~snapshot:empty unnamed);
  selected {route=Lane.Live_route None;reason=Selection.Explicit_browser}
    (Selection.resolve ~verb:Lane.Tabs_list ~bound:false unnamed);
  check bool "bound automatic selection refuses before observing runtime" true
    (Selection.resolve ~verb:Lane.Tabs_list ~bound:true Selection.Automatic=Error Selection.Binding_required)
let test_work_lifecycle () =
  let open_=Lane.Session_open {headless=None} in
  selected {route=Lane.Stagehand_route;reason=Selection.Preferred_work_browser} (choose ~verb:open_ empty);
  selected {route=Lane.Automation_route;reason=Selection.Compatible_work_browser}
    (choose ~verb:open_ {empty with stagehand={empty.stagehand with registered=false}});
  selected {route=Lane.Automation_route;reason=Selection.Existing_work_session}
    (choose ~verb:open_ {empty with automation=work Lane.Browser_open});
  check bool "opening does not choose among two owned sessions" true
    (choose ~verb:open_ {empty with automation=work Lane.Browser_open;stagehand=work Lane.Browser_open}=
     Error (Selection.Ambiguous_browsers [Lane.Stagehand_route;Lane.Automation_route]));
  selected {route=Lane.Stagehand_route;reason=Selection.Preferred_work_browser} (choose ~verb:Lane.Session_status empty);
  List.iter (fun verb -> check bool "close/goto never create a session" true
    (choose ~verb empty=Error Selection.No_available_browser)) [Lane.Session_close;Lane.Page_goto {url="https://example.org";tab_id=None}]
let test_eligibility () =
  let extension=client "1" Lane.Web_extension in
  let hover=Lane.Page_interact {tab_id=0;expected_url=None;action=Lane.Hover (Lane.Selector "#observed")} in
  check bool "extension cannot be silently selected for trusted hover" true
    (choose ~verb:hover {empty with live_clients=[extension]}=Error Selection.No_available_browser);
  check bool "disabled login is not selected" true
    (choose {empty with live_activity=Lane.Disabled;live_clients=[client "1" Lane.Webdriver_bidi]}=Error Selection.No_available_browser);
  let timing=Lane.Page_interact {tab_id=0;expected_url=None;action=Lane.Drag_to {
    source=Lane.Selector "#from";destination=Lane.Selector "#to";via=[];duration_ms=10}} in
  selected {route=Lane.Automation_route;reason=Selection.Existing_work_session}
    (choose ~verb:timing {empty with stagehand=work Lane.Browser_open;automation=work Lane.Browser_open});
  check bool "bound timing request still requires its exact browser" true
    (choose ~verb:timing ~bound:true {empty with automation=work Lane.Browser_open}=Error Selection.Binding_required);
  let locate=Lane.Page_locate {tab_id=1;instruction=None} in
  let automation=work Lane.Browser_open in
  check bool "a driver without the selected locate consumer is not eligible" true
    (choose ~verb:locate {empty with automation}=Error Selection.No_available_browser);
  selected {route=Lane.Automation_route;reason=Selection.Existing_work_session}
    (choose ~verb:locate {empty with automation={automation with locate=true}});
  let chrome=work Lane.Browser_open in
  check bool "Chrome without a selected model consumer is not eligible" true
    (choose ~verb:locate {empty with stagehand=chrome}=Error Selection.No_available_browser);
  selected {route=Lane.Stagehand_route;reason=Selection.Existing_work_session}
    (choose ~verb:locate {empty with stagehand={chrome with locate=true}});
  check bool "a bound locate cannot switch from its observed browser" true
    (choose ~verb:locate ~bound:true {empty with automation={automation with locate=true}}=Error Selection.Binding_required)
let test_inactive_session_cleanup () =
  List.iter (fun activity ->
    let inactive : Selection.work_browser = {activity;registered=true;session=Lane.Browser_open;locate=false} in
    let sole = {empty with stagehand=inactive} in
    List.iter (fun verb ->
      selected {route=Lane.Stagehand_route;reason=Selection.Existing_work_session}
        (choose ~verb sole);
      check bool "cleanup still refuses ambiguous owned browsers" true
        (choose ~verb {sole with automation=inactive} =
         Error (Selection.Ambiguous_browsers [Lane.Stagehand_route;Lane.Automation_route])))
      [Lane.Session_status;Lane.Session_close];
    List.iter (fun verb -> check bool "inactive owned browser cannot receive new work" true
      (choose ~verb sole=Error Selection.No_available_browser))
      [Lane.Tabs_list;Lane.Page_goto {url="https://example.org";tab_id=None}];
    selected {route=Lane.Automation_route;reason=Selection.Compatible_work_browser}
      (choose ~verb:(Lane.Session_open {headless=None}) sole);
    check bool "closed inactive backend is not a ready status default" true
      (choose ~verb:Lane.Session_status {empty with stagehand={inactive with session=Lane.Browser_closed};
        automation={inactive with session=Lane.Browser_closed}} = Error Selection.No_available_browser);
    check bool "unregistered backend cannot be inspected or closed" true
      (choose ~verb:Lane.Session_close {sole with stagehand={inactive with registered=false}}=
       Error Selection.No_available_browser)) [Lane.Disabled;Lane.Unobserved]
let test_observation_is_not_dispatch () = Eio_main.run (fun _ ->
  let dispatched=ref 0 in
  Lane.install_activity_observer (Some (fun _ -> Lane.Enabled));
  Lane.install_stagehand_executor (Some (fun ~actor:_ _ -> incr dispatched;Lane.Lane_absent));
  Lane.install_server_session_observer Lane.Server_stagehand (Some (fun () -> Lane.Browser_closed));
  Fun.protect ~finally:(fun () -> Lane.install_activity_observer None;
    Lane.install_stagehand_executor None;Lane.install_server_session_observer Lane.Server_stagehand None) (fun () ->
    selected {route=Lane.Stagehand_route;reason=Selection.Preferred_work_browser}
      (Selection.resolve ~verb:(Lane.Session_open {headless=None}) ~bound:false Selection.Automatic);
    check int "selection opens no browser and sends no command" 0 !dispatched;
    check bool "closed remains closed" true (Lane.server_session_observation Lane.Server_stagehand=Lane.Browser_closed)))
let test_wire () =
  List.iter (fun reason -> check bool "typed reason round trip" true
    (Selection.reason_of_wire (Selection.reason_to_wire reason)=Some reason))
    [Selection.Explicit_browser;Existing_login;Existing_work_session;Preferred_work_browser;Compatible_work_browser;Available_connected_browser];
  check bool "unknown selection reason is not defaulted" true (Selection.reason_of_wire "unknown"=None);
  check string "wire gives exact backend identity and reason"
    {|{"lane":"stagehand","clientId":null,"reason":"preferred_work_browser"}|}
    (Selection.to_json {route=Lane.Stagehand_route;reason=Selection.Preferred_work_browser} |> Yojson.Safe.to_string)
let test_bind_admitted_identity () = Eio_main.run (fun env ->
  Time_compat.set_clock (Eio.Stdenv.clock env);
  Lane.install_activity_observer (Some (fun _ -> Lane.Enabled));
  let info=client "1" Lane.Webdriver_bidi in
  Fun.protect ~finally:(fun () -> ignore (Lane.disconnect_client ~client_id:info.client_id);
    Lane.install_activity_observer None) (fun () ->
    ignore (Lane.take_command ~client_info:info ~window_sec:0.001);
    let target=match Lane.resolve_target ~verb:Lane.Tabs_list (Lane.Live_route None) with
      | Ok target -> target | Error _ -> fail "sole connected client was not admitted" in
    let explicit : Selection.selected = {route=Lane.Live_route None;reason=Selection.Explicit_browser} in
    selected {route=route info;reason=Selection.Explicit_browser} (Ok (Selection.bind_target explicit target))))
let () = run "browser selection" ["policy",[
  test_case "connected login and actual owned sessions" `Quick test_connections_and_sessions;
  test_case "exact browser binding" `Quick test_explicit_binding;
  test_case "work session lifecycle" `Quick test_work_lifecycle;
  test_case "capability and activity eligibility" `Quick test_eligibility;
  test_case "inactive owned session inspection and cleanup" `Quick test_inactive_session_cleanup;
  test_case "observation sends no command" `Quick test_observation_is_not_dispatch;
  test_case "selection wire contract" `Quick test_wire;
  test_case "receipts retain the actual admitted client" `Quick test_bind_admitted_identity]]
