module B = Browser_lane
module Host = Browser_addon_host
module C = Browser_capabilities
module Legacy = Tool_misc_browser_lane
let ( let* ) = Result.bind
type projection = Raw | Inventory | Session | Scene of Browser_scene.request | Screenshot of int
  | Scoped_elements of string
type prepared = {preference:Browser_selection.preference;verb:B.verb;
  required_actions:C.operation list;projection:projection}
let fields allowed = function
  | `Assoc fields when List.for_all (fun (key,_) -> List.mem key allowed) fields -> Ok fields
  | _ -> Error "unknown browser tool argument"
let surface fields=Browser_surface.parse_request (`Assoc
  (List.filter (fun (key,_) -> List.mem key ["lane";"clientId";"tabId"]) fields))
let tab request=Option.to_result ~none:"an observed tabId is required" request.Browser_surface.tab_id
let bound request=match request.Browser_surface.route,request.tab_id with
  | (Browser_selection.Automatic|Exact (B.Live_route None)),Some _ ->
      Error (Browser_selection.error_message Binding_required)
  | (Automatic|Exact (B.Live_route None)),None
  | Exact (B.Live_route (Some _)|Automation_route|Stagehand_route),(None|Some _) -> Ok ()
let prepared ?(required_actions=[]) request projection verb=
  let* ()=bound request in
  Ok {preference=request.Browser_surface.route;verb;projection;required_actions}
let optional_int key fields=match List.assoc_opt key fields with
  | None -> Ok None | Some (`Int value) -> Ok (Some value)
  | Some _ -> Error (key ^ " must be an integer")
let absolute_url = function
  | Some (`String value) ->
      let uri=Uri.of_string value in
      (match Uri.scheme uri,Uri.host uri with
       | Some ("http"|"https"),Some host when host<>"" -> Ok value
       | (None|Some _),(None|Some _) -> Error "url must be an absolute HTTP(S) URL")
  | None|Some _ -> Error "url is required"
let prepare_read ~keeper_name json =
  let* fields=fields ["lane";"clientId";"tabId";"maxChars";"mode";"framePath";
    "scope";"expectedUrl";"navigationSource";"within"] json in
  let* request=surface fields in
  let* ()=bound request in
  let* frame_path=B.Action.parse_frame_path json in
  let* mode=Legacy.read_mode_of_args json in
  let* cap=optional_int "maxChars" fields in
  let* max_chars=Browser_page_script.text_cap cap in
  let* within=Browser_page_script.within_of_json (List.assoc_opt "within" fields) in
  let* ()=match mode,within with
    | `Elements,(None|Some _)
    | (`Text|`Scene|`Regions|`Screenshot|`Downloads|`Console|`Network|`Cookies|`Frames|`Dialog),None -> Ok ()
    | (`Text|`Scene|`Regions|`Screenshot|`Downloads|`Console|`Network|`Cookies|`Frames|`Dialog),Some _ ->
        Error "within applies to mode elements only" in
  let elements_projection=match within with None -> Raw | Some selector -> Scoped_elements selector in
  let top_scene=frame_path=[] && (match mode with `Scene|`Regions -> true
    | `Text|`Elements|`Screenshot|`Downloads|`Console|`Network|`Cookies|`Frames|`Dialog -> false) in
  let* ()=if not top_scene && List.exists (fun key -> List.mem_assoc key fields)
      ["scope";"expectedUrl";"navigationSource"] then
      Error "scope, expectedUrl and navigationSource support top-document scene or regions only" else Ok () in
  let contextual=frame_path<>[] || (match mode with `Frames|`Dialog -> true
    | `Text|`Elements|`Scene|`Regions|`Screenshot|`Downloads|`Console|`Network|`Cookies -> false) in
  if contextual then
    let* ()=match request.route with Browser_selection.Exact B.Automation_route -> Ok ()
      | Automatic|Exact (Live_route _|Stagehand_route) -> Error "frame and dialog reads require automation" in
    let* tab_id=tab request in
    let* mode=match mode with
      | `Text -> Ok (`Text max_chars) | `Elements -> Ok (`Elements within) | `Frames -> Ok `Frames
      | `Dialog when frame_path=[] -> Ok `Dialog
      | `Dialog|`Scene|`Regions|`Screenshot|`Downloads|`Console|`Network|`Cookies -> Error "framePath supports text, elements and frames" in
    let projection=match mode with `Elements _ -> elements_projection
      | `Text _|`Frames|`Dialog -> Raw in
    prepared request projection (B.Page_context {tab_id;frame_path;mode})
  else match mode with
  | (`Scene|`Regions as scene_mode) ->
      let view=match scene_mode with `Regions -> "regions" | `Scene -> "content" in
      let* scene=Browser_scene.parse_request (`Assoc (("view",`String view)::
        List.filter (fun (key,_) -> not (List.mem key ["mode";"framePath"])) fields)) in
      let* tab_id=tab request in
      prepared request (Scene scene) (B.Page_scene {tab_id;max_chars;view=scene.view;scope=scene.scope})
  | `Screenshot ->
      let* ()=Option.to_result ~none:"screenshot requires an owning Keeper" (Option.map (fun _ -> ()) keeper_name) in
      let* tab_id=tab request in prepared request (Screenshot tab_id) (B.Page_capture {tab_id})
  | `Downloads ->
      let* ()=match request.route with Browser_selection.Exact B.Automation_route -> Ok ()
        | Automatic|Exact (Live_route _|Stagehand_route) -> Error "downloads require automation" in
      let* tab_id=tab request in prepared request Raw (B.Page_downloads {tab_id})
  | `Console ->
      let* ()=match request.route with Browser_selection.Exact B.Automation_route -> Ok ()
        | Automatic|Exact (Live_route _|Stagehand_route) -> Error "console reads require automation" in
      let* tab_id=tab request in prepared request Raw (B.Page_console {tab_id})
  | `Network ->
      let* ()=match request.route with Browser_selection.Exact B.Automation_route -> Ok ()
        | Automatic|Exact (Live_route _|Stagehand_route) -> Error "network reads require automation" in
      let* tab_id=tab request in prepared request Raw (B.Page_network {tab_id})
  | `Cookies ->
      let* ()=match request.route with Browser_selection.Exact B.Automation_route -> Ok ()
        | Automatic|Exact (Live_route _|Stagehand_route) -> Error "cookie reads require automation" in
      let* tab_id=tab request in prepared request Raw (B.Page_cookies {tab_id})
  | `Text -> prepared request Raw (B.Page_read {tab_id=request.tab_id;max_chars=Some max_chars})
  | `Elements -> prepared request elements_projection (B.Page_elements {tab_id=request.tab_id;within})
  | `Frames|`Dialog -> Error "contextual read requires a frame or dialog mode"
let prepare ~keeper_name ~upload_paths tool json =
  let* _=Lane_addon_action.canonical json in
  match tool with
  | C.Read -> prepare_read ~keeper_name json
  | Interact ->
      let* request=Browser_interaction.parse json in
      Ok {preference=request.route;required_actions=[];projection=Raw;
        verb=B.Page_interact {tab_id=request.tab_id;expected_url=request.expected_url;action=request.action}}
  | Act ->
      let* action=B.Action.parse json in
      let* action=match action,upload_paths with
        | B.Action.On_tab ({interaction=Upload {selector;_};_} as target),Some paths ->
            Ok (B.Action.On_tab {target with interaction=Upload {selector;paths}})
        | On_tab {interaction=Upload _;_},None -> Error "upload requires an authoritative Keeper file context"
        | (Open_tab _|On_tab {interaction=(Click _|Fill _|Press _|Select _|Scroll _|Back|Forward|Reload
            |Close_tab|Accept_dialog _|Dismiss_dialog);_}),(None|Some _) -> Ok action in
      let* request=Legacy.tool_request json in
      let* ()=match action,request.route with
        | B.Action.Open_tab _,Browser_selection.Exact (B.Live_route None) ->
            Error "live open_tab requires an explicit observed clientId"
        | (Open_tab _|On_tab _),(Automatic|Exact (Live_route _|Automation_route|Stagehand_route)) -> Ok () in
      prepared request Raw (B.Page_act action)
  | Instruct ->
      let* fields=fields ("lane"::Legacy.instruct_arguments) json in
      let* verb=Legacy.instruct_verb fields in
      let* request=surface fields in
      let* ()=match request.route with
        | Browser_selection.Exact B.Stagehand_route -> Ok ()
        | Exact B.Automation_route when B.verb_allowed_on_automation verb -> Ok ()
        | Exact B.Automation_route -> Error "automation supports observe with selected locate Exact Output; act/extract require stagehand"
        | Automatic|Exact (B.Live_route _) -> Error "BrowserInstruct requires the observed automation or stagehand lane and tabId" in
      prepared request Raw verb
  | Tabs ->
      let* fields=fields ["lane";"clientId";"tabId";"requiredActions"] json in
      let* request=surface fields in
      let* required_actions=Legacy.required_actions json in
      let* ()=match request.tab_id,required_actions with Some _,_::_ ->
          Error "requiredActions applies only to initial discovery without tabId"
        | (None|Some _),[]|None,_::_ -> Ok () in
      prepared ~required_actions request Inventory B.Tabs_list
  | Session ->
      let* fields=fields ["lane";"clientId";"tabId";"requiredActions";"action";"headless"] json in
      let* request=surface fields in
      let* required_actions=Legacy.required_actions json in
      let* headless=match List.assoc_opt "headless" fields with None -> Ok (Some false)
        | Some (`Bool value) -> Ok (Some value)|Some _ -> Error "headless must be boolean" in
      let* verb=match List.assoc_opt "action" fields with
        | Some (`String "open") -> Ok (B.Session_open {headless})
        | Some (`String "close") when not (List.mem_assoc "requiredActions" fields) -> Ok B.Session_close
        | Some (`String "status") when not (List.mem_assoc "requiredActions" fields) -> Ok B.Session_status
        | None|Some _ -> Error "action must be open, close or status; requiredActions applies only to open" in
      prepared ~required_actions request Session verb
  | Goto ->
      let* fields=fields ["lane";"clientId";"tabId";"url"] json in
      let* request=surface fields in
      let* url=absolute_url (List.assoc_opt "url" fields) in
      let* ()=match request.route,request.tab_id with
        | Browser_selection.Exact (B.Live_route _),None ->
            Error "live navigation needs the tabId of a tab this connection opened with open_tab"
        | (Automatic|Exact (B.Live_route _|Automation_route|Stagehand_route)),(None|Some _) -> Ok () in
      prepared request Raw (B.Page_goto {url;tab_id=request.tab_id})
let restamp ~tool_name ~start_time : Tool_result.result -> Tool_result.result = function
  | Tool_result.Completed data -> Tool_result.Completed {data with tool_name;duration_ms=Tool_timing.elapsed_ms start_time}
  | Deferred data -> Tool_result.Deferred {data with tool_name;duration_ms=Tool_timing.elapsed_ms start_time}
  | Failed data -> Tool_result.Failed {data with tool_name;duration_ms=Tool_timing.elapsed_ms start_time}
let project ~base_path ~keeper_name ~started request (receipt:Host.receipt) =
  let annotate=Browser_binding.annotate receipt.binding in
  let capability_fields=["browserCapabilities",C.to_json (Browser_binding.backend receipt.binding);
    "requiredActions",`List (List.map (fun action -> `String (C.operation_name action)) request.required_actions)] in
  let with_capabilities = function
    | `Assoc fields -> Ok (`Assoc (capability_fields @ List.filter
        (fun (key,_) -> not (List.mem key ["browserCapabilities";"requiredActions"])) fields))
    | _ -> Error "browser inventory/session response must be an object" in
  match request.projection with
  | Raw -> Ok (annotate receipt.data)
  | Inventory ->
      let data=match receipt.data with `List tabs -> `Assoc ["tabs",`List tabs] | value -> value in
      with_capabilities (annotate data)
  | Session -> with_capabilities (annotate receipt.data)
  | Scene scene -> Browser_scene.project scene ~binding:receipt.binding ~started receipt.data
  | Scoped_elements selector ->
      let* data=Browser_page_script.check_scoped_elements ~within:(Some selector) receipt.data in
      Ok (annotate data)
  | Screenshot tab_id ->
      let* keeper_name=Option.to_result ~none:"screenshot requires an owning Keeper" keeper_name in
      let* data=Browser_surface.capture_from ~binding:receipt.binding ~tab_id ~started receipt.data
        |> Result.map_error Browser_surface.failure_message in
      Browser_screenshot.persist ~base_path ~keeper_name data
let handle ?upload_paths ~config ~access ~principal ~reserved ~keeper_name ~tool ~tool_name ~start_time json =
  let started=Mtime_clock.elapsed_ns () in
  let result=match prepare ~keeper_name ~upload_paths tool json with
    | Error detail -> Legacy.make_input_err ~tool_name ~start_time detail
    | Ok request ->
        match Host.connect ~config ~access ~principal ~reserved with
        | Error error -> Host.error_result ~start_time error
        | Ok host ->
            match Host.issue ?upload_paths ~required_actions:request.required_actions host ~preference:request.preference request.verb with
            | Error result -> result
            | Ok receipt ->
                (match project ~base_path:config.Workspace.base_path ~keeper_name ~started request receipt with
                 | Ok data -> Tool_result.make_ok ~tool_name ~start_time ~data ?metadata:receipt.raw_result._meta ()
                 | Error detail ->
                     let effect_disposition=match request.projection with
                       | Session -> Tool_result.Effect_outcome_unknown
                       | Raw|Inventory|Scene _|Screenshot _|Scoped_elements _ -> Tool_result.Proven_pre_effect in
                     (* A refused scoped read does not pass on the unscoped answer. *)
                     let data=match request.projection with
                       | Scoped_elements _ -> `Assoc ["error",`String detail]
                       | Session|Raw|Inventory|Scene _|Screenshot _ ->
                           Mcp_protocol.Mcp_types.tool_result_to_yojson receipt.raw_result in
                     Tool_result.make_err ~tool_name ~start_time
                     ~class_:Tool_result.Runtime_failure ~effect_disposition
                     ?metadata:receipt.raw_result._meta ~data detail) in
  restamp ~tool_name ~start_time result
