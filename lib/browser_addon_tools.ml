module B = Browser_lane
module Host = Browser_addon_host
module C = Browser_capabilities
module Legacy = Tool_misc_browser_lane
open Result.Syntax
type projection = Raw | Inventory | Session | Scene of Browser_scene.request | Screenshot of int * B.Capture.t option
  | Scoped_elements of B.elements_filter
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
let prepare_read json =
  let* fields=fields ["lane";"clientId";"tabId";"maxChars";"mode";"framePath";
    "scope";"expectedUrl";"navigationSource";"within";"selector";"snapshotScope";"root";"screenshotOptions"] json in
  let* request=surface fields in
  let* ()=bound request in
  let* frame_path=B.Action.parse_frame_path json in
  let* mode=Legacy.read_mode_of_args json in
  let* options=B.Capture.of_optional_json (List.assoc_opt "screenshotOptions" fields) in
  let* ()=match mode,options with
    | `Screenshot,_ | _,None -> Ok ()
    | _,Some _ -> Error "screenshotOptions apply only to mode screenshot" in
  let* cap=optional_int "maxChars" fields in
  let* max_chars=Browser_page_script.text_cap cap in
  let* filter=Browser_page_script.elements_filter_of_json (fun key -> List.assoc_opt key fields) in
  let* ()=match mode,(filter.within,filter.selector) with
    | `Elements,((None|Some _),(None|Some _))
    | (`Text|`Html|`Scene|`Regions|`Snapshot|`Screenshot|`Downloads|`Console|`Network|`Cookies|`Frames|`Dialog),(None,None) -> Ok ()
    | (`Text|`Html|`Scene|`Regions|`Snapshot|`Screenshot|`Downloads|`Console|`Network|`Cookies|`Frames|`Dialog),((Some _,_)|(_,Some _)) ->
        Error "within and selector apply to mode elements only" in
  let elements_projection=match filter.within,filter.selector with None,None -> Raw | (Some _,_|_,Some _) -> Scoped_elements filter in
  let top_scene=frame_path=[] && (match mode with `Scene|`Regions -> true
    | `Text|`Html|`Elements|`Snapshot|`Screenshot|`Downloads|`Console|`Network|`Cookies|`Frames|`Dialog -> false) in
  let* ()=if not top_scene && List.exists (fun key -> List.mem_assoc key fields)
      ["scope";"expectedUrl";"navigationSource"] then
      Error "scope, expectedUrl and navigationSource support top-document scene or regions only" else Ok () in
  let* ()=match mode with
    | `Snapshot -> Ok ()
    | `Text|`Html|`Elements|`Scene|`Regions|`Screenshot|`Downloads|`Console|`Network|`Cookies|`Frames|`Dialog ->
      if List.exists (fun key -> List.mem_assoc key fields) ["snapshotScope";"root"]
      then Error "snapshotScope and root apply to mode snapshot only" else Ok () in
  let contextual=frame_path<>[] || (match mode with `Frames|`Dialog -> true
    | `Text|`Html|`Elements|`Scene|`Regions|`Snapshot|`Screenshot|`Downloads|`Console|`Network|`Cookies -> false) in
  if contextual then
    let* ()=match request.route,mode with
      | Browser_selection.Exact B.Automation_route,_ -> Ok ()
      | Exact (Live_route _),(`Text|`Elements|`Frames) -> Ok ()
      | Exact (Live_route _),(`Dialog|`Html|`Scene|`Regions|`Snapshot|`Screenshot|`Downloads|`Console|`Network|`Cookies) ->
          Error "a live browser reads text, elements and frames in a frame; a dialog shows on its BrowserTabs/masc_browser_tabs row"
      | Automatic,_|Exact Stagehand_route,_ -> Error "frame and dialog reads require an explicit automation or live browser" in
    let* tab_id=tab request in
    let* mode=match mode with
      | `Text -> Ok (`Text max_chars) | `Elements -> Ok (`Elements filter) | `Frames -> Ok `Frames
      | `Dialog when frame_path=[] -> Ok `Dialog
      | `Dialog|`Html|`Scene|`Regions|`Snapshot|`Screenshot|`Downloads|`Console|`Network|`Cookies -> Error "framePath supports text, elements and frames" in
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
  | `Snapshot ->
      let* ()=match request.route with
        | Browser_selection.Automatic | Exact (B.Live_route _) -> Ok ()
        | Exact (Automation_route|Stagehand_route) -> Error B.snapshot_refused in
      let* scope=match List.assoc_opt "snapshotScope" fields,List.assoc_opt "root" fields with
        | (None|Some (`String _) as scope),(None|Some (`String _) as root) ->
          let text=function Some (`String value) -> Some value | Some _ | None -> None in
          B.snapshot_scope_of_wire ~scope:(Option.value (text scope) ~default:"viewport") ~root:(text root)
        | Some _,_ | _,Some _ -> Error "snapshotScope and root are text" in
      let* tab_id=tab request in prepared request Raw (B.Page_snapshot {tab_id;max_chars;scope})
  | `Screenshot ->
      let* tab_id=tab request in prepared request (Screenshot (tab_id,options)) (B.Page_capture {tab_id;options})
  | `Downloads ->
      (* A live connection that does not list downloads refuses at selection
         (Browser_lane.live_transport_serves). *)
      let* ()=match request.route with Browser_selection.Exact (B.Automation_route|Live_route _) -> Ok ()
        | Automatic|Exact Stagehand_route -> Error "downloads require automation or an explicit live browser" in
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
  (* The source of the top document, never cut: when the JSON reply would
     pass 1 MiB it says htmlComplete false instead. A browser that cannot read it refuses at
     selection. *)
  | `Html ->
      let* ()=match cap with None -> Ok () | Some _ -> Error "maxChars applies to text; html returns the document source uncut, or none when the reply would pass 1 MiB" in
      let* tab_id=tab request in prepared request Raw (B.Page_document {tab_id})
  | `Elements -> prepared request elements_projection (B.Page_elements {tab_id=request.tab_id;filter})
  | `Frames|`Dialog -> Error "contextual read requires a frame or dialog mode"
let prepare ~upload_paths tool json =
  let* _=Lane_addon_action.canonical json in
  match tool with
  | C.Read -> prepare_read json
  | Interact ->
    (match json with
     | `Assoc supplied when List.assoc_opt "action" supplied = Some (`String "workflow") ->
      let* ()=if List.length supplied=List.length (List.sort_uniq String.compare (List.map fst supplied))
        then Ok () else Error "duplicate native workflow argument" in
      let* accepted=fields ["lane";"clientId";"tabId";"action";"expectedUrl";"steps";"snapshotScope";"maxChars"] json in
      let fields=accepted in
      let* request=surface fields in
      let* ()=bound request in
      let* cap=optional_int "maxChars" fields in
      let* max_chars=Browser_page_script.text_cap cap in
      let input=`Assoc (("maxChars",`Int max_chars)::List.filter (fun (key,_)->
        not (List.mem key ["lane";"clientId";"action";"maxChars"])) fields) in
      let* workflow=B.Native_workflow.of_json input in
      Ok {preference=request.route;required_actions=[];projection=Raw;verb=B.Page_native_workflow workflow}
     | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _) ->
      let* request=Browser_interaction.parse json in
      let* ()=match request.route with
        | Browser_selection.Exact (B.Automation_route|B.Stagehand_route) when B.acts_on_snapshot_target request.action ->
            Error B.snapshot_target_refused
        | Automatic|Exact (Live_route _|Automation_route|Stagehand_route) -> Ok () in
      Ok {preference=request.route;required_actions=[];projection=Raw;
        verb=B.Page_interact {tab_id=request.tab_id;frame_path=request.frame_path;expected_url=request.expected_url;action=request.action}})
  | Act ->
      let* action=B.Action.parse json in
      let* action=match action,upload_paths with
        | B.Action.On_tab ({interaction=Upload {target=upload;_};_} as target),Some paths ->
            Ok (B.Action.On_tab {target with interaction=Upload {target=upload;paths}})
        | On_tab {interaction=Upload _;_},None -> Error "upload requires an authoritative Keeper file context"
        | (Open_tab _|Open_window _|Control _|On_tab {interaction=(Back|Forward|Reload
            |Close_tab|Accept_dialog _|Dismiss_dialog|Set_cookie _|Delete_cookie _|Set_emulation _|Clear_emulation|Block_requests _|Unblock_requests);_}),(None|Some _) -> Ok action in
      let* request=Legacy.tool_request json in
      let* ()=match action,request.route with
        | (B.Action.Open_tab _|Open_window _|Control _),Browser_selection.Exact (B.Live_route None)
        | Control _,Automatic ->
            Error "live creation, control and Page management actions require an explicit observed clientId"
        | Control _,Exact (B.Automation_route|Stagehand_route) -> Error B.handoff_refused
        | (Open_tab _|Open_window _|On_tab _),(Automatic|Exact (Live_route _|Automation_route|Stagehand_route))
        | Control _,Exact (Live_route (Some _)) -> Ok () in
      prepared request Raw (B.Page_act action)
  | Instruct ->
      let* fields=fields ("lane"::Legacy.instruct_arguments) json in
      let* verb=Legacy.instruct_verb fields in
      let* request=surface fields in
      let* ()=match request.route with
        | Browser_selection.Exact B.Stagehand_route -> Ok ()
        | Exact B.Automation_route when B.verb_allowed_on_automation verb -> Ok ()
        | Exact B.Automation_route -> Error "automation supports observe with selected locate Exact Output; act/extract require stagehand"
        | Automatic|Exact (B.Live_route _) -> Error "BrowserInstruct/masc_browser_instruct requires the observed automation or stagehand lane and tabId" in
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
type metadata_request = Connections | Bind_goal of {goal_id:string;client_id:B.client_id} | Goal_status of string
  | Unbind_goal of string
type request = Browser of prepared | Metadata of metadata_request
let prepare_request ~upload_paths tool json =
  let* _=Lane_addon_action.canonical json in
  match tool,json with
  | C.Tabs,`Assoc supplied when List.mem_assoc "mode" supplied ->
      let* fields=fields ["mode"] json in
      (match List.assoc_opt "mode" fields with
       | Some (`String "connections") -> Ok (Metadata Connections)
       | None|Some _ -> Error "BrowserTabs mode must be connections; omit mode for tab discovery")
  | C.Session,`Assoc supplied when List.mem (List.assoc_opt "action" supplied)
      [Some (`String "bind_goal");Some (`String "goal_status");Some (`String "unbind_goal")] ->
      let* goal_id=match List.assoc_opt "goalId" supplied with
        | Some (`String value) when String.trim value<>"" -> Ok value
        | None|Some _ -> Error "goalId must be nonblank text" in
      (match List.assoc_opt "action" supplied with
       | Some (`String "bind_goal") ->
         let* fields=fields ["action";"goalId";"lane";"clientId"] json in
         let* ()=match List.assoc_opt "lane" fields with
           | Some (`String "live") -> Ok ()
           | None|Some _ -> Error "bind_goal requires lane=live" in
         let* request=surface fields in
         (match request.route with
          | Browser_selection.Exact (B.Live_route (Some client_id)) ->
              Ok (Metadata (Bind_goal {goal_id;client_id}))
          | Automatic|Exact (Live_route None|Automation_route|Stagehand_route) ->
              Error "bind_goal requires lane=live and an observed Ego clientId")
       | Some (`String "goal_status") ->
         let* _=fields ["action";"goalId"] json in
         Ok (Metadata (Goal_status goal_id))
       | Some (`String "unbind_goal") ->
         let* _=fields ["action";"goalId"] json in
         Ok (Metadata (Unbind_goal goal_id))
       | None|Some _ -> Error "unknown Goal Space operation")
  | (C.Session|Tabs|Read|Interact|Act|Instruct|Goto),_ ->
      prepare ~upload_paths tool json |> Result.map (fun value -> Browser value)
let initial_goal_space initial_goal_ids config request =
  match request.preference,request.verb with
  | Browser_selection.Automatic,(B.Tabs_list|Session_open _) ->
    let* ids=match initial_goal_ids with None -> Ok [] | Some read -> read () in
    (match List.sort_uniq String.compare ids with
     | [] -> Ok None
     | [goal_id] -> Browser_goal_space.find config ~goal_id |> Result.map_error Browser_goal_space.error_message
     | _::_::_ -> Error "current Task belongs to multiple Goals; choose an explicit browser lane and clientId")
  | (Automatic|Exact (B.Live_route _|Automation_route|Stagehand_route)),
    (Tabs_list|Session_open _|Session_close|Session_status|Page_read _|Page_document _|Page_downloads _
    |Page_console _|Page_network _|Page_cookies _|Page_capture _|Page_scene _|Page_snapshot _
    |Page_native_workflow _|Page_interact _|Page_goto _|Page_elements _|Page_act _|Page_context _
    |Page_instruct _|Page_locate _|Page_extract _) -> Ok None
let annotate_goal binding = function
  | `Assoc fields -> `Assoc ((match binding with None -> [] | Some value ->
      ["browserGoal",Browser_goal_space.to_json value]) @ List.remove_assoc "browserGoal" fields)
  | value -> value
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
  let data value = Result.map (fun data -> data,None) value in
  match request.projection with
  | Raw -> data (Ok (annotate receipt.data))
  | Inventory ->
      let inventory=match receipt.data with `List tabs -> `Assoc ["tabs",`List tabs] | value -> value in
      data (with_capabilities (annotate inventory))
  | Session -> data (with_capabilities (annotate receipt.data))
  | Scene scene -> data (Browser_scene.project scene ~binding:receipt.binding ~started receipt.data)
  | Scoped_elements filter ->
      data (Result.map annotate (Browser_page_script.check_scoped_elements ~filter receipt.data))
  | Screenshot (tab_id,options) ->
      let* capture=match options with
        | None -> Browser_surface.capture_from ~binding:receipt.binding ~tab_id ~started receipt.data
        | Some options -> Browser_surface.native_capture_from ~binding:receipt.binding ~tab_id ~started ~options receipt.data in
      match keeper_name,capture with
      | Some keeper_name,_ -> data (Browser_screenshot.persist ?native_options:options ~base_path ~keeper_name capture)
      (* A caller with no Keeper workspace gets the checked PNG back as an image
         block of this result, and the observation fields without its bytes.
         The content repeats the observation as text before the image, so a
         client that reads only content keeps the viewport and selection. *)
      | None,`Assoc fields ->
          (match List.assoc_opt "data" fields with
           | Some (`String image) ->
               let observed=`Assoc (List.filter (fun (key,_) -> key<>"data") fields) in
               Ok (observed,
                 Some [Llm_provider.Types.Text (Yojson.Safe.to_string observed);
                   Llm_provider.Types.Image {media_type="image/png";source=Llm_provider.Types.Base64 image}])
           | Some _|None -> Error "screenshot lacks its image")
      | None,_ -> Error "screenshot must be an object"
let handle ?initial_goal_ids ?upload_paths ~config ~access ~principal ~reserved ~keeper_name ~tool ~tool_name ~start_time json =
  let started=Mtime_clock.elapsed_ns () in
  let result=match prepare_request ~upload_paths tool json with
    | Error detail -> Legacy.make_input_err ~tool_name ~start_time detail
    | Ok request ->
          let refuse error=Tool_result.make_err ~tool_name ~start_time
            ~class_:Tool_result.Workflow_rejection ~effect_disposition:Tool_result.Proven_pre_effect error in
          let with_host run=match Host.connect ~config ~access ~principal ~reserved with
            | Error error -> Host.error_result ~start_time error
            | Ok host -> run host in
          match request with
          | Metadata Connections ->
              (match principal with
               | Lane_addon_call_context.Anonymous -> refuse "browser calls require verified host authority"
               | Keeper _|Authenticated_agent _|Host_actor _|Operator ->
                 match Host.connection_inventory ~config ~access with
                 | Error (Host.Snapshot_unavailable detail) -> Tool_result.make_err ~tool_name ~start_time
                     ~class_:Tool_result.Dependency_unavailable ~effect_disposition:Tool_result.Proven_pre_effect detail
                 | Error (Host.Snapshot_unreadable detail) -> Tool_result.make_err ~tool_name ~start_time
                     ~class_:Tool_result.Runtime_failure ~effect_disposition:Tool_result.Proven_pre_effect detail
                 | Ok inventory -> Tool_result.make_ok ~tool_name ~start_time
                     ~data:(Browser_connection_inventory.to_json inventory) ())
          | Metadata (Bind_goal {goal_id;client_id}) -> with_host (fun host ->
              (match Host.bind_goal_space host ~goal_id ~client_id with
               | Error error -> refuse (Browser_goal_space.error_message error)
               | Ok committed -> Tool_result.make_ok ~tool_name ~start_time ~data:(`Assoc [
                   "browserGoal",Browser_goal_space.to_json committed.binding;
                   "created",`Bool committed.created;
                   "mirrorError",(match committed.mirror_error with None -> `Null|Some e -> `String e)]) ()))
          | Metadata (Goal_status goal_id) ->
              (match principal with
               | Lane_addon_call_context.Anonymous -> refuse "browser calls require verified host authority"
               | Keeper _|Authenticated_agent _|Host_actor _|Operator ->
              match Browser_goal_space.find config ~goal_id with
               | Error error -> refuse (Browser_goal_space.error_message error)
               | Ok binding -> Tool_result.make_ok ~tool_name ~start_time ~data:(`Assoc [
                   "goalId",`String goal_id;"browserGoal",(match binding with None -> `Null
                     | Some value -> Browser_goal_space.to_json value);"observation",`String "stored_binding"]) ())
          | Metadata (Unbind_goal goal_id) ->
              (match principal with
               | Lane_addon_call_context.Anonymous -> refuse "browser calls require verified host authority"
               | Keeper _|Authenticated_agent _|Host_actor _|Operator ->
              match Browser_goal_space.unbind config ~goal_id with
               | Error error -> refuse (Browser_goal_space.error_message error)
               | Ok unbound -> Tool_result.make_ok ~tool_name ~start_time ~data:(`Assoc [
                   "goalId",`String goal_id;
                   "removed",(match unbound.removed with None -> `Null
                     | Some value -> Browser_goal_space.to_json value);
                   "actor",`String (Lane_addon_call_context.actor_label principal);
                   "mirrorError",(match unbound.mirror_error with None -> `Null|Some e -> `String e)]) ())
          | Browser request ->
            match initial_goal_space initial_goal_ids config request with
            | Error error -> refuse error
            | Ok goal_space ->
            with_host (fun host ->
            match Host.issue ?goal_space ?upload_paths ~required_actions:request.required_actions host ~preference:request.preference request.verb with
            | Error result -> result
            | Ok receipt ->
                (match project ~base_path:config.Workspace.base_path ~keeper_name ~started request receipt with
                 | Ok (data,content_blocks) ->
                     Tool_result.make_ok ~tool_name ~start_time ~data:(annotate_goal goal_space data) ?content_blocks ?metadata:receipt.raw_result._meta ()
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
                     ?metadata:receipt.raw_result._meta ~data detail)) in
  restamp ~tool_name ~start_time result
