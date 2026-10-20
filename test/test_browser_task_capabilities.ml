open Alcotest
module Lane = Browser_lane
module Cap = Masc.Browser_capabilities
module Selection = Masc.Browser_selection
module Tools = Masc.Tool_misc_browser_lane
module U = Yojson.Safe.Util
let data = Tool_result.data
let argument actions = `Assoc ["requiredActions",`List (List.map (fun s -> `String s) actions)]
let tabs args = Tools.handle_tabs ~base_path:"/nonexistent/browser-capability-fixture"
  ~tool_name:"BrowserTabs" ~start_time:(Tool_timing.start ()) args
let client _digit transport : Lane.client_info =
  let client_id = Uuidm.v4_gen (Random.State.make_self_init ()) () in
  {client_id;transport;browser=Lane.Firefox;version="0.8.0";engine_version="fixture"}
let answered = Lane.Answered (`Assoc ["ok",`Bool true;"data",`List []])
let fixture run = Eio_main.run (fun env ->
  Time_compat.set_clock (Eio.Stdenv.clock env);
  let chrome=ref 0 and gecko=ref 0 and live=ref 0 in
  let extension=client "1" Lane.Web_extension and bidi=client "2" Lane.Webdriver_bidi in
  Lane.install_activity_observer (Some (fun _ -> Lane.Enabled));
  Lane.install_stagehand_executor (Some (fun ~actor:_ _ -> incr chrome;answered));
  Lane.install_automation_executor (Some (fun _ -> incr gecko;answered));
  List.iter (fun lane -> Lane.install_server_session_observer lane (Some (fun () -> Lane.Browser_open)))
    [Lane.Server_stagehand;Lane.Server_automation];
  Fun.protect ~finally:(fun () ->
    Lane.install_activity_observer None;Lane.install_stagehand_executor None;Lane.install_automation_executor None;
    List.iter (fun lane -> Lane.install_server_session_observer lane None) [Lane.Server_stagehand;Lane.Server_automation];
    List.iter (fun info -> ignore (Lane.disconnect_client ~client_id:info.Lane.client_id)) [extension;bidi]) (fun () ->
      List.iter (fun info -> ignore (Lane.take_command ~client_info:info ~window_sec:0.001)) [extension;bidi];
      Eio.Switch.run (fun sw ->
        List.iter (fun info -> Eio.Fiber.fork_daemon ~sw (fun () ->
          let rec serve () = match Lane.take_command ~client_info:info ~window_sec:0.01 with
            | Ok (Some command) -> incr live;
                ignore (Lane.deliver_result ~client_id:info.client_id ~id:command.id
                  ~payload:(`Assoc ["ok",`Bool true;"data",`List []]));serve ()
            | Ok None -> serve () | Error _ -> () in serve (); `Stop_daemon)) [extension;bidi];
        run ~chrome ~gecko ~live ~extension ~bidi)))
let lane result = U.(data result |> member "lane" |> to_string)
let test_task_choice () = fixture (fun ~chrome ~gecko ~live:_ ~extension:_ ~bidi:_ ->
  let html5=tabs (argument ["html5_drop";"open_tab";"close_tab";"back";"forward";"reload"]) in
  check string "HTML5 task selects native Chromium, not existing BiDi login" "stagehand" (lane html5);
  check int "one actual chosen executor dispatch" 1 !chrome;
  check int "no Gecko effect" 0 !gecko;
  check bool "receipt exposes exact-browser operation constraints" true
    (U.(data html5 |> member "browserCapabilities" |> member "operations" |> to_list |> List.length) > 0);
  let frames=tabs (argument ["read_frames";"list_downloads"]) in
  check string "frame/download task chooses owned Gecko" "automation" (lane frames);
  check int "one Gecko discovery" 1 !gecko;
  let native=tabs (argument ["hover";"type_text"]) in
  check string "connected native login satisfies task" "live" (lane native);
  check string "extension excluded for typing/hover" "webdriver_bidi" U.(data native |> member "transport" |> to_string))
let test_zoom_and_impossible () = fixture (fun ~chrome ~gecko ~live ~extension ~bidi:_ ->
  let zoom=tabs (argument ["page_zoom"]) in
  check string "zoom task binds extension" (Lane.client_id_to_string extension.client_id)
    U.(data zoom |> member "clientId" |> to_string);
  let before=(!chrome,!gecko,!live) in
  let impossible=tabs (argument ["page_zoom";"type_text"]) in
  check string "machine-readable combined requirement refusal" "required_browser_actions_unavailable"
    U.(data impossible |> member "code" |> to_string);
  check bool "no dispatch on impossible task" true (before=(!chrome,!gecko,!live));
  check bool "raw model output retains recovery candidates" true
    (Yojson.Safe.from_string (Tool_result.message impossible)=data impossible);
  check int "recovery lists actual connected/registered browsers" 4
    U.(data impossible |> member "candidates" |> to_list |> List.length);
  let explicit=tabs (`Assoc ["lane",`String "live";"clientId",`String (Lane.client_id_to_string extension.client_id);
    "requiredActions",`List [`String "hover"]]) in
  check string "exact unsupported owner is preserved" "unsupported_required_browser_actions"
    U.(data explicit |> member "code" |> to_string);
  check bool "explicit browser never falls back to native browser" true (before=(!chrome,!gecko,!live)))
let test_open_and_boundary () = fixture (fun ~chrome ~gecko ~live ~extension:_ ~bidi:_ ->
  List.iter (fun lane -> Lane.install_server_session_observer lane (Some (fun () -> Lane.Browser_closed)))
    [Lane.Server_stagehand;Lane.Server_automation];
  let open_ actions = Tools.handle_session ~tool_name:"BrowserSession" ~start_time:(Tool_timing.start ())
    (`Assoc ["action",`String "open";"requiredActions",`List (List.map (fun s -> `String s) actions)]) in
  ignore (open_ ["read_frames"]);check int "required frames opens Gecko, not configured Chromium" 1 !gecko;
  check int "Chromium not opened" 0 !chrome;
  let before=(!chrome,!gecko,!live) in
  ignore (open_ ["page_zoom"]);check bool "owned sessions cannot open an operator extension" true (before=(!chrome,!gecko,!live));
  List.iter (fun json -> ignore (tabs (`Assoc ["requiredActions",json]));
    check bool "invalid requirement never dispatches" true (before=(!chrome,!gecko,!live)))
    [`String "hover";`List [`String "typo"];`List [`String "hover";`String "hover"];`List [`Int 1]];
  ignore (tabs (`Assoc ["requiredActions",`List [];"requiredActions",`List [`String "hover"]]));
  check bool "duplicate requirement fields never dispatch" true (before=(!chrome,!gecko,!live));
  ignore (Tools.handle_session ~tool_name:"BrowserSession" ~start_time:(Tool_timing.start ())
    (`Assoc ["action",`String "status";"requiredActions",`List []]));
  check bool "requirements cannot redirect lifecycle inspection" true (before=(!chrome,!gecko,!live));
  check bool "bound automatic request cannot be reselected by capabilities" true
    (Selection.resolve ~required_actions:[Cap.Type_text] ~verb:Lane.Tabs_list ~bound:true Selection.Automatic
      = Error Selection.Binding_required))
let test_model_selection () = fixture (fun ~chrome ~gecko ~live ~extension:_ ~bidi:_ ->
  let chrome_before= !chrome in
  Lane.install_stagehand_executor ~models:false (Some (fun ~actor:_ _ -> incr chrome;answered));
  let before=(!chrome,!gecko,!live) in
  let required=["requiredActions",`List [`String "sentence_action"]] in
  List.iter (fun result ->
    check bool "model-off required task refuses before dispatch" true (not (Tool_result.is_success result)))
    [tabs (`Assoc required);
     tabs (`Assoc (("lane",`String "stagehand")::required));
     Tools.handle_session ~tool_name:"BrowserSession" ~start_time:(Tool_timing.start ())
       (`Assoc (("action",`String "open")::required));
     Tools.handle_session ~tool_name:"BrowserSession" ~start_time:(Tool_timing.start ())
       (`Assoc (("lane",`String "stagehand")::("action",`String "open")::required))];
  check bool "no discovery or open reached any browser" true (before=(!chrome,!gecko,!live));
  Lane.install_stagehand_executor ~models:true (Some (fun ~actor:_ _ -> incr chrome;answered));
  check bool "selected consumer restores required task discovery" true
    (Tool_result.is_success (tabs (`Assoc required)));
  check int "selected consumer dispatches exactly the chosen discovery" (chrome_before+1) !chrome)

let () = run "task-aware browser choice" ["scenarios",[
  test_case "HTML5, frames/downloads and hover/typing discovery" `Quick test_task_choice;
  test_case "zoom, impossible requirements and immutable explicit owners" `Quick test_zoom_and_impossible;
  test_case "session opening and parse/binding pre-effect refusal" `Quick test_open_and_boundary;
  test_case "selected model consumer is required before discovery and open" `Quick test_model_selection]]
