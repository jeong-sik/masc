module B = Browser_lane
module Host = Browser_addon_host
module C = Browser_capabilities
module Legacy = Tool_misc_browser_lane
open Result.Syntax
type projection = Raw | Inventory | Scene of Browser_scene.request | Screenshot of int * B.Capture.t option
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
  | Exact (B.Live_route (Some _)),(None|Some _) -> Ok ()
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
  let* fields=fields ["lane";"clientId";"tabId";"maxChars";"mode";
    "scope";"expectedUrl";"navigationSource";"within";"selector";"snapshotScope";"root";"screenshotOptions"] json in
  let* request=surface fields in
  let* ()=bound request in
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
    | (`Text|`Html|`Scene|`Regions|`Snapshot|`Screenshot|`Downloads|`Cookies|`Network|`Console|`Dialog),(None,None) -> Ok ()
    | (`Text|`Html|`Scene|`Regions|`Snapshot|`Screenshot|`Downloads|`Cookies|`Network|`Console|`Dialog),((Some _,_)|(_,Some _)) ->
        Error "within and selector apply to mode elements only" in
  let elements_projection=match filter.within,filter.selector with None,None -> Raw | (Some _,_|_,Some _) -> Scoped_elements filter in
  let top_scene=(match mode with `Scene|`Regions -> true
    | `Text|`Html|`Elements|`Snapshot|`Screenshot|`Downloads|`Cookies|`Network|`Console|`Dialog -> false) in
  let* ()=if not top_scene && List.exists (fun key -> List.mem_assoc key fields)
      ["scope";"expectedUrl";"navigationSource"] then
      Error "scope, expectedUrl and navigationSource support top-document scene or regions only" else Ok () in
  let* ()=match mode with
    | `Snapshot -> Ok ()
    | `Text|`Html|`Elements|`Scene|`Regions|`Screenshot|`Downloads|`Cookies|`Network|`Console|`Dialog ->
      if List.exists (fun key -> List.mem_assoc key fields) ["snapshotScope";"root"]
      then Error "snapshotScope and root apply to mode snapshot only" else Ok () in
  match mode with
  | `Dialog ->
      let* ()=match request.route with
        | Browser_selection.Exact (Live_route _) -> Ok ()
        | Automatic -> Error "dialog reads require an explicit live browser" in
      let* tab_id=tab request in
      prepared request Raw (B.Page_context {tab_id})
  | (`Scene|`Regions as scene_mode) ->
      let view=match scene_mode with `Regions -> "regions" | `Scene -> "content" in
      let* scene=Browser_scene.parse_request (`Assoc (("view",`String view)::
        List.filter (fun (key,_) -> key<>"mode") fields)) in
      let* tab_id=tab request in
      prepared request (Scene scene) (B.Page_scene {tab_id;max_chars;view=scene.view;scope=scene.scope})
  | `Snapshot ->
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
      let* ()=match request.route with Browser_selection.Exact (B.Live_route _) -> Ok ()
        | Automatic -> Error "downloads require an explicit live browser" in
      let* tab_id=tab request in prepared request Raw (B.Page_downloads {tab_id})
  (* Names and attributes only, never a value. A connection that does not
     list them refuses at selection (Browser_lane.live_transport_serves). *)
  | `Cookies ->
      let* ()=match request.route with Browser_selection.Exact (B.Live_route _) -> Ok ()
        | Automatic -> Error "cookie and storage names require an explicit live browser" in
      let* tab_id=tab request in prepared request Raw (B.Page_cookies {tab_id})
  (* Requests as rows, never a header value, cookie, body or query value. A
     connection that does not list them refuses at selection. *)
  | `Network ->
      let* ()=match request.route with Browser_selection.Exact (B.Live_route _) -> Ok ()
        | Automatic -> Error "network requests require an explicit live browser" in
      let* tab_id=tab request in prepared request Raw (B.Page_network {tab_id})
  (* What the tab's document wrote to its console, read in one step that
     turns ego's console hiding off and back on. A connection that does not
     read it refuses at selection. *)
  | `Console ->
      let* ()=match request.route with Browser_selection.Exact (B.Live_route _) -> Ok ()
        | Automatic -> Error "console lines require an explicit live browser" in
      let* tab_id=tab request in prepared request Raw (B.Page_console {tab_id})
  | `Text -> prepared request Raw (B.Page_read {tab_id=request.tab_id;max_chars=Some max_chars})
  (* The source of the top document, never cut: when the JSON reply would
     pass 1 MiB it says htmlComplete false instead. A browser that cannot read it refuses at
     selection. *)
  | `Html ->
      let* ()=match cap with None -> Ok () | Some _ -> Error "maxChars applies to text; html returns the document source uncut, or none when the reply would pass 1 MiB" in
      let* tab_id=tab request in prepared request Raw (B.Page_document {tab_id})
  | `Elements -> prepared request elements_projection (B.Page_elements {tab_id=request.tab_id;filter})
let prepare ~upload_paths tool json =
  let* _=Lane_addon_action.canonical json in
  match tool with
  | C.Read -> prepare_read json
  | Interact ->
    (match json with
     | `Assoc supplied when List.assoc_opt "action" supplied = Some (`String "workflow") ->
      let* ()=if List.length supplied=List.length (List.sort_uniq String.compare (List.map fst supplied))
        then Ok () else Error "duplicate native workflow argument" in
      let* accepted=fields ["clientId";"tabId";"action";"expectedUrl";"steps";"snapshotScope";"maxChars"] json in
      let fields=accepted in
      let* request=surface fields in
      let* ()=bound request in
      let* cap=optional_int "maxChars" fields in
      let* max_chars=Browser_page_script.text_cap cap in
      let input=`Assoc (("maxChars",`Int max_chars)::List.filter (fun (key,_)->
        not (List.mem key ["clientId";"action";"maxChars"])) fields) in
      let* workflow=B.Native_workflow.of_json input in
      Ok {preference=request.route;required_actions=[];projection=Raw;verb=B.Page_native_workflow workflow}
     | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _) ->
      let* _=fields (Browser_interaction.route_names @ Browser_interaction.wire_fields) json in
      let* request=Browser_interaction.parse json in
      Ok {preference=request.route;required_actions=[];projection=Raw;
        verb=B.Page_interact {tab_id=request.tab_id;expected_url=request.expected_url;action=request.action}})
  | Act ->
      let* action=B.Action.parse json in
      let* action=match action,upload_paths with
        | B.Action.On_tab ({interaction=Upload {target=upload;_};_} as target),Some paths ->
            Ok (B.Action.On_tab {target with interaction=Upload {target=upload;paths}})
        | On_tab {interaction=Upload _;_},None -> Error "upload requires an authoritative Keeper file context"
        | (Open_tab _|Control _|On_tab {interaction=(Back|Forward|Reload
            |Close_tab|Stop_loading|Accept_dialog _|Dismiss_dialog|Set_cookie _|Delete_cookie _|Set_emulation _|Clear_emulation|Block_requests _|Unblock_requests);_}),(None|Some _) -> Ok action in
      let* request=Legacy.tool_request json in
      let* ()=Host.act_route request.route action in
      prepared request Raw (B.Page_act action)

  | Tabs ->
      let* fields=fields ["lane";"clientId";"tabId";"requiredActions"] json in
      let* request=surface fields in
      let* required_actions=Legacy.required_actions json in
      let* ()=match request.tab_id,required_actions with Some _,_::_ ->
          Error "requiredActions applies only to initial discovery without tabId"
        | (None|Some _),[]|None,_::_ -> Ok () in
      prepared ~required_actions request Inventory B.Tabs_list
  | Session -> Error "action must be bind_goal, goal_status or unbind_goal"
  | Goto ->
      let* fields=fields ["clientId";"tabId";"url"] json in
      let* request=surface fields in
      let* url=absolute_url (List.assoc_opt "url" fields) in
      let* ()=match request.route,request.tab_id with
        | Browser_selection.Exact (B.Live_route _),None ->
            Error "live navigation needs the tabId of a tab this connection opened with open_tab"
        | (Automatic|Exact (B.Live_route _)),(None|Some _) -> Ok () in
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
          | Automatic|Exact (Live_route None) ->
              Error "bind_goal requires lane=live and an observed Ego clientId")
       | Some (`String "goal_status") ->
         let* _=fields ["action";"goalId"] json in
         Ok (Metadata (Goal_status goal_id))
       | Some (`String "unbind_goal") ->
         let* _=fields ["action";"goalId"] json in
         Ok (Metadata (Unbind_goal goal_id))
       | None|Some _ -> Error "unknown Goal Space operation")
  | (C.Session|Tabs|Read|Interact|Act|Goto),_ ->
      prepare ~upload_paths tool json |> Result.map (fun value -> Browser value)
let initial_goal_space initial_goal_ids config request =
  match request.preference,request.verb with
  | Browser_selection.Automatic,B.Tabs_list ->
    let* ids=match initial_goal_ids with None -> Ok [] | Some read -> read () in
    (match List.sort_uniq String.compare ids with
     | [] -> Ok None
     | [goal_id] -> Browser_goal_space.find config ~goal_id |> Result.map_error Browser_goal_space.error_message
     | _::_::_ -> Error "current Task belongs to multiple Goals; choose an explicit browser lane and clientId")
  | (Automatic|Exact (B.Live_route _)),
    (Tabs_list|Page_read _|Page_document _|Page_downloads _|Page_cookies _|Page_network _|Page_console _
    | Page_capture _|Page_scene _|Page_snapshot _
    |Page_native_workflow _|Page_interact _|Page_goto _|Page_elements _|Page_act _|Page_context _) -> Ok None
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
  let capability_fields=["browserCapabilities",C.to_json (Browser_binding.backend receipt.binding)
      ~constraints_for:request.required_actions;
    "requiredActions",`List (List.map (fun action -> `String (C.operation_name action)) request.required_actions)] in
  (* The browser selection and the tabs come first, so a reader that stops early
     has what the next call needs. *)
  let with_capabilities = function
    | `Assoc fields -> Ok (`Assoc (List.filter
        (fun (key,_) -> not (List.mem key ["browserCapabilities";"requiredActions"])) fields @ capability_fields))
    | _ -> Error "browser inventory response must be an object" in
  let data value = Result.map (fun data -> data,None) value in
  match request.projection with
  | Raw -> data (Ok (annotate receipt.data))
  | Inventory ->
      let inventory=match receipt.data with `List tabs -> `Assoc ["tabs",`List tabs] | value -> value in
      data (with_capabilities (annotate inventory))
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
                     let effect_disposition=Tool_result.Proven_pre_effect in
                     (* A refused scoped read does not pass on the unscoped answer. *)
                     let data=match request.projection with
                       | Scoped_elements _ -> `Assoc ["error",`String detail]
                       | Raw|Inventory|Scene _|Screenshot _ ->
                           Mcp_protocol.Mcp_types.tool_result_to_yojson receipt.raw_result in
                     Tool_result.make_err ~tool_name ~start_time
                     ~class_:Tool_result.Runtime_failure ~effect_disposition
                     ?metadata:receipt.raw_result._meta ~data detail)) in
  restamp ~tool_name ~start_time result
