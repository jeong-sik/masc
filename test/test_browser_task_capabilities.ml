open Alcotest
module Lane = Browser_lane
module Cap = Masc.Browser_capabilities
module Selection = Masc.Browser_selection
module Tools = Masc.Browser_addon_tools
module Worker = Masc.Browser_addon_tool

let test_bound_request_keeps_its_browser () =
  check bool "bound automatic request cannot be reselected by capabilities" true
    (Selection.resolve ~required_actions:[Cap.Type_text] ~verb:Lane.Tabs_list ~bound:true Selection.Automatic
      = Error Selection.Binding_required)

let operations names = List.map (fun name -> match Cap.operation_of_wire name with
  | Some operation -> operation | None -> failf "%s is not a browser operation" name) names
let client transport : Lane.client_info =
  {client_id=Uuidm.v4_gen (Random.State.make_self_init ()) ();transport;browser=Lane.Firefox;
   version="0.8.0";engine_version="fixture"}

(* What the browser Add-on worker chooses from (lib/browser_addon_tool.ml):
   a connected extension host and a connected BiDi host beside an owned
   Chromium and an owned Firefox. Their executors count every command, and
   choosing must send none. *)
let with_browsers ?(models=true) ?(sessions=Lane.Browser_open) run = Eio_main.run (fun env ->
  Time_compat.set_clock (Eio.Stdenv.clock env);
  let dispatched=ref 0 in
  let refused=Lane.Refused "the selection fixture runs no browser command" in
  let extension=client Lane.Web_extension and bidi=client Lane.Webdriver_bidi in
  let owned=[Lane.Server_stagehand;Lane.Server_automation] in
  Lane.install_activity_observer (Some (fun _ -> Lane.Enabled));
  Lane.install_stagehand_executor ~models (Some (fun ~actor:_ _ -> incr dispatched;refused));
  Lane.install_automation_executor (Some (fun _ -> incr dispatched;refused));
  List.iter (fun lane -> Lane.install_server_session_observer lane (Some (fun () -> sessions))) owned;
  Fun.protect ~finally:(fun () ->
    Lane.install_activity_observer None;
    Lane.install_stagehand_executor None;Lane.install_automation_executor None;
    List.iter (fun lane -> Lane.install_server_session_observer lane None) owned;
    List.iter (fun (info:Lane.client_info) -> ignore (Lane.disconnect_client ~client_id:info.client_id))
      [extension;bidi]) (fun () ->
    List.iter (fun info -> ignore (Lane.take_command ~client_info:info ~window_sec:0.001)) [extension;bidi];
    run ~extension ~bidi;
    check int "choosing a browser sends it no command" 0 !dispatched))
let automatic ?(verb=Lane.Tabs_list) names =
  Selection.resolve ~required_actions:(operations names) ~verb ~bound:false Selection.Automatic
let chosen = function
  | Ok (selected : Selection.selected) -> Some selected.route
  | Error (_ : Selection.error) -> None
let live (info : Lane.client_info) = Some (Lane.Live_route (Some info.client_id))
let none_serves = function
  | Error (Selection.Required_actions_unavailable _) -> true
  | Ok _ | Error (Selection.Binding_required | No_available_browser | Ambiguous_browsers _
    | Unsupported_required_actions _) -> false
(* The worker admits an explicit browser, then checks the target it resolved,
   in this order (lib/browser_addon_tool.ml). The scripted Add-on the other
   browser tests use answers commands itself, so it never runs this. *)
let admitted names route =
  match Selection.resolve ~required_actions:(operations names) ~verb:Lane.Tabs_list ~bound:false
          (Selection.Exact route) with
  | Error error -> Error error
  | Ok selected ->
    (match Lane.resolve_target ~verb:Lane.Tabs_list selected.route with
     | Error _ -> fail "the explicit browser is connected"
     | Ok target -> Selection.require_target (operations names) target)
let unsupported = function
  | Error (Selection.Unsupported_required_actions _) -> true
  | Ok () | Error (Selection.Binding_required | No_available_browser | Ambiguous_browsers _
    | Required_actions_unavailable _) -> false

let test_task_choice () = with_browsers (fun ~extension ~bidi ->
  check bool "HTML5 drop and tab history choose the owned Chromium over the BiDi login" true
    (chosen (automatic ["html5_drop";"open_tab";"close_tab";"back";"forward";"reload"])
     = Some Lane.Stagehand_route);
  check bool "frames and downloads choose the owned Firefox" true
    (chosen (automatic ["read_frames";"list_downloads"]) = Some Lane.Automation_route);
  check bool "hover and typing choose the BiDi host, not the extension" true
    (chosen (automatic ["hover";"type_text"]) = live bidi);
  check bool "page zoom chooses the extension host" true
    (chosen (automatic ["page_zoom"]) = live extension))

let test_impossible_and_explicit () = with_browsers (fun ~extension ~bidi:_ ->
  (match automatic ["page_zoom";"type_text"] with
   | Error (Selection.Required_actions_unavailable {required;candidates}) ->
     check bool "the refusal names what was required" true (required = operations ["page_zoom";"type_text"]);
     check int "it lists every connected and owned browser as a candidate" 4 (List.length candidates)
   | Ok _ | Error (Selection.Binding_required | No_available_browser | Ambiguous_browsers _
     | Unsupported_required_actions _) -> fail "no browser zooms and types, so none is chosen");
  check bool "an explicit extension host that cannot hover is refused, not replaced" true
    (unsupported (admitted ["hover"] (Lane.Live_route (Some extension.client_id)))))

let test_session_open_choice () = with_browsers ~sessions:Lane.Browser_closed (fun ~extension:_ ~bidi:_ ->
  let opening = Lane.Session_open {headless=Some false} in
  check bool "a frame task opens the owned Firefox, not the configured Chromium" true
    (chosen (automatic ~verb:opening ["read_frames"]) = Some Lane.Automation_route);
  check bool "no owned browser zooms, so opening cannot fall to the operator's extension" true
    (none_serves (automatic ~verb:opening ["page_zoom"])))

let test_sentence_actions_need_the_model () =
  with_browsers ~models:false (fun ~extension:_ ~bidi:_ ->
    check bool "with Stagehand's models off no browser is chosen for a sentence action" true
      (none_serves (automatic ["sentence_action"]));
    check bool "an explicit Stagehand without models is refused" true
      (unsupported (admitted ["sentence_action"] Lane.Stagehand_route)));
  with_browsers ~models:true (fun ~extension:_ ~bidi:_ ->
    check bool "with its models on Stagehand serves a sentence action" true
      (chosen (automatic ["sentence_action"]) = Some Lane.Stagehand_route);
    check bool "and the explicit Stagehand is admitted" true
      (admitted ["sentence_action"] Lane.Stagehand_route = Ok ()))

(* Required actions are parsed before any browser is chosen. A refused list
   fails as the caller's input, before the tool looks for a browser Add-on;
   an accepted one goes on to that lookup, which finds none here. *)
let test_invalid_required_actions_reach_no_browser () =
  let config = Masc.Workspace.default_config
      (Filename.concat (Filename.get_temp_dir_name ()) "masc-browser-capability-no-workspace") in
  let invoke tool fields = Tools.handle ~config ~access:Masc.Lane_addon_sources.Operator_configuration
      ~principal:(Lane_addon_call_context.Host_actor "browser-capability-tester") ~reserved:[]
      ~keeper_name:None ~tool ~tool_name:"BrowserTabs" ~start_time:(Tool_timing.start ()) (`Assoc fields) in
  let refused_as_input result = Tool_result.failure_class result = Some Tool_result.Policy_rejection in
  List.iter (fun (name, value) ->
      check bool name true (refused_as_input (invoke Cap.Tabs ["requiredActions",value])))
    [ "a name that is not a list", `String "hover"
    ; "an unknown operation", `List [`String "typo"]
    ; "a repeated operation", `List [`String "hover";`String "hover"]
    ; "an operation that is not a name", `List [`Int 1] ];
  check bool "a repeated requiredActions field" true
    (refused_as_input (invoke Cap.Tabs ["requiredActions",`List [];"requiredActions",`List [`String "hover"]]));
  check bool "requirements cannot ride a session status" true
    (refused_as_input (invoke Cap.Session ["action",`String "status";"requiredActions",`List []]));
  check bool "an accepted list goes on to find the browser Add-on" true
    (Tool_result.failure_class (invoke Cap.Tabs ["requiredActions",`List [`String "hover"]])
     = Some Tool_result.Dependency_unavailable);
  let command fields = Worker.command (`Assoc fields) in
  check bool "the worker refuses a repeated requiredActions field" true
    (Result.is_error (command ["requiredActions",`List [];"requiredActions",`List [`String "hover"];
                               "command",Lane.verb_json Lane.Tabs_list]));
  check bool "the worker refuses requirements on a status" true
    (Result.is_error (command ["requiredActions",`List [`String "hover"];
                               "command",Lane.verb_json Lane.Session_status]));
  check bool "the worker accepts them on discovery" true
    (command ["requiredActions",`List [`String "hover"];"command",Lane.verb_json Lane.Tabs_list]
     = Ok Lane.Tabs_list)

let test_button_click_table () =
  let reaches backend operation = match Cap.support backend operation with
    | Cap.Available _ | Cap.Conditional _ -> true | Cap.Unsupported _ -> false in
  List.iter (fun operation ->
    check bool (Cap.operation_name operation ^ " on live BiDi") true
      (reaches (Cap.Connected Lane.Webdriver_bidi) operation);
    check bool (Cap.operation_name operation ^ " on owned Gecko") true (reaches Cap.Owned_gecko operation);
    check bool (Cap.operation_name operation ^ " on Stagehand") true (reaches Cap.Owned_chromium operation);
    check bool (Cap.operation_name operation ^ " is not claimed for the extension") false
      (reaches (Cap.Connected Lane.Web_extension) operation);
    check bool (Cap.operation_name operation ^ " is not claimed for Safari") false
      (reaches Cap.Safari_unavailable operation);
    match Cap.support Cap.Owned_gecko operation with
    | Cap.Conditional {invocation;_} ->
      check bool (Cap.operation_name operation ^ " is invoked through click_at") true
        (invocation.action = Some "click_at" && invocation.tool = Cap.Interact)
    | Cap.Available _ | Cap.Unsupported _ -> fail "a button click is conditional on an observed point")
    [Cap.Right_click; Cap.Middle_click]

let test_resize_viewport_table () =
  let reaches backend = match Cap.support backend Cap.Resize_viewport with
    | Cap.Available _ | Cap.Conditional _ -> true | Cap.Unsupported _ -> false in
  check bool "live BiDi sets the viewport" true (reaches (Cap.Connected Lane.Webdriver_bidi));
  check bool "Stagehand sets the viewport" true (reaches Cap.Owned_chromium);
  check bool "the owned Firefox driver sizes its window to the viewport" true (reaches Cap.Owned_gecko);
  check bool "the extension does not" false (reaches (Cap.Connected Lane.Web_extension));
  check bool "Safari does not" false (reaches Cap.Safari_unavailable)

let test_tab_history_and_close_table () =
  let reaches backend operation = match Cap.support backend operation with
    | Cap.Available _ | Cap.Conditional _ -> true | Cap.Unsupported _ -> false in
  List.iter (fun operation ->
    check bool (Cap.operation_name operation ^ " on live BiDi") true (reaches (Cap.Connected Lane.Webdriver_bidi) operation);
    check bool (Cap.operation_name operation ^ " on owned Gecko") true (reaches Cap.Owned_gecko operation);
    check bool (Cap.operation_name operation ^ " on Stagehand") true (reaches Cap.Owned_chromium operation);
    check bool (Cap.operation_name operation ^ " on ego") true (reaches (Cap.Connected Lane.Ego_task_space) operation);
    check bool (Cap.operation_name operation ^ " is not claimed for the extension") false
      (reaches (Cap.Connected Lane.Web_extension) operation);
    check bool (Cap.operation_name operation ^ " is not claimed for Safari") false (reaches Cap.Safari_unavailable operation))
    [Cap.Back; Cap.Forward; Cap.Reload; Cap.Close_tab]

let test_touch_table () =
  let reaches backend = match Cap.support backend Cap.Touch with
    | Cap.Available _ | Cap.Conditional _ -> true | Cap.Unsupported _ -> false in
  check bool "live BiDi sends touch" true (reaches (Cap.Connected Lane.Webdriver_bidi));
  check bool "the owned Firefox sends touch" true (reaches Cap.Owned_gecko);
  check bool "Stagehand has no touch" false (reaches Cap.Owned_chromium);
  check bool "the extension has no touch" false (reaches (Cap.Connected Lane.Web_extension));
  check bool "Safari has no touch" false (reaches Cap.Safari_unavailable)

let test_select_option_table () =
  let invocation backend = match Cap.support backend Cap.Select_option with
    | Cap.Available invocation | Cap.Conditional {invocation; _} -> Some (invocation.Cap.tool, invocation.Cap.action)
    | Cap.Unsupported _ -> None in
  List.iter (fun (label,backend) ->
    check bool (label ^ " selects through BrowserInteract") true
      (invocation backend = Some (Cap.Interact, Some "select_option")))
    ["live BiDi",Cap.Connected Lane.Webdriver_bidi;"the extension",Cap.Connected Lane.Web_extension;
     "Stagehand",Cap.Owned_chromium;"the owned Firefox",Cap.Owned_gecko];
  check bool "Safari has no select" true (invocation Cap.Safari_unavailable = None)

let test_list_windows_table () =
  let reaches backend = match Cap.support backend Cap.List_windows with
    | Cap.Available _ | Cap.Conditional _ -> true | Cap.Unsupported _ -> false in
  check bool "live BiDi names each tab's window" true (reaches (Cap.Connected Lane.Webdriver_bidi));
  List.iter (fun (label,backend) -> check bool (label ^ " does not") false (reaches backend))
    ["the extension",Cap.Connected Lane.Web_extension;"the owned Firefox",Cap.Owned_gecko;
     "Stagehand",Cap.Owned_chromium;"Safari",Cap.Safari_unavailable]

(* The catalog claims on an ego connection only what its peer does
   (Browser_lane.live_transport_serves Ego_task_space), and every read and
   effect on a page says that the operator's tabs in the space are refused. *)
let test_ego_table () =
  let backend = Cap.Connected Lane.Ego_task_space in
  let reachable = List.filter (fun operation -> match Cap.support backend operation with
    | Cap.Available _ | Cap.Conditional _ -> true | Cap.Unsupported _ -> false) Cap.operations in
  check (list string) "reads, capture, the tab list, its own tabs, their history, input, dialogs, uploads and downloads on them, and the space handed to the operator and back"
    ["list_tabs";"open_tab";"close_tab";"navigate";"follow_link";"back";"forward";"reload";"read_text";"read_elements";"read_scene";"read_regions";"read_snapshot";"screenshot";"click_snapshot_target";"fill_snapshot_target";
     "hover_snapshot_target";"double_click_snapshot_target";"click";"double_click";"right_click";"middle_click";"hover";"pointer_drag";"scroll_page";"scroll_at";
     "fill";"type_text";"press_key";"key_chord";"select_option";"read_dialog";"accept_dialog";"dismiss_dialog";"hand_off";"take_over";"upload_file";"list_downloads"]
    (List.map Cap.operation_name reachable);
  List.iter (fun operation -> match Cap.support backend operation with
    | Cap.Conditional {constraints;_} ->
      check bool (Cap.operation_name operation ^ " names the operator's tabs") true
        (List.exists (fun constraint_ -> String_util.contains_substring constraint_ "operator opened") constraints)
    | Cap.Available _ | Cap.Unsupported _ -> failf "%s is not conditional on ego" (Cap.operation_name operation))
    (List.filter (fun operation -> not (List.mem operation [Cap.List_tabs; Cap.Open_tab])) reachable)

(* ego's own accessibility snapshot, and acting on the targets it names, are
   claimed by the ego connection alone. *)
let test_snapshot_table () =
  List.iter (fun (backend, label, claimed) ->
    List.iter (fun operation ->
      check bool (label ^ (if claimed then " claims " else " does not claim ") ^ Cap.operation_name operation) claimed
        (match Cap.support backend operation with
         | Cap.Available _ | Cap.Conditional _ -> true | Cap.Unsupported _ -> false))
      [Cap.Read_snapshot; Cap.Click_snapshot_target; Cap.Fill_snapshot_target;
       Cap.Hover_snapshot_target; Cap.Double_click_snapshot_target])
    [Cap.Connected Lane.Ego_task_space, "ego", true;
     Cap.Connected Lane.Webdriver_bidi, "BiDi", false;
     Cap.Connected Lane.Web_extension, "the extension", false;
     Cap.Owned_gecko, "automation Firefox", false;
     Cap.Owned_chromium, "Stagehand Chromium", false;
     Cap.Safari_unavailable, "Safari", false]

let () = run "task-aware browser choice" ["scenarios",[
  test_case "a bound request is not reselected by required actions" `Quick test_bound_request_keeps_its_browser;
  test_case "HTML5, frames/downloads, hover/typing and zoom choose their browser" `Quick test_task_choice;
  test_case "an impossible combination lists candidates and an explicit browser is kept" `Quick
    test_impossible_and_explicit;
  test_case "session open chooses an owned browser that serves the task" `Quick test_session_open_choice;
  test_case "a sentence action needs Stagehand's models" `Quick test_sentence_actions_need_the_model;
  test_case "invalid required actions reach no browser" `Quick test_invalid_required_actions_reach_no_browser;
  test_case "right and middle click are claimed only where a button is pressed" `Quick test_button_click_table;
  test_case "viewport resize is claimed only where a size can be set" `Quick test_resize_viewport_table;
  test_case "history and close are claimed on every backend that acts on tabs" `Quick test_tab_history_and_close_table;
  test_case "touch is claimed only where a touch pointer is sent" `Quick test_touch_table;
  test_case "select_option is claimed where the shared script runs" `Quick test_select_option_table;
  test_case "window listing is claimed only where tabs name their window" `Quick test_list_windows_table;
  test_case "an ego connection is claimed only for what its peer does" `Quick test_ego_table;
  test_case "the ego snapshot is claimed by the ego connection alone" `Quick test_snapshot_table]]
