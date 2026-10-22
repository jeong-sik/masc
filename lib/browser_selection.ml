module Lane = Browser_lane
type preference = Automatic | Exact of Lane.route
type reason = Explicit_browser | Existing_login | Existing_work_session
  | Preferred_work_browser | Compatible_work_browser | Available_connected_browser
type selected = { route : Lane.route; reason : reason }
type error = Binding_required | No_available_browser | Ambiguous_browsers of Lane.route list
  | Required_actions_unavailable of { required : Browser_capabilities.operation list;
      candidates : (Lane.route * Browser_capabilities.operation list) list }
  | Unsupported_required_actions of { route : Lane.route; missing : Browser_capabilities.operation list }
type work_browser = { activity : Lane.activity; registered : bool; session : Lane.session_observation; locate : bool }
type snapshot = { live_activity : Lane.activity; live_clients : Lane.client_info list
  ; automation : work_browser; stagehand : work_browser }

let reason_to_wire = function
  | Explicit_browser -> "explicit_browser" | Existing_login -> "existing_login"
  | Existing_work_session -> "existing_work_session" | Preferred_work_browser -> "preferred_work_browser"
  | Compatible_work_browser -> "compatible_work_browser" | Available_connected_browser -> "available_connected_browser"
let reason_of_wire = function
  | "explicit_browser" -> Some Explicit_browser | "existing_login" -> Some Existing_login
  | "existing_work_session" -> Some Existing_work_session | "preferred_work_browser" -> Some Preferred_work_browser
  | "compatible_work_browser" -> Some Compatible_work_browser | "available_connected_browser" -> Some Available_connected_browser
  | _ -> None
let route_fields = function
  | Lane.Live_route client -> ["lane",`String "live";"clientId",(match client with
      | Some id -> `String (Lane.client_id_to_string id) | None -> `Null)]
  | Lane.Automation_route -> ["lane",`String "automation";"clientId",`Null]
  | Lane.Stagehand_route -> ["lane",`String "stagehand";"clientId",`Null]
let to_json selected = `Assoc (route_fields selected.route @ ["reason",`String (reason_to_wire selected.reason)])
let route_of_target = function
    | Lane.Automation -> Lane.Automation_route | Lane.Stagehand -> Lane.Stagehand_route
    | Lane.Live_client client -> Lane.Live_route (Some client.info.client_id)
let bind_target selected target = {selected with route=route_of_target target}
let operations_json actions = `List (List.map (fun action -> `String (Browser_capabilities.operation_name action)) actions)
let error_message = function
  | Binding_required -> "This tab or document belongs to a browser. Repeat its observed lane and clientId."
  | No_available_browser -> "No compatible browser is available. Connect a browser or explicitly open a work session."
  | Ambiguous_browsers _ -> "More than one browser is available. Select its lane and, for a connected browser, clientId."
  | Required_actions_unavailable _ -> "No available browser implements all requiredActions. Inspect candidates and their missingActions; explicitly open a compatible work session or change the task requirements."
  | Unsupported_required_actions _ -> "The selected browser does not implement all requiredActions. Its owner was preserved and no command was dispatched."
let choice_case = function
  | Binding_required -> Lane.Binding_required_case | No_available_browser -> Lane.No_available_browser_case
  | Ambiguous_browsers _ -> Lane.Ambiguous_browsers_case
  | Required_actions_unavailable _ -> Lane.Required_actions_unavailable_case
  | Unsupported_required_actions _ -> Lane.Unsupported_required_actions_case
let error_to_json error = `Assoc (["code",`String (Lane.choice_case_code (choice_case error));
  "message",`String (error_message error)]
  @ match error with Ambiguous_browsers routes -> ["browsers",`List (List.map (fun route -> `Assoc (route_fields route)) routes)]
    | Required_actions_unavailable {required;candidates} ->
        ["requiredActions",operations_json required;"candidates",`List (List.map (fun (route,missing) ->
          `Assoc (route_fields route @ ["missingActions",operations_json missing])) candidates)]
    | Unsupported_required_actions {route;missing} -> route_fields route @ ["missingActions",operations_json missing]
    | Binding_required | No_available_browser -> [])

let snapshot () =
  let work lane =
    let observed = Lane.inventory_observation (Lane.server_lane_name lane) in
    let registered = match observed.backend with Lane.Executor_registered value -> value | Lane.Live_clients _ -> false in
    let locate=match lane with Lane.Server_automation -> Lane.automation_locate_available ()
      | Lane.Server_stagehand -> Lane.stagehand_models_available () in
    {activity=observed.activity;registered;session=Lane.server_session_observation lane;locate} in
  {live_activity=Lane.activity Lane.Lane_name.Live;live_clients=Lane.connected_clients ();
   automation=work Lane.Server_automation;stagehand=work Lane.Server_stagehand}

let enabled = function Lane.Enabled -> true | Lane.Disabled | Lane.Unobserved -> false
let stagehand_serves verb = Lane.verb_allowed_on_stagehand verb && match verb with
  | Lane.Page_interact {action=(Lane.Drag {duration_ms;_} | Lane.Drag_to {duration_ms;_});_} -> duration_ms=0
  | Lane.Page_interact {action=(Lane.Activate_tab | Lane.Set_zoom _);_} -> false
  (* Stagehand has no call that gives the browser its own size back. *)
  | Lane.Page_interact {action=Lane.Set_viewport Lane.Browser_default;_} -> false
  | Lane.Page_interact {action=(Lane.Tap_at _ | Lane.Swipe _);_} -> false
  | Lane.Page_interact {action=Lane.Set_viewport (Lane.Fit _);_} -> true
  | Lane.Tabs_list | Lane.Page_read _ | Lane.Page_document _ | Lane.Page_downloads _ | Lane.Page_console _ | Lane.Page_network _ | Lane.Page_cookies _
  | Lane.Page_capture _ | Lane.Page_scene _ | Lane.Session_open _ | Lane.Session_close | Lane.Session_status
  | Lane.Page_goto _ | Lane.Page_elements _ | Lane.Page_act _ | Lane.Page_context _ | Lane.Page_instruct _
  | Lane.Page_locate _ | Lane.Page_extract _
  | Lane.Page_interact {action=(Lane.Double_click _ | Lane.Double_click_at _ | Lane.Type_text _ | Lane.Press_key _ | Lane.Click _ | Lane.Fill _ | Lane.Select_option _ | Lane.Scroll _ | Lane.Hover _ | Lane.Hover_at _
      | Lane.Click_at _ | Lane.Scroll_at _ | Lane.Follow_link _ | Lane.Click_node _ | Lane.Fill_node _);_} -> true
let automation_serves verb = Lane.verb_allowed_on_automation verb && match verb with
  | Lane.Page_interact {action=(Lane.Activate_tab | Lane.Set_zoom _ | Lane.Set_viewport _);_} -> false
  | Lane.Tabs_list | Lane.Page_read _ | Lane.Page_document _ | Lane.Page_downloads _ | Lane.Page_console _ | Lane.Page_network _ | Lane.Page_cookies _
  | Lane.Page_capture _ | Lane.Page_scene _ | Lane.Session_open _ | Lane.Session_close | Lane.Session_status
  | Lane.Page_goto _ | Lane.Page_elements _ | Lane.Page_act _ | Lane.Page_context _ | Lane.Page_instruct _
  | Lane.Page_locate _ | Lane.Page_extract _
  | Lane.Page_interact {action=(Lane.Double_click _ | Lane.Double_click_at _ | Lane.Type_text _ | Lane.Press_key _ | Lane.Click _ | Lane.Fill _ | Lane.Select_option _ | Lane.Scroll _ | Lane.Hover _ | Lane.Drag_to _
      | Lane.Hover_at _ | Lane.Click_at _ | Lane.Scroll_at _ | Lane.Drag _ | Lane.Follow_link _
      | Lane.Tap_at _ | Lane.Swipe _
      | Lane.Click_node _ | Lane.Fill_node _);_} -> true

let choose_candidates ~verb ~bound ~snapshot preference =
  let lifecycle_inspection_or_cleanup = match verb with
    | Lane.Session_status | Lane.Session_close -> true
    | Lane.Session_open _ | Lane.Page_goto _ | Lane.Tabs_list | Lane.Page_read _
    | Lane.Page_document _ | Lane.Page_downloads _ | Lane.Page_console _ | Lane.Page_network _ | Lane.Page_cookies _ | Lane.Page_capture _ | Lane.Page_scene _
    | Lane.Page_interact _ | Lane.Page_elements _ | Lane.Page_act _ | Lane.Page_context _
    | Lane.Page_instruct _ | Lane.Page_locate _ | Lane.Page_extract _ -> false in
  let ready state = state.registered &&
    (enabled state.activity || lifecycle_inspection_or_cleanup) in
  let eligible route state = ready state && match route with
    | Lane.Stagehand_route -> stagehand_serves verb && (not (Lane.verb_uses_model verb) || state.locate)
    | Lane.Automation_route -> automation_serves verb &&
        (match verb with Lane.Page_locate _ -> state.locate
         | Lane.Tabs_list|Page_read _|Page_document _|Page_downloads _ | Page_console _ | Page_network _ | Page_cookies _|Page_capture _|Page_scene _|Page_interact _
         | Session_open _|Session_close|Session_status|Page_goto _|Page_elements _|Page_act _|Page_context _
         | Page_instruct _|Page_extract _ -> true)
    | Lane.Live_route _ -> false in
  let opened route state = eligible route state && match state.session with
    | Lane.Browser_open -> true | Lane.Browser_closed | Lane.Browser_changing | Lane.Browser_unknown -> false in
  let owned = List.filter_map (fun (route,state) -> if opened route state then Some route else None)
      [Lane.Stagehand_route,snapshot.stagehand;Lane.Automation_route,snapshot.automation] in
  let one reason = function
    | [] -> Error No_available_browser
    | [route] -> Ok {route;reason}
    | routes -> Error (Ambiguous_browsers routes) in
  let configured () =
    let idle state = enabled state.activity && match state.session with Lane.Browser_closed -> true
      | Lane.Browser_open | Lane.Browser_changing | Lane.Browser_unknown -> false in
    if eligible Lane.Stagehand_route snapshot.stagehand && idle snapshot.stagehand
    then Ok {route=Lane.Stagehand_route;reason=Preferred_work_browser}
    else if eligible Lane.Automation_route snapshot.automation && idle snapshot.automation
    then Ok {route=Lane.Automation_route;reason=Compatible_work_browser}
    else Error No_available_browser in
  let connected transport =
    if not (enabled snapshot.live_activity) then [] else
    match Lane.live_capability verb with
    | None -> []
    | Some capability -> List.filter_map (fun (info : Lane.client_info) ->
      if info.transport=transport && Lane.live_transport_serves info.transport capability
      then Some (Lane.Live_route (Some info.client_id)) else None) snapshot.live_clients in
  match preference with
  | Exact (Lane.Live_route None) when bound -> Error Binding_required
  | Exact ((Lane.Live_route (Some _ | None) | Lane.Automation_route | Lane.Stagehand_route) as route) ->
      Ok {route;reason=Explicit_browser}
  | Automatic when bound -> Error Binding_required
  | Automatic -> match verb with
    | Lane.Session_open _ | Lane.Session_status -> (match owned with [] -> configured () | _::_ -> one Existing_work_session owned)
    | Lane.Session_close | Lane.Page_goto _ -> one Existing_work_session owned
    | Lane.Tabs_list | Lane.Page_read _ | Lane.Page_document _ | Lane.Page_downloads _ | Lane.Page_console _ | Lane.Page_network _ | Lane.Page_cookies _
    | Lane.Page_capture _ | Lane.Page_scene _ | Lane.Page_interact _ | Lane.Page_elements _
    | Lane.Page_act _ | Lane.Page_context _ | Lane.Page_instruct _ | Lane.Page_locate _ | Lane.Page_extract _ ->
      (* Both carry a login: the Keeper's own Firefox over BiDi, and the
         operator's ego profile, whose cookies every task space shares. With
         one of each connected the choice is the caller's. *)
      match connected Lane.Webdriver_bidi @ connected Lane.Ego_task_space with
      | _::_ as browsers -> one Existing_login browsers
      | [] -> match owned with
        | _::_ -> one Existing_work_session owned
        | [] -> one Available_connected_browser (connected Lane.Web_extension)
let effective_missing ~models backend required =
  let missing=Browser_capabilities.missing_operations backend required in
  List.filter (fun operation -> List.mem operation missing ||
    (operation=Browser_capabilities.Sentence_action && not models)) required
let choose ?(required_actions=[]) ~verb ~bound ~snapshot preference =
  match preference with
  | Exact _ -> choose_candidates ~verb ~bound ~snapshot preference
  | Automatic when bound || required_actions=[] -> choose_candidates ~verb ~bound ~snapshot preference
  | Automatic ->
    let missing ~models backend = effective_missing ~models backend required_actions in
    let candidates = List.map (fun (info : Lane.client_info) ->
        Lane.Live_route (Some info.client_id),missing ~models:false (Browser_capabilities.Connected info.transport)) snapshot.live_clients
      @ List.filter_map (fun (route,backend,state) -> if state.registered then Some (route,missing ~models:state.locate backend) else None)
          [Lane.Stagehand_route,Browser_capabilities.Owned_chromium,snapshot.stagehand;
           Lane.Automation_route,Browser_capabilities.Owned_gecko,snapshot.automation] in
    let filter_work backend state = {state with registered=state.registered && missing ~models:state.locate backend=[]} in
    let filtered = {snapshot with
      live_clients=List.filter (fun (info : Lane.client_info) -> missing ~models:false (Browser_capabilities.Connected info.transport)=[]) snapshot.live_clients;
      stagehand=filter_work Browser_capabilities.Owned_chromium snapshot.stagehand;
      automation=filter_work Browser_capabilities.Owned_gecko snapshot.automation} in
    (match choose_candidates ~verb ~bound ~snapshot:filtered preference with
     | Error No_available_browser -> Error (Required_actions_unavailable {required=required_actions;candidates})
     | (Ok _ | Error (Binding_required | Ambiguous_browsers _ | Required_actions_unavailable _ | Unsupported_required_actions _)) as result -> result)
let require_target required target =
  let models=match target with Lane.Stagehand -> Lane.stagehand_models_available ()
    | Lane.Automation | Lane.Live_client _ -> false in
  match effective_missing ~models (Browser_capabilities.backend_of_target target) required with
  | [] -> Ok ()
  | missing -> Error (Unsupported_required_actions {route=route_of_target target;missing})
let resolve ?(required_actions=[]) ~verb ~bound preference = match preference with
  | Exact (Lane.Live_route None) when bound -> Error Binding_required
  | Exact ((Lane.Live_route (Some _ | None) | Lane.Automation_route | Lane.Stagehand_route) as route) ->
      Ok {route;reason=Explicit_browser}
  | Automatic when bound -> Error Binding_required
  | Automatic -> choose ~required_actions ~verb ~bound ~snapshot:(snapshot ()) preference
