module Lane = Browser_lane
type preference = Automatic | Exact of Lane.route
type reason = Explicit_browser | Existing_login | Existing_work_session
  | Compatible_work_browser | Available_connected_browser
[@@deriving enumerate]
type selected = { route : Lane.route; reason : reason }
type error = Binding_required | No_available_browser | Ambiguous_browsers of Lane.route list
  | Required_actions_unavailable of { required : Browser_capabilities.operation list;
      candidates : (Lane.route * Browser_capabilities.operation list) list }
  | Unsupported_required_actions of { route : Lane.route; missing : Browser_capabilities.operation list }
type work_browser = { activity : Lane.activity; registered : bool; session : Lane.session_observation; locate : bool }
type snapshot = { live_activity : Lane.activity; live_clients : Lane.client_info list
  ; live_space_presence : (Lane.client_id * Browser_ego_space_observation.presence) list
  ; automation : work_browser }

let reason_to_wire = function
  | Explicit_browser -> "explicit_browser" | Existing_login -> "existing_login"
  | Existing_work_session -> "existing_work_session"
  | Compatible_work_browser -> "compatible_work_browser" | Available_connected_browser -> "available_connected_browser"
let reason_of_wire s = List.find_opt (fun v -> String.equal (reason_to_wire v) s) all_of_reason
let route_fields = function
  | Lane.Live_route client -> ["lane",`String "live";"clientId",(match client with
      | Some id -> `String (Lane.client_id_to_string id) | None -> `Null)]
  | Lane.Automation_route -> ["lane",`String "automation";"clientId",`Null]
let to_json selected = `Assoc (route_fields selected.route @ ["reason",`String (reason_to_wire selected.reason)])
type browser = Owned_automation | Connected of Lane.client_info
let route_of_browser = function
  | Owned_automation -> Lane.Automation_route
  | Connected info -> Lane.Live_route (Some info.client_id)
let backend_of_browser = function
  | Owned_automation -> Browser_capabilities.Owned_gecko
  | Connected info -> Browser_capabilities.Connected info.transport
let bind selected browser = {selected with route=route_of_browser browser}
let operations_json actions = `List (List.map (fun action -> `String (Browser_capabilities.operation_name action)) actions)
let error_message = function
  | Binding_required -> "This tab or document belongs to a browser. Repeat its observed lane and clientId."
  | No_available_browser -> "No compatible browser is available. Connect a browser or explicitly open a work session."
  | Ambiguous_browsers _ -> "More than one browser is available. No command was dispatched; this is a selection refusal, not a browser outage. Repeat the same tool with lane and, for a live browser, clientId from one entry in the returned browsers list."
  | Required_actions_unavailable _ -> "No available browser implements all requiredActions. Inspect candidates and their missingActions; explicitly open a compatible work session or change the task requirements."
  | Unsupported_required_actions _ -> "The selected browser does not implement all requiredActions. Its owner was preserved and no command was dispatched."
let choice_case = function
  | Binding_required -> Lane.Binding_required_case | No_available_browser -> Lane.No_available_browser_case
  | Ambiguous_browsers _ -> Lane.Ambiguous_browsers_case
  | Required_actions_unavailable _ -> Lane.Required_actions_unavailable_case
  | Unsupported_required_actions _ -> Lane.Unsupported_required_actions_case
let error_to_json error = `Assoc (["code",`String (Lane.choice_case_code (choice_case error));
  "message",`String (error_message error)]
  @ match error with Ambiguous_browsers routes ->
        ["browsers",`List (List.map (fun route -> `Assoc (route_fields route)) routes);
         "recovery",`Assoc ["action",`String "repeat_same_tool_with_selected_browser";
           "commandDispatched",`Bool false;"failureScope",`String "browser_selection";
           "browserChoices",`String "browsers"]]
    | Required_actions_unavailable {required;candidates} ->
        ["requiredActions",operations_json required;"candidates",`List (List.map (fun (route,missing) ->
          `Assoc (route_fields route @ ["missingActions",operations_json missing])) candidates)]
    | Unsupported_required_actions {route;missing} -> route_fields route @ ["missingActions",operations_json missing]
    | Binding_required | No_available_browser -> [])

let enabled = function Lane.Enabled -> true | Lane.Disabled | Lane.Unobserved -> false
let automation_serves verb = Lane.verb_allowed_on_automation verb && match verb with
  | Lane.Page_native_workflow _ -> false
  | Lane.Page_interact {action=(Lane.Activate_tab | Lane.Set_zoom _ | Lane.Click_target _ | Lane.Fill_target _ | Lane.Hover_target _ | Lane.Double_click_target _);_} -> false
  | Lane.Tabs_list | Lane.Page_read _ | Lane.Page_document _ | Lane.Page_downloads _ | Lane.Page_console _ | Lane.Page_network _ | Lane.Page_cookies _
  | Lane.Page_capture _ | Lane.Page_scene _ | Lane.Page_snapshot _ | Lane.Session_open _ | Lane.Session_close | Lane.Session_status
  | Lane.Page_goto _ | Lane.Page_elements _ | Lane.Page_act _ | Lane.Page_context _
  | Lane.Page_locate _
  | Lane.Page_interact {action=(Lane.Set_viewport _ | Lane.Double_click _ | Lane.Double_click_at _ | Lane.Type_text _ | Lane.Press_key _ | Lane.Click _ | Lane.Fill _ | Lane.Select_option _ | Lane.Scroll _ | Lane.Hover _ | Lane.Drag_to _
      | Lane.Hover_at _ | Lane.Click_at _ | Lane.Scroll_at _ | Lane.Drag _ | Lane.Follow_link _
      | Lane.Tap_at _ | Lane.Swipe _
      | Lane.Click_node _ | Lane.Fill_node _);_} -> true

let choose_candidates ~verb ~bound ~snapshot preference =
  let lifecycle_inspection_or_cleanup = match verb with
    | Lane.Session_status | Lane.Session_close -> true
    | Lane.Session_open _ | Lane.Page_goto _ | Lane.Tabs_list | Lane.Page_read _
    | Lane.Page_document _ | Lane.Page_downloads _ | Lane.Page_console _ | Lane.Page_network _ | Lane.Page_cookies _ | Lane.Page_capture _ | Lane.Page_scene _ | Lane.Page_snapshot _
    | Lane.Page_interact _|Page_native_workflow _ | Lane.Page_elements _ | Lane.Page_act _ | Lane.Page_context _
    | Lane.Page_locate _ -> false in
  let ready state = state.registered &&
    (enabled state.activity || lifecycle_inspection_or_cleanup) in
  let eligible route state = ready state && match route with
    | Lane.Automation_route -> automation_serves verb &&
        (match verb with Lane.Page_locate _ -> state.locate
         | Lane.Tabs_list|Page_read _|Page_document _|Page_downloads _ | Page_console _ | Page_network _ | Page_cookies _|Page_capture _|Page_scene _|Page_snapshot _|Page_interact _|Page_native_workflow _
         | Session_open _|Session_close|Session_status|Page_goto _|Page_elements _|Page_act _|Page_context _ -> true)
    | Lane.Live_route _ -> false in
  let opened route state = eligible route state && match state.session with
    | Lane.Browser_open -> true | Lane.Browser_closed | Lane.Browser_changing | Lane.Browser_unknown -> false in
  let owned = List.filter_map (fun (route,state) -> if opened route state then Some route else None)
      [Lane.Automation_route,snapshot.automation] in
  let one reason = function
    | [] -> Error No_available_browser
    | [route] -> Ok {route;reason}
    | routes -> Error (Ambiguous_browsers routes) in
  let configured () =
    let idle state = enabled state.activity && match state.session with Lane.Browser_closed -> true
      | Lane.Browser_open | Lane.Browser_changing | Lane.Browser_unknown -> false in
    if eligible Lane.Automation_route snapshot.automation && idle snapshot.automation
    then Ok {route=Lane.Automation_route;reason=Compatible_work_browser}
    else Error No_available_browser in
  let connected transport =
    if not (enabled snapshot.live_activity) then [] else
    match Lane.live_capability verb with
    | None -> []
    | Some capability -> List.filter_map (fun (info : Lane.client_info) ->
      let space_available=match info.transport with
        | Lane.Web_extension|Webdriver_bidi -> true
        | Ego_task_space ->
          (match info.space,List.assoc_opt info.client_id snapshot.live_space_presence with
           | Some space,Some {space_id;state=Present;_} -> space.id=space_id
           | (Some _|None),(Some {state=Missing|Unknown _;_}|None)
           | None,Some {state=Present;_} -> false) in
      if space_available && info.transport=transport && Lane.live_transport_serves info.transport capability
      then Some (Lane.Live_route (Some info.client_id)) else None) snapshot.live_clients in
  match preference with
  | Exact (Lane.Live_route None) when bound -> Error Binding_required
  | Exact ((Lane.Live_route (Some _ | None) | Lane.Automation_route) as route) ->
      Ok {route;reason=Explicit_browser}
  | Automatic when bound -> Error Binding_required
  | Automatic -> match verb with
    | Lane.Session_open _ | Lane.Session_status -> (match owned with [] -> configured () | _::_ -> one Existing_work_session owned)
    | Lane.Session_close | Lane.Page_goto _ -> one Existing_work_session owned
    | Lane.Tabs_list | Lane.Page_read _ | Lane.Page_document _ | Lane.Page_downloads _ | Lane.Page_console _ | Lane.Page_network _ | Lane.Page_cookies _
    | Lane.Page_capture _ | Lane.Page_scene _ | Lane.Page_snapshot _ | Lane.Page_interact _|Page_native_workflow _ | Lane.Page_elements _
    | Lane.Page_act _ | Lane.Page_context _ | Lane.Page_locate _ ->
      (* Both carry a login: the Keeper's own Firefox over BiDi, and the
         operator's ego profile, whose cookies every task space shares. With
         one of each connected the choice is the caller's. *)
      match connected Lane.Webdriver_bidi @ connected Lane.Ego_task_space with
      | _::_ as browsers -> one Existing_login browsers
      | [] -> match owned with
        | _::_ -> one Existing_work_session owned
        | [] -> one Available_connected_browser (connected Lane.Web_extension)
let effective_missing backend required =
  let missing=Browser_capabilities.missing_operations backend required in
  List.filter (fun operation -> List.mem operation missing) required
let choose ?(required_actions=[]) ~verb ~bound ~snapshot preference =
  match preference with
  | Exact _ -> choose_candidates ~verb ~bound ~snapshot preference
  | Automatic when bound || required_actions=[] -> choose_candidates ~verb ~bound ~snapshot preference
  | Automatic ->
    let missing backend = effective_missing backend required_actions in
    let candidates = List.map (fun (info : Lane.client_info) ->
        Lane.Live_route (Some info.client_id),missing (Browser_capabilities.Connected info.transport)) snapshot.live_clients
      @ List.filter_map (fun (route,backend,state) -> if state.registered then Some (route,missing backend) else None)
          [Lane.Automation_route,Browser_capabilities.Owned_gecko,snapshot.automation] in
    let filter_work backend state = {state with registered=state.registered && missing backend=[]} in
    let filtered = {snapshot with
      live_clients=List.filter (fun (info : Lane.client_info) -> missing (Browser_capabilities.Connected info.transport)=[]) snapshot.live_clients;
      automation=filter_work Browser_capabilities.Owned_gecko snapshot.automation} in
    (match choose_candidates ~verb ~bound ~snapshot:filtered preference with
     | Error No_available_browser -> Error (Required_actions_unavailable {required=required_actions;candidates})
     | (Ok _ | Error (Binding_required | Ambiguous_browsers _ | Required_actions_unavailable _ | Unsupported_required_actions _)) as result -> result)
let require required browser =
  match effective_missing (backend_of_browser browser) required with
  | [] -> Ok ()
  | missing -> Error (Unsupported_required_actions {route=route_of_browser browser;missing})
let target ~verb ~snapshot route =
  let activity=match route with
    | Lane.Automation_route -> snapshot.automation.activity
    | Lane.Live_route _ -> snapshot.live_activity in
  match Lane.activity_rejection_with ~activity (Lane.route_lane_name route) verb with
  | Some rejection -> Error (Lane.Activity_rejected rejection)
  | None -> match route with
    | Lane.Automation_route -> Ok Owned_automation
    | Lane.Live_route (Some id) ->
      (match List.find_opt (fun (info : Lane.client_info) -> Uuidm.equal info.client_id id) snapshot.live_clients with
       | Some info -> Ok (Connected info)
       | None -> Error (Lane.Selected_client_disconnected id))
    | Lane.Live_route None ->
      match snapshot.live_clients with
      | [info] -> Ok (Connected info)
      | [] -> Error Lane.No_live_client
      | _ :: _ :: _ as several ->
        Error (Lane.Ambiguous_clients (List.map (fun (info : Lane.client_info) -> info.client_id) several
          |> List.sort (fun left right -> String.compare (Lane.client_id_to_string left) (Lane.client_id_to_string right))))
let bound = function
  | Lane.Page_read {tab_id;_} | Lane.Page_elements {tab_id;_} -> Option.is_some tab_id
  | Lane.Page_act (Lane.Action.Open_tab _ | Lane.Action.Open_window _ | Lane.Action.Control _) | Lane.Tabs_list | Lane.Session_open _ | Lane.Session_status -> false
  | Lane.Page_document _ | Lane.Page_downloads _ | Lane.Page_console _ | Lane.Page_network _ | Lane.Page_cookies _ | Lane.Page_capture _
  | Lane.Page_scene _ | Lane.Page_snapshot _ | Lane.Page_native_workflow _ | Lane.Page_interact _ | Lane.Session_close | Lane.Page_goto _ | Lane.Page_act (Lane.Action.On_tab _)
  | Lane.Page_context _ | Lane.Page_locate _ -> true
