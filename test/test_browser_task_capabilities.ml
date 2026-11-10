open Alcotest
module Lane = Browser_lane
module Cap = Masc.Browser_capabilities
module Selection = Masc.Browser_selection
module Tools = Masc.Browser_addon_tools
module Worker = Masc.Browser_addon_tool

(* The requiredActions the discovery schema advertises are the operations this
   table answers for. Input validation refuses a name the schema leaves out
   before the host sees it, so a browser needed only for that work could not
   be chosen. *)
let test_required_actions_schema_lists_every_operation () =
  let enum (schema : Masc_domain.tool_schema) = Yojson.Safe.Util.(schema.input_schema
    |> member "properties" |> member "requiredActions" |> member "items" |> member "enum"
    |> to_list |> List.map to_string) |> List.sort String.compare in
  let operations = List.map Cap.operation_name Cap.operations |> List.sort String.compare in
  List.iter (fun (name, schema) ->
    check (list string) (name ^ " requiredActions are the operation table") operations (enum schema))
    ["masc_browser_tabs", Tool_schemas_misc_toml.browser_tabs]

let test_bound_request_keeps_its_browser () =
  check bool "bound automatic request cannot be reselected by capabilities" true
    (Selection.choose ~required_actions:[Cap.Type_text] ~verb:Lane.Tabs_list ~bound:true
       ~snapshot:{live_activity=Lane.Enabled;live_clients=[];live_space_presence=[]}
       Selection.Automatic
      = Error Selection.Binding_required)

let operations names = List.map (fun name -> match Cap.operation_of_wire name with
  | Some operation -> operation | None -> failf "%s is not a browser operation" name) names
let client transport : Lane.client_info =
  {client_id=Uuidm.v4_gen (Random.State.make_self_init ()) ();transport;browser=Lane.Ego_lite;
   version="0.8.0";engine_version="fixture";space=(match transport with Browser_lane.Ego_task_space -> Some ({id=51;name="fixture Space"} : Browser_lane.ego_space))}

(* What a browser Add-on worker reports in its snapshot and the host chooses
   from (lib/browser_addon_host.ml): a connected ego task space. Choosing must
   queue it no command. *)
let with_browsers run = Eio_main.run (fun env ->
  Time_compat.set_clock (Eio.Stdenv.clock env);
  let ego=client Lane.Ego_task_space in
  Lane.install_activity_observer (Some (fun _ -> Lane.Enabled));
  Fun.protect ~finally:(fun () ->
    Lane.install_activity_observer None;
    List.iter (fun (info:Lane.client_info) -> ignore (Lane.disconnect_client ~client_id:info.client_id))
      [ego]) (fun () ->
    List.iter (fun info -> ignore (Lane.take_command ~client_info:info ~window_sec:0.001)) [ego];
    run ~ego;
    List.iter (fun info -> check bool "choosing a browser sends it no command" true
      (Lane.take_command ~client_info:info ~window_sec:0.001=Ok None)) [ego]))
(* An ego connection is chosen only while its task space is observed present. *)
let snapshot () : Selection.snapshot =
  let clients=Lane.connected_clients () in
  {live_activity=Lane.Enabled;live_clients=clients;
   live_space_presence=List.filter_map (fun (info:Lane.client_info) -> Option.map (fun (space:Lane.ego_space) ->
     info.client_id,{Masc.Browser_ego_space_observation.space_id=space.id;observed_at=0.;state=Present}) info.space) clients}
let automatic ?(verb=Lane.Tabs_list) names =
  Selection.choose ~required_actions:(operations names) ~verb ~bound:false
    ~snapshot:(snapshot ()) Selection.Automatic
let chosen = function
  | Ok (selected : Selection.selected) -> Some selected.route
  | Error (_ : Selection.error) -> None
let live (info : Lane.client_info) = Some (Lane.Live_route (Some info.client_id))
let none_serves = function
  | Error (Selection.Required_actions_unavailable _) -> true
  | Ok _ | Error (Selection.Binding_required | No_available_browser | Ambiguous_browsers _
    | Unsupported_required_actions _) -> false
(* The host admits an explicit browser, then checks the browser the snapshot
   names, in this order (lib/browser_addon_host.ml). The scripted Add-on the
   other browser tests use answers commands itself, so it never runs this. *)
let admitted names route =
  let snapshot=snapshot () in
  match Selection.choose ~required_actions:(operations names) ~verb:Lane.Tabs_list ~bound:false ~snapshot
          (Selection.Exact route) with
  | Error error -> Error error
  | Ok selected ->
    (match Selection.target ~verb:Lane.Tabs_list ~snapshot selected.route with
     | Error _ -> fail "the explicit browser is connected"
     | Ok browser -> Selection.require (operations names) browser)
let unsupported = function
  | Error (Selection.Unsupported_required_actions _) -> true
  | Ok () | Error (Selection.Binding_required | No_available_browser | Ambiguous_browsers _
    | Required_actions_unavailable _) -> false

let test_task_choice () = with_browsers (fun ~ego ->
  (* #49295 gave the ego connection tap_at/swipe, so Cap.support says Touch is
     served there (lib/browser_capabilities.ml:266-271) and this file's own
     test_touch_table asserts the same at "ego sends touch". A touch-only
     request therefore chooses that connection instead of finding none. *)
  check bool "touch chooses the ego connection" true
    (chosen (automatic ["touch"]) = live ego);
  check bool "hover and typing choose the ego connection" true
    (chosen (automatic ["hover";"type_text"]) = live ego);
  check bool "no browser zooms the page, so none is chosen" true
    (none_serves (automatic ["page_zoom"])))

let test_impossible_and_explicit () = with_browsers (fun ~ego ->
  (match automatic ["page_zoom";"type_text"] with
   | Error (Selection.Required_actions_unavailable {required;candidates}) ->
     check bool "the refusal names what was required" true (required = operations ["page_zoom";"type_text"]);
     check int "it lists every connected browser as a candidate" 1 (List.length candidates)
   | Ok _ | Error (Selection.Binding_required | No_available_browser | Ambiguous_browsers _
     | Unsupported_required_actions _) -> fail "no browser zooms and types, so none is chosen");
  (* Same reason as the selection above: the ego connection serves touch
     (lib/browser_capabilities.ml:266-271), so an explicit request naming it
     for touch is admitted rather than refused. *)
  check bool "an explicit ego connection that serves touch is admitted" true
    (admitted ["touch"] (Lane.Live_route (Some ego.client_id)) = Ok ()))

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
  check bool "requirements cannot ride a Goal status read" true
    (refused_as_input (invoke Cap.Session ["action",`String "goal_status";"goalId",`String "goal-probe";"requiredActions",`List []]));
  check bool "an accepted list goes on to find the browser Add-on" true
    (Tool_result.failure_class (invoke Cap.Tabs ["requiredActions",`List [`String "hover"]])
     = Some Tool_result.Dependency_unavailable);
  let parse fields = Masc.Browser_addon_host.parse_command (`Assoc fields) in
  check bool "the host refuses a repeated requiredActions field" true
    (Result.is_error (parse ["requiredActions",`List [];"requiredActions",`List [`String "hover"];
                             "command",Lane.verb_json Lane.Tabs_list]));
  check bool "the host keeps the requirements for its own choice" true
    (parse ["requiredActions",`List [`String "hover"];"command",Lane.verb_json Lane.Tabs_list]
     = Ok (Selection.Automatic,Lane.Tabs_list,operations ["hover"],None));
  check bool "a lane names a browser backend" true
    (Result.is_error (parse ["lane",`String "work";"command",Lane.verb_json Lane.Tabs_list]));
  (* The host checks requirements while it chooses; the worker runs the
     route it was given and takes none. *)
  let command fields = Worker.command (`Assoc fields) in
  let raw_id="0c000000-0000-4000-8000-000000000001" in
  let client_id=match Lane.client_id_of_string raw_id with Ok id -> id | Error detail -> fail detail in
  check bool "the worker refuses requirements even on discovery" true
    (Result.is_error (command ["lane",`String "live";"clientId",`String raw_id;
                               "requiredActions",`List [`String "hover"];
                               "command",Lane.verb_json Lane.Tabs_list]));
  check bool "the worker accepts the chosen route alone" true
    (command ["lane",`String "live";"clientId",`String raw_id;"command",Lane.verb_json Lane.Tabs_list]
     = Ok (Lane.Live_route (Some client_id),Lane.Tabs_list))

let test_button_click_table () =
  let reaches backend operation = match Cap.support backend operation with
    | Cap.Available _ | Cap.Conditional _ -> true | Cap.Unsupported _ -> false in
  List.iter (fun operation ->
    check bool (Cap.operation_name operation ^ " on ego") true
      (reaches (Cap.Connected Lane.Ego_task_space) operation);
    check bool (Cap.operation_name operation ^ " is not claimed for Safari") false
      (reaches Cap.Safari_unavailable operation);
    match Cap.support (Cap.Connected Lane.Ego_task_space) operation with
    | Cap.Conditional {invocation;_} ->
      check bool (Cap.operation_name operation ^ " is invoked through click_at") true
        (invocation.action = Some "click_at" && invocation.tool = Cap.Interact)
    | Cap.Available _ | Cap.Unsupported _ -> fail "a button click is conditional on an observed point")
    [Cap.Right_click; Cap.Middle_click]

let test_resize_viewport_table () =
  let reaches backend = match Cap.support backend Cap.Resize_viewport with
    | Cap.Available _ | Cap.Conditional _ -> true | Cap.Unsupported _ -> false in
  check bool "ego sets the page viewport through its CDP session" true (reaches (Cap.Connected Lane.Ego_task_space));
  check bool "Safari does not" false (reaches Cap.Safari_unavailable)

let test_tab_history_and_close_table () =
  let reaches backend operation = match Cap.support backend operation with
    | Cap.Available _ | Cap.Conditional _ -> true | Cap.Unsupported _ -> false in
  List.iter (fun operation ->
    check bool (Cap.operation_name operation ^ " on ego") true (reaches (Cap.Connected Lane.Ego_task_space) operation);
    check bool (Cap.operation_name operation ^ " is not claimed for Safari") false (reaches Cap.Safari_unavailable operation))
    [Cap.Back; Cap.Forward; Cap.Reload; Cap.Close_tab]

let test_touch_table () =
  let reaches backend = match Cap.support backend Cap.Touch with
    | Cap.Available _ | Cap.Conditional _ -> true | Cap.Unsupported _ -> false in
  check bool "ego sends touch" true (reaches (Cap.Connected Lane.Ego_task_space));
  check bool "Safari has no touch" false (reaches Cap.Safari_unavailable)

let test_select_option_table () =
  let invocation backend = match Cap.support backend Cap.Select_option with
    | Cap.Available invocation | Cap.Conditional {invocation; _} -> Some (invocation.Cap.tool, invocation.Cap.action)
    | Cap.Unsupported _ -> None in
  List.iter (fun (label,backend) ->
    check bool (label ^ " selects through BrowserInteract") true
      (invocation backend = Some (Cap.Interact, Some "select_option")))
    ["ego",Cap.Connected Lane.Ego_task_space];
  check bool "Safari has no select" true (invocation Cap.Safari_unavailable = None)

let test_list_windows_table () =
  let reaches backend = match Cap.support backend Cap.List_windows with
    | Cap.Available _ | Cap.Conditional _ -> true | Cap.Unsupported _ -> false in
  check bool "ego names each tab's window" true (reaches (Cap.Connected Lane.Ego_task_space));
  List.iter (fun (label,backend) -> check bool (label ^ " does not") false (reaches backend))
    ["Safari",Cap.Safari_unavailable]

let test_intercept_network_table () =
  let invocation backend = match Cap.support backend Cap.Intercept_network with
    | Cap.Available invocation | Cap.Conditional {invocation; _} -> Some (invocation.Cap.tool, invocation.Cap.action)
    | Cap.Unsupported _ -> None in
  check bool "ego blocks requests through BrowserAct" true
    (invocation (Cap.Connected Lane.Ego_task_space) = Some (Cap.Act, Some "block_requests"));
  List.iter (fun (label,backend) -> check bool (label ^ " does not") true (invocation backend = None))
    ["Safari",Cap.Safari_unavailable]

let test_read_storage_table () =
  let invocation backend = match Cap.support backend Cap.Read_storage with
    | Cap.Available invocation | Cap.Conditional {invocation; _} -> Some (invocation.Cap.tool, invocation.Cap.mode)
    | Cap.Unsupported _ -> None in
  check bool "ego lists cookie and storage names through BrowserRead" true
    (invocation (Cap.Connected Lane.Ego_task_space) = Some (Cap.Read, Some "cookies"));
  List.iter (fun (label,backend) -> check bool (label ^ " does not") true (invocation backend = None))
    ["Safari",Cap.Safari_unavailable]

let test_read_console_table () =
  let invocation backend = match Cap.support backend Cap.Read_console with
    | Cap.Available invocation | Cap.Conditional {invocation; _} -> Some (invocation.Cap.tool, invocation.Cap.mode)
    | Cap.Unsupported _ -> None in
  check bool "ego reads a tab's console through BrowserRead" true
    (invocation (Cap.Connected Lane.Ego_task_space) = Some (Cap.Read, Some "console"));
  List.iter (fun (label,backend) -> check bool (label ^ " does not") true (invocation backend = None))
    ["Safari",Cap.Safari_unavailable]

let test_write_storage_table () =
  let invocation backend = match Cap.support backend Cap.Write_storage with
    | Cap.Available invocation | Cap.Conditional {invocation; _} -> Some (invocation.Cap.tool, invocation.Cap.action)
    | Cap.Unsupported _ -> None in
  check bool "ego writes cookies through BrowserAct" true
    (invocation (Cap.Connected Lane.Ego_task_space) = Some (Cap.Act, Some "set_cookie"));
  List.iter (fun (label,backend) -> check bool (label ^ " does not") true (invocation backend = None))
    ["Safari",Cap.Safari_unavailable]

let test_read_network_table () =
  let invocation backend = match Cap.support backend Cap.Read_network with
    | Cap.Available invocation | Cap.Conditional {invocation; _} -> Some (invocation.Cap.tool, invocation.Cap.mode)
    | Cap.Unsupported _ -> None in
  check bool "ego lists a tab's requests through BrowserRead" true
    (invocation (Cap.Connected Lane.Ego_task_space) = Some (Cap.Read, Some "network"));
  List.iter (fun (label,backend) -> check bool (label ^ " does not") true (invocation backend = None))
    ["Safari",Cap.Safari_unavailable]

(* The catalog claims on an Ego connection only what its peer does
   (Browser_lane.live_transport_serves Ego_task_space). Page operations retain
   explicit conditions; the peer tests exercise their actual admission. *)
let test_ego_table () =
  let backend = Cap.Connected Lane.Ego_task_space in
  (match Cap.support backend Cap.Close_tab with
   | Cap.Conditional {invocation={tool=Act;mode=None;action=Some "close_tab"};_} -> ()
   | Cap.Available _|Cap.Conditional _|Cap.Unsupported _ -> fail "Ego closing must use its explicit close_tab action");
  (match Cap.support backend Cap.Read_dialog with
   | Cap.Conditional {invocation={tool=Read;mode=Some "dialog";action=None};_} -> ()
   | Cap.Available _|Cap.Conditional _|Cap.Unsupported _ -> fail "Ego dialog metadata must use its explicit read mode");
  (match Cap.support backend Cap.Html5_drop with
   | Cap.Conditional {invocation={tool=Interact;mode=None;action=Some "drag_to"};_} -> ()
   | Cap.Available _|Cap.Conditional _|Cap.Unsupported _ -> fail "Ego HTML5 drop must use the selector-to-selector drag_to");
  let reachable = List.filter (fun operation -> match Cap.support backend operation with
    | Cap.Available _ | Cap.Conditional _ -> true | Cap.Unsupported _ -> false) Cap.operations in
  check (list string) "reads, capture, the tab list and its windows, its own tabs, their history, input, touch, dialogs, uploads and downloads on them, their viewport size, environment, blocked hosts, storage names, requests, console and cookie writes, and the space handed to the operator and back"
    ["list_tabs";"open_tab";"close_tab";"activate_tab";"list_windows";"navigate";"follow_link";"back";"forward";"reload";"stop_loading";"read_text";"read_html";"read_elements";"read_scene";"read_regions";"read_snapshot";"screenshot";"native_workflow";"click_snapshot_target";"fill_snapshot_target";
     "hover_snapshot_target";"double_click_snapshot_target";"click";"double_click";"right_click";"middle_click";"hover";"pointer_drag";"html5_drop";"scroll_page";"scroll_at";
     "fill";"type_text";"press_key";"key_chord";"select_option";"read_dialog";"accept_dialog";"dismiss_dialog";"hand_off";"take_over";"space_status";"finish_space";"wait_for_control";"adopt_tab";"release_tab";"upload_file";"list_downloads";"resize_viewport";"touch";"emulate_environment";"intercept_network";"read_storage";"read_network";"read_console";"write_storage"]
    (List.map Cap.operation_name reachable);
  List.iter (fun operation -> match Cap.support backend operation with
    | Cap.Conditional {constraints=_::_;_} -> ()
    | Cap.Conditional {constraints=[];_} | Cap.Available _ | Cap.Unsupported _ ->
      failf "%s needs explicit Ego Page conditions" (Cap.operation_name operation))
    (* Space metadata, completion and the control wait act on the Space, not on
       a page; adopting or releasing a page manages an unmanaged tab the
       operator opened on purpose. *)
    (List.filter (fun operation -> not (List.mem operation
      [Cap.List_tabs; Cap.Open_tab; Cap.Space_status; Cap.Finish_space; Cap.Wait_for_control;
       Cap.Adopt_tab; Cap.Release_tab])) reachable)

(* ego's own accessibility snapshot, and acting on the targets it names, are
   claimed by the ego connection alone. *)
let test_loading_recovery_table () =
  List.iter (fun (backend, label, claimed) ->
    check bool (label ^ " native loading recovery") claimed
      (match Cap.support backend Cap.Stop_loading with
       | Cap.Conditional {invocation; _} -> invocation.Cap.tool=Cap.Act && invocation.Cap.action=Some "stop_loading"
       | Cap.Available _ -> fail "recovery must retain native Page authority constraints"
       | Cap.Unsupported _ -> false))
    [Cap.Connected Lane.Ego_task_space, "Ego", true;
     Cap.Safari_unavailable, "Safari", false]

let test_snapshot_table () =
  List.iter (fun (backend, label, claimed) ->
    List.iter (fun operation ->
      check bool (label ^ (if claimed then " claims " else " does not claim ") ^ Cap.operation_name operation) claimed
        (match Cap.support backend operation with
         | Cap.Available _ | Cap.Conditional _ -> true | Cap.Unsupported _ -> false))
      [Cap.Read_snapshot; Cap.Click_snapshot_target; Cap.Fill_snapshot_target;
       Cap.Hover_snapshot_target; Cap.Double_click_snapshot_target])
    [Cap.Connected Lane.Ego_task_space, "ego", true;
     Cap.Safari_unavailable, "Safari", false]

let test_native_input_admission_surface () =
  let schema=Tool_schemas_misc_toml.browser_interact in
  let methods=Yojson.Safe.Util.(schema.input_schema |> member "properties" |> member "steps"
    |> member "items" |> member "properties" |> member "method" |> member "enum"
    |> to_list |> List.map to_string) in
  check int "native-window typing is an explicit executable model method" 1
    (List.length (List.filter ((=) "keyboard.type") methods));
  List.iter (fun name -> check bool (name ^ " remains explicit") true (List.mem name methods))
    ["fill";"keyboard.insertText";"keyboard.paste";"keyboard.press";"dragAndDrop"];
  (match Cap.support (Cap.Connected Lane.Ego_task_space) Cap.Type_text with
   | Cap.Conditional {invocation;constraints=_::_} ->
     check bool "typing remains an exact observed native interaction" true
       (invocation.Cap.tool=Cap.Interact && invocation.Cap.action=Some "type_text")
   | Conditional {constraints=[];_} | Available _ | Unsupported _ ->
     fail "native-window typing must retain its Page and focus conditions");
  let config=Masc.Workspace.default_config
    (Filename.concat (Filename.get_temp_dir_name ()) "masc-browser-raw-input-no-workspace") in
  let invoke steps=Tools.handle ~config ~access:Masc.Lane_addon_sources.Operator_configuration
    ~principal:(Lane_addon_call_context.Host_actor "browser-input-contract-tester") ~reserved:[]
    ~keeper_name:None ~tool:Cap.Interact ~tool_name:"BrowserInteract" ~start_time:(Tool_timing.start ())
    (`Assoc ["clientId",`String "0c000000-0000-4000-8000-000000000001";
      "action",`String "workflow";"tabId",`Int 1;"expectedUrl",`String "https://fixture.test/";
      "steps",`List steps]) in
  let fill=`Assoc ["method",`String "fill";"selector",`String "#editor";"text",`String "earlier effect"] in
  let raw=`Assoc ["method",`String "keyboard.type";"text",`String "raw"] in
  let safe=`Assoc ["method",`String "keyboard.insertText";"text",`String "literal"] in
  check bool "native-window typing reaches ordinary Add-on lookup" true
    (Tool_result.failure_class (invoke [fill;raw])=Some Tool_result.Dependency_unavailable);
  check bool "nonholding insertion retains ordinary Add-on lookup" true
    (Tool_result.failure_class (invoke [fill;safe])=Some Tool_result.Dependency_unavailable)

(* The catalog answer keeps one row per operation. A Conditional row lists its
   constraints only for an operation the caller named; an Available or
   Unsupported row never does. *)
let test_constraints_follow_required_actions () =
  let backend = Cap.Connected Lane.Ego_task_space in
  let rows constraints_for =
    Yojson.Safe.Util.(Cap.to_json backend ~constraints_for |> member "operations" |> to_list) in
  let name row = Yojson.Safe.Util.(row |> member "operation" |> to_string) in
  let listing constraints_for =
    List.filter_map (fun row -> match Yojson.Safe.Util.member "constraints" row with
      | `Null -> None
      | `List (_::_) -> Some (name row)
      | `List [] | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ ->
        failf "%s lists constraints that are not a non-empty array" (name row)) (rows constraints_for) in
  check (list string) "every operation keeps its row" (List.map Cap.operation_name Cap.operations)
    (List.map name (rows []));
  check (list string) "no operation named" [] (listing []);
  check (list string) "only the named conditional operations, in catalog order" ["hover";"type_text"]
    (listing [Cap.Type_text; Cap.Hover]);
  check (list string) "an available operation has none" [] (listing [Cap.List_tabs]);
  check (list string) "an unsupported operation has none" [] (listing [Cap.Close_window])

let () = run "task-aware browser choice" ["scenarios",[
  test_case "a bound request is not reselected by required actions" `Quick test_bound_request_keeps_its_browser;
  test_case "HTML5, frames/downloads, hover/typing and zoom choose their browser" `Quick test_task_choice;
  test_case "an impossible combination lists candidates and an explicit browser is kept" `Quick
    test_impossible_and_explicit;
  test_case "invalid required actions reach no browser" `Quick test_invalid_required_actions_reach_no_browser;
  test_case "right and middle click are claimed only where a button is pressed" `Quick test_button_click_table;
  test_case "viewport resize is claimed only where a size can be set" `Quick test_resize_viewport_table;
  test_case "history and close are claimed on every backend that acts on tabs" `Quick test_tab_history_and_close_table;
  test_case "touch is claimed only where a touch pointer is sent" `Quick test_touch_table;
  test_case "select_option is claimed where the shared script runs" `Quick test_select_option_table;
  test_case "window listing is claimed only where tabs name their window" `Quick test_list_windows_table;
  test_case "request blocking is claimed only on ego" `Quick test_intercept_network_table;
  test_case "storage names are claimed only on ego" `Quick test_read_storage_table;
  test_case "requests are claimed only on ego" `Quick test_read_network_table;
  test_case "the console is claimed only on ego" `Quick test_read_console_table;
  test_case "cookie writes are claimed only on ego" `Quick test_write_storage_table;
  test_case "an ego connection is claimed only for what its peer does" `Quick test_ego_table;
  test_case "native loading recovery is exposed only by Ego" `Quick test_loading_recovery_table;
  test_case "the ego snapshot is claimed by the ego connection alone" `Quick test_snapshot_table;
  test_case "native input availability is truthful and preflights the entire workflow" `Quick test_native_input_admission_surface;
  test_case "discovery schemas list every operation" `Quick test_required_actions_schema_lists_every_operation;
  test_case "constraints are listed only for the operations the caller named" `Quick test_constraints_follow_required_actions]]
