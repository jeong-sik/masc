open Alcotest
module Selection = Masc.Browser_selection
module Lane = Browser_lane
let work session : Selection.work_browser = {activity=Lane.Enabled;registered=true;session;locate=false}
let empty : Selection.snapshot = {live_activity=Lane.Enabled;live_clients=[];
  stagehand=work Lane.Browser_closed;automation=work Lane.Browser_closed}
let client digit transport : Lane.client_info =
  let id="00000000-0000-4000-8000-00000000000" ^ digit in
  let client_id = match Lane.client_id_of_string id with Ok id -> id | Error error -> fail error in
  {client_id;browser=Lane.Firefox;version="fixture";engine_version="fixture";transport;space=(match transport with Browser_lane.Ego_task_space -> Some ({id=51;name="fixture Space"} : Browser_lane.ego_space) | Web_extension|Webdriver_bidi -> None)}
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
  let workflow=match Lane.Native_workflow.of_json (`Assoc ["tabId",`Int 1;
    "expectedUrl",`String "https://example.test/";"steps",`List [];"maxChars",`Int 1000]) with
    | Ok request -> Lane.Page_native_workflow request | Error detail -> fail detail in
  check bool "native workflow is bound to its observed tab" true (Selection.bound workflow);
  check bool "native workflow cannot silently select another browser" true
    (choose ~verb:workflow ~bound:(Selection.bound workflow)
      {empty with live_clients=[client "3" Lane.Ego_task_space]}=Error Selection.Binding_required);
  check bool "automatic bound request cannot change browser" true (choose ~bound:true empty=Error Selection.Binding_required);
  let explicit=Lane.Live_route (Some (client "1" Lane.Webdriver_bidi).client_id) in
  selected {route=explicit;reason=Selection.Explicit_browser}
    (Selection.choose ~verb:Lane.Tabs_list ~bound:true ~snapshot:empty (Selection.Exact explicit));
  let unnamed=Selection.Exact (Lane.Live_route None) in
  List.iter (fun info ->
    check bool "an unbound live lane cannot adopt a different client's observed tab" true
      (Selection.choose ~verb:(Lane.Page_read {tab_id=Some 0;max_chars=None}) ~bound:true
        ~snapshot:{empty with live_clients=[info]} unnamed=Error Selection.Binding_required))
    [client "1" Lane.Webdriver_bidi;client "2" Lane.Webdriver_bidi];
  check bool "bound live lane requires client identity before runtime observation" true
    (Selection.choose ~verb:Lane.Tabs_list ~bound:true ~snapshot:empty unnamed=Error Selection.Binding_required);
  selected {route=Lane.Live_route None;reason=Selection.Explicit_browser}
    (Selection.choose ~verb:Lane.Tabs_list ~bound:false ~snapshot:empty unnamed)

let test_native_workflow_binding () =
  let workflow = match Lane.Native_workflow.of_json (`Assoc ["tabId",`Int 7;
    "expectedUrl",`String "https://example.org";"steps",`List [];"maxChars",`Int 1000]) with
    | Ok workflow -> workflow | Error detail -> fail detail in
  let verb=Lane.Page_native_workflow workflow in
  let first=client "1" Lane.Ego_task_space and second=client "2" Lane.Ego_task_space in
  let snapshot={empty with live_clients=[first;second]} in
  let bound=Selection.bound verb in
  check bool "a workflow's tab requires its original browser" true bound;
  List.iter (fun preference ->
    check bool "observed clients cannot supply a missing workflow browser identity" true
      (Selection.choose ~verb ~bound ~snapshot preference=Error Selection.Binding_required))
    [Selection.Automatic;Selection.Exact (Lane.Live_route None)];
  selected {route=route second;reason=Selection.Explicit_browser}
    (Selection.choose ~verb ~bound ~snapshot (Selection.Exact (route second)))

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
  let hover=Lane.Page_interact {frame_path=[];tab_id=0;expected_url=None;action=Lane.Hover (Lane.Selector "#observed")} in
  check bool "extension cannot be silently selected for trusted hover" true
    (choose ~verb:hover {empty with live_clients=[extension]}=Error Selection.No_available_browser);
  check bool "disabled login is not selected" true
    (choose {empty with live_activity=Lane.Disabled;live_clients=[client "1" Lane.Webdriver_bidi]}=Error Selection.No_available_browser);
  let timing=Lane.Page_interact {frame_path=[];tab_id=0;expected_url=None;action=Lane.Drag_to {
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
      (Selection.choose ~verb:(Lane.Session_open {headless=None}) ~bound:false
        ~snapshot:(Masc.Browser_addon_inventory.observe ()) Selection.Automatic);
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
let test_ambiguous_selection_recovery () =
  let first=client "1" Lane.Webdriver_bidi and second=client "2" Lane.Ego_task_space in
  let json=Selection.error_to_json (Selection.Ambiguous_browsers [route first;route second]) in
  let open Yojson.Safe.Util in
  check string "selection refusal code" "ambiguous_browsers" (json |> member "code" |> to_string);
  check int "both browser choices retained" 2 (json |> member "browsers" |> to_list |> List.length);
  check string "structured recovery contract"
    {|{"action":"repeat_same_tool_with_selected_browser","commandDispatched":false,"failureScope":"browser_selection","browserChoices":"browsers"}|}
    (json |> member "recovery" |> Yojson.Safe.to_string)
let test_bind_chosen_identity () =
  let info=client "1" Lane.Webdriver_bidi in
  let explicit : Selection.selected = {route=Lane.Live_route None;reason=Selection.Explicit_browser} in
  match Selection.target ~verb:Lane.Tabs_list ~snapshot:{empty with live_clients=[info]} (Lane.Live_route None) with
  | Ok browser -> selected {route=route info;reason=Selection.Explicit_browser} (Ok (Selection.bind explicit browser))
  | Error error -> fail (Lane.selection_error_message error)
(* The host names the browser from the worker's snapshot with the refusals the
   worker gives for the same route. *)
let test_target_from_snapshot () =
  let first=client "1" Lane.Webdriver_bidi and second=client "2" Lane.Web_extension in
  let target ?(verb=Lane.Tabs_list) snapshot route=Selection.target ~verb ~snapshot route in
  check bool "no connected client" true (target empty (Lane.Live_route None)=Error Lane.No_live_client);
  check bool "several connected clients need a clientId" true
    (target {empty with live_clients=[second;first]} (Lane.Live_route None)
     =Error (Lane.Ambiguous_clients [first.client_id;second.client_id]));
  check bool "a client the snapshot does not hold has left" true
    (target {empty with live_clients=[first]} (route second)=Error (Lane.Selected_client_disconnected second.client_id));
  check bool "a named client is that client" true
    (target {empty with live_clients=[first;second]} (route second)=Ok (Selection.Connected second));
  let off={empty with automation={empty.automation with activity=Lane.Disabled}} in
  check bool "a lane that is off refuses new work" true
    (target off Lane.Automation_route=Error (Lane.Activity_rejected (Lane.Lane_off Lane.Lane_name.Automation)));
  check bool "a lane that is off still closes its session" true
    (target ~verb:Lane.Session_close off Lane.Automation_route=Ok Selection.Owned_automation);
  check bool "the live lane follows the snapshot's live activity" true
    (target {empty with live_activity=Lane.Unobserved;live_clients=[first]} (route first)
     =Error (Lane.Activity_rejected Lane.Activity_unavailable))
let test_space_binding () =
  let module Binding=Masc.Browser_binding in
  let original=client "1" Lane.Ego_task_space in
  let space : Lane.ego_space = {id=51;name="SDK Space"} in
  let original={original with space=Some space} in
  let make info=Binding.of_browser {Selection.route=route info;reason=Selection.Explicit_browser}
    (Selection.Connected info) in
  let binding=make original in
  let renamed=make {original with space=Some {space with name="Renamed Space"}} in
  let replaced=make {original with space=Some {space with id=52}} in
  check bool "a rename retains the same Space connection" true (Binding.same_connection binding renamed);
  check bool "reusing a client UUID cannot silently replace its Space" false (Binding.same_connection binding replaced);
  let forged=`Assoc ["browserSpace",`Assoc ["id",`Int 999;"name",`String "forged"];
    "browserSpace",`Null;"clientId",`String "forged";"tabId",`Int 3] in
  let answer=Binding.annotate binding forged in
  check bool "host Space replaces every page-supplied context" true
    (Yojson.Safe.Util.member "browserSpace" answer=Lane.ego_space_to_json space);
  (match answer with
   | `Assoc fields -> check int "Space context has one authoritative value" 1
       (List.length (List.filter (fun (key,_) -> key="browserSpace") fields))
   | _ -> fail "expected object")

let test_goal_space_default () =
  let module G=Masc.Browser_goal_space in
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir=Filename.temp_dir "browser-goal-space-" "" in
  let rec remove path =
    if Sys.is_directory path then (
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path in
  Fun.protect ~finally:(fun () -> remove dir) (fun () ->
    let config=Masc.Workspace.default_config dir in
    ignore (Masc.Workspace.init config ~agent_name:(Some "fixture"));
    let goal title=match Goal_store.upsert_goal config ~title ~metric:"verified" ~target_value:"1" () with
      | Ok (goal,_) -> goal.id
      | Error error -> fail (Goal_store.write_error_to_string error) in
    let first=goal "first" and second=goal "second" in
    let ok=function Ok value -> value | Error e -> fail (G.error_message e) in
    let space : Lane.ego_space={id=51;name="observed Space"} in
    let bind goal_id space=G.bind config ~goal_id ~addon_instance_id:"addon-one" ~space ~actor:"keeper:test" in
    check bool "existing Goal starts unbound" true (ok (G.find config ~goal_id:first)=None);
    let committed=ok (bind first space) in
    check bool "first assignment committed" true committed.created;
    check bool "same assignment is idempotent" false (ok (bind first {space with name="renamed"})).created;
    check bool "another Space never replaces a Goal pin" true (Result.is_error (bind first {space with id=52}));
    check bool "distinct Goals never silently share one Space" true (Result.is_error (bind second space));
    let readback=Option.get (ok (G.find config ~goal_id:first)) in
    let original={(client "1" Lane.Ego_task_space) with space=Some space} in
    let reconnected={original with client_id=(client "2" Lane.Ego_task_space).client_id} in
    check bool "reconnect resumes numeric Space through fresh UUID" true
      (ok (G.resolve readback ~addon_instance_id:"addon-one" [reconnected])=reconnected.client_id);
    check bool "missing Space does not choose unrelated browser" true
      (Result.is_error (G.resolve readback ~addon_instance_id:"addon-one" [client "3" Lane.Webdriver_bidi]));
    check bool "different installation cannot borrow pin" true
      (Result.is_error (G.resolve readback ~addon_instance_id:"addon-two" [original]));
    check bool "ambiguous same Space connections require choice" true
      (Result.is_error (G.resolve readback ~addon_instance_id:"addon-one" [original;reconnected]));
    let store=Filename.concat (Masc.Workspace.masc_dir config) "browser_goal_spaces.json" in
    let before=Masc.Workspace.read_json_doc config store in
    check bool "missing Goal cannot create a pin" true (Result.is_error (bind "missing" {space with id=52}));
    check bool "missing Goal left committed bytes unchanged" true (before=Masc.Workspace.read_json_doc config store);
    let corrupt=`Assoc ["bindings",`List [G.to_json readback;G.to_json readback]] in
    Masc.Workspace.write_json config store corrupt;
    check bool "duplicate store is rejected on read" true (Result.is_error (G.find config ~goal_id:first));
    check bool "corrupt store never licenses a new assignment" true (Result.is_error (bind second {space with id=52}));
    check bool "corrupt evidence remains" true (Masc.Workspace.read_json_doc config store=Ok (Some corrupt)))

let test_multi_worker_inventory () =
  let module I=Masc.Browser_connection_inventory in
  let member=Yojson.Safe.Util.member in
  let off:Selection.work_browser={activity=Lane.Disabled;registered=false;session=Lane.Browser_closed;locate=false} in
  let observation instance_id clients : I.observation =
    {instance_id;published={Masc.Browser_addon_observation.clients;
      client_rows=List.map (fun client -> Masc.Browser_addon_observation.publish_client client ~space_observation:None) clients;
      automation=off;stagehand=off;unavailable=[]}} in
  let ego={(client "1" Lane.Ego_task_space) with browser=Lane.Ego_lite} and firefox=client "2" Lane.Webdriver_bidi in
  let first=observation "first" [ego] and second=observation "second" [firefox] in
  let report ?(issues=[]) observations=I.to_json (I.build ~observations ~issues) in
  let ids json=member "clients" json |> Yojson.Safe.Util.to_list
    |> List.map (fun row -> member "clientId" row |> Yojson.Safe.Util.to_string) in
  let code name json=member "automatic" json |> member name |> member "error" |> member "code" in
  let both=report [first;second] in
  check (list string) "separate workers retain both concrete clients"
    (List.map (fun (info:Lane.client_info) -> Lane.client_id_to_string info.client_id) [ego;firefox]) (ids both);
  check bool "complete cross-worker observations are distinguished" true (member "inventoryComplete" both=`Bool true);
  check bool "different logged-in clients require a choice" true (code "browse" both=`String "ambiguous_browsers");
  check bool "an owned work route never guesses a worker" true (code "work" both=`String "browser_binding_required");
  let single=report [first;observation "empty" []] in
  check bool "one cross-worker live candidate retains its UUID" true
    (member "automatic" single |> member "browse" |> member "data" |> member "clientId"
      =`String (Lane.client_id_to_string ego.client_id));
  let issue=I.Source_unready {instance_id="starting";message="worker has not started"} in
  let partial=report ~issues:[issue] [first] in
  check (list string) "a failed sibling does not erase valid manual choices" [Lane.client_id_to_string ego.client_id] (ids partial);
  List.iter (fun name -> check bool "incomplete observations never offer no-browser fallback" true
    (code name partial=`String "browser_binding_required")) ["browse";"work"];
  check bool "incomplete report is explicit" true (member "inventoryComplete" partial=`Bool false);
  let only_failure=report ~issues:[issue] [] in
  check bool "no readable workers is still incomplete" true
    (member "inventoryComplete" only_failure=`Bool false && code "browse" only_failure=`String "browser_binding_required");
  let duplicated=report [first;observation "duplicate" [ego];second] in
  check (list string) "every duplicate identity is excluded, other choices retained"
    [Lane.client_id_to_string firefox.client_id] (ids duplicated);
  let issues=match I.issues_of_json (member "inventoryIssues" duplicated) with
    | Ok issues -> issues | Error detail -> fail detail in
  check bool "duplicate issue carries the original owners" true
    (issues=[I.Duplicate_client {client_id=ego.client_id;instances=["duplicate";"first"]}]);
  check bool "unready issue wire round trip" true
    (I.issues_of_json (I.issues_to_json [issue])=Ok [issue]);
  List.iter (fun value -> check bool "unreadable issue metadata is not valid success" true
    (Result.is_error (I.issues_of_json value)))
    [`List [`Assoc ["kind",`String "unknown"]];
     `List [`Assoc ["kind",`String "unready";"kind",`String "unready";"instanceId",`String "x";"message",`String "bad"]]]

let () = run "browser selection" ["policy",[
  test_case "multiple worker inventory preserves choices and uncertainty" `Quick test_multi_worker_inventory;
  test_case "Goal Space assignment and reconnect preserve browser identity" `Quick test_goal_space_default;
  test_case "connected login and actual owned sessions" `Quick test_connections_and_sessions;
  test_case "exact browser binding" `Quick test_explicit_binding;
  test_case "native workflow retains its original browser" `Quick test_native_workflow_binding;
  test_case "work session lifecycle" `Quick test_work_lifecycle;
  test_case "capability and activity eligibility" `Quick test_eligibility;
  test_case "inactive owned session inspection and cleanup" `Quick test_inactive_session_cleanup;
  test_case "observation sends no command" `Quick test_observation_is_not_dispatch;
  test_case "selection wire contract" `Quick test_wire;
  test_case "ambiguous selection names its recovery" `Quick test_ambiguous_selection_recovery;
  test_case "receipts bind Space identity and reject forged context" `Quick test_space_binding;
  test_case "receipts retain the chosen client" `Quick test_bind_chosen_identity;
  test_case "a route names its browser in the snapshot" `Quick test_target_from_snapshot]]
