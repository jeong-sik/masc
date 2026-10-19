module Lane = Browser_lane
type preference = Automatic | Exact of Lane.route
type reason = Explicit_browser | Existing_login | Existing_work_session
  | Preferred_work_browser | Compatible_work_browser | Available_connected_browser
type selected = { route : Lane.route; reason : reason }
type error = Binding_required | No_available_browser | Ambiguous_browsers of Lane.route list
type work_browser = { activity : Lane.activity; registered : bool; session : Lane.session_observation }
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
let bind_target selected target =
  let route = match target with
    | Lane.Automation -> Lane.Automation_route | Lane.Stagehand -> Lane.Stagehand_route
    | Lane.Live_client client -> Lane.Live_route (Some client.info.client_id) in
  {selected with route}
let error_message = function
  | Binding_required -> "This tab or document belongs to a browser. Repeat its observed lane and clientId."
  | No_available_browser -> "No compatible browser is available. Connect a browser or explicitly open a work session."
  | Ambiguous_browsers _ -> "More than one browser is available. Select its lane and, for a connected browser, clientId."
let error_to_json error = `Assoc (["code",`String (match error with
  | Binding_required -> "browser_binding_required" | No_available_browser -> "no_available_browser"
  | Ambiguous_browsers _ -> "ambiguous_browsers");"message",`String (error_message error)]
  @ match error with Ambiguous_browsers routes -> ["browsers",`List (List.map (fun route -> `Assoc (route_fields route)) routes)]
    | Binding_required | No_available_browser -> [])

let snapshot () =
  let work lane =
    let observed = Lane.inventory_observation (Lane.server_lane_name lane) in
    let registered = match observed.backend with Lane.Executor_registered value -> value | Lane.Live_clients _ -> false in
    {activity=observed.activity;registered;session=Lane.server_session_observation lane} in
  {live_activity=Lane.activity Lane.Lane_name.Live;live_clients=Lane.connected_clients ();
   automation=work Lane.Server_automation;stagehand=work Lane.Server_stagehand}

let enabled = function Lane.Enabled -> true | Lane.Disabled | Lane.Unobserved -> false
let stagehand_serves verb = Lane.verb_allowed_on_stagehand verb && match verb with
  | Lane.Page_interact {action=(Lane.Drag {duration_ms;_} | Lane.Drag_to {duration_ms;_});_} -> duration_ms=0
  | Lane.Page_interact {action=Lane.Activate_tab;_} -> false
  | Lane.Tabs_list | Lane.Page_read _ | Lane.Page_document _ | Lane.Page_downloads _
  | Lane.Page_capture _ | Lane.Page_scene _ | Lane.Session_open _ | Lane.Session_close | Lane.Session_status
  | Lane.Page_goto _ | Lane.Page_elements _ | Lane.Page_act _ | Lane.Page_context _ | Lane.Page_instruct _
  | Lane.Page_locate _ | Lane.Page_extract _
  | Lane.Page_interact {action=(Lane.Click _ | Lane.Fill _ | Lane.Scroll _ | Lane.Hover _ | Lane.Hover_at _
      | Lane.Click_at _ | Lane.Scroll_at _ | Lane.Follow_link _ | Lane.Click_node _ | Lane.Fill_node _);_} -> true
let automation_serves verb = Lane.verb_allowed_on_automation verb && match verb with
  | Lane.Page_interact {action=Lane.Activate_tab;_} -> false
  | Lane.Tabs_list | Lane.Page_read _ | Lane.Page_document _ | Lane.Page_downloads _
  | Lane.Page_capture _ | Lane.Page_scene _ | Lane.Session_open _ | Lane.Session_close | Lane.Session_status
  | Lane.Page_goto _ | Lane.Page_elements _ | Lane.Page_act _ | Lane.Page_context _ | Lane.Page_instruct _
  | Lane.Page_locate _ | Lane.Page_extract _
  | Lane.Page_interact {action=(Lane.Click _ | Lane.Fill _ | Lane.Scroll _ | Lane.Hover _ | Lane.Drag_to _
      | Lane.Hover_at _ | Lane.Click_at _ | Lane.Scroll_at _ | Lane.Drag _ | Lane.Follow_link _
      | Lane.Click_node _ | Lane.Fill_node _);_} -> true

let choose ~verb ~bound ~snapshot preference =
  let lifecycle_inspection_or_cleanup = match verb with
    | Lane.Session_status | Lane.Session_close -> true
    | Lane.Session_open _ | Lane.Page_goto _ | Lane.Tabs_list | Lane.Page_read _
    | Lane.Page_document _ | Lane.Page_downloads _ | Lane.Page_capture _ | Lane.Page_scene _
    | Lane.Page_interact _ | Lane.Page_elements _ | Lane.Page_act _ | Lane.Page_context _
    | Lane.Page_instruct _ | Lane.Page_locate _ | Lane.Page_extract _ -> false in
  let ready state = state.registered &&
    (enabled state.activity || lifecycle_inspection_or_cleanup) in
  let eligible route state = ready state && match route with
    | Lane.Stagehand_route -> stagehand_serves verb
    | Lane.Automation_route -> automation_serves verb
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
  | Exact route -> Ok {route;reason=Explicit_browser}
  | Automatic when bound -> Error Binding_required
  | Automatic -> match verb with
    | Lane.Session_open _ | Lane.Session_status -> (match owned with [] -> configured () | _::_ -> one Existing_work_session owned)
    | Lane.Session_close | Lane.Page_goto _ -> one Existing_work_session owned
    | Lane.Tabs_list | Lane.Page_read _ | Lane.Page_document _ | Lane.Page_downloads _
    | Lane.Page_capture _ | Lane.Page_scene _ | Lane.Page_interact _ | Lane.Page_elements _
    | Lane.Page_act _ | Lane.Page_context _ | Lane.Page_instruct _ | Lane.Page_locate _ | Lane.Page_extract _ ->
      match connected Lane.Webdriver_bidi with
      | _::_ as browsers -> one Existing_login browsers
      | [] -> match owned with
        | _::_ -> one Existing_work_session owned
        | [] -> one Available_connected_browser (connected Lane.Web_extension)
let resolve ~verb ~bound preference = match preference with
  | Exact route -> Ok {route;reason=Explicit_browser}
  | Automatic when bound -> Error Binding_required
  | Automatic -> choose ~verb ~bound ~snapshot:(snapshot ()) preference
