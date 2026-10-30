module R = Lane_addon_runtime
(* One browser service and its own browser command, if it advertises one.
   A service without it still serves its sources, so it is still counted
   when the host asks which service serves a source. *)
type served = { service : R.browser_service; export : R.tool_export option }
type t = {
  config : Workspace.config;
  access : Lane_addon_sources.access;
  principal : Lane_addon_call_context.principal;
  reserved : string list;
  services : served list;
}
open Result.Syntax
(* Every browser service that serves now, each with its own export matched
   by instance and owner. No service at all is the only refusal here. *)
let connect ~config ~access ~principal ~reserved =
  let* ()=match principal with
    | Lane_addon_call_context.Anonymous -> Error (R.Host_refusal
        (Lane_addon_call_context.Rejected "browser calls require verified host authority"))
    | Keeper _|Authenticated_agent _|Host_actor _|Operator -> Ok () in
  let browser=R.browser_service_reading ~config ~access in
  let exports=R.browser_export_reading ~config ~access in
  let own (service:R.browser_service)=List.filter (fun (export:R.tool_export) ->
    export.instance_id=service.instance_id && export.tool.name=Browser_addon_tool.definition.name
    && Lane_addon_tool_export.equal_owner export.owner service.owner) exports in
  match browser.services with
  | [] -> Error (R.Unavailable (match Lane_addon_unready.summary browser.unready with
      | Some reason -> reason
      | None -> "no browser Add-on is attached"))
  | _::_ ->
    let services=List.map (fun service -> {service;export=match own service with
      | [export] -> Some export
      | []|_::_::_ -> None}) browser.services in
    Ok {config;access;principal;reserved;services}
(* A source is served by exactly one service or not at all: none, or two,
   leave that source alone unusable, and every other source is still chosen. *)
type backend_failure = No_service of Browser_lane.Backend.t | Several_services of Browser_lane.Backend.t
let backend_failure_message = function
  | No_service backend -> Printf.sprintf "no attached browser Add-on serves %s" (Browser_lane.Backend.to_wire backend)
  | Several_services backend -> Printf.sprintf
      "more than one attached browser Add-on serves %s, so it is not used until one is detached"
      (Browser_lane.Backend.to_wire backend)
let serves (served:served) backend=served.service.backend = backend
let for_backend t backend=match List.filter (fun served -> serves served backend) t.services with
  | [served] -> Ok served
  | [] -> Error (No_service backend)
  | _::_::_ -> Error (Several_services backend)
let call_served t (served:served) ~arguments = match served.export with
  | Some export -> Machine_addon_host.call ~continuation:None ~principal:t.principal
      ~config:t.config ~access:t.access ~reserved:t.reserved ~export ~arguments
  | None -> Error (R.Unavailable "the browser Add-on serving this browser advertises no browser command")
let call t ~backend ~arguments = match for_backend t backend with
  | Ok served -> call_served t served ~arguments
  | Error failure -> Error (R.Unavailable (backend_failure_message failure))
let error_result ~start_time error =
  let class_,effect_disposition,detail=match error with
    | R.Unavailable detail -> Tool_result.Dependency_unavailable,Tool_result.Proven_pre_effect,detail
    | Outcome_unknown detail -> Tool_result.Runtime_failure,Tool_result.Effect_outcome_unknown,detail
    | Host_refusal refusal ->
        let class_,detail=match refusal with
          | Lane_addon_call_context.Rejected detail|Activity_disabled detail -> Tool_result.Workflow_rejection,detail
          | Unavailable detail|Activity_unobserved detail -> Tool_result.Dependency_unavailable,detail in
        class_,Tool_result.Proven_pre_effect,detail in
  Tool_result.make_err ~tool_name:Browser_addon_tool.definition.name ~start_time ~class_ ~effect_disposition detail
let snapshot_service ~config ~access ~service =
  let* reply=R.call_browser_service ~config ~access ~service ~command:Browser_addon_wire.Snapshot in
  match reply with
  | Browser_addon_wire.Snapshot_result value -> Ok value
  | Service_refusal {message;disposition=Not_started} -> Error (Browser_addon_client.Unavailable message)
  | Service_refusal {message;disposition=Outcome_unknown} -> Error (Browser_addon_client.Outcome_unknown message)
  | Model_reply _|Extension_reply _|Download_reply _|Receipt|Issue_result _|Poll_result _ -> Error (Browser_addon_client.Outcome_unknown "unexpected browser snapshot reply")
let snapshot_of t (served:served) = snapshot_service ~config:t.config ~access:t.access ~service:served.service
let snapshot t ~backend = match for_backend t backend with
  | Ok served -> snapshot_of t served
  | Error failure -> Error (Browser_addon_client.Unavailable (backend_failure_message failure))
type snapshot_failure = Snapshot_unavailable of string | Snapshot_unreadable of string
(* Every caller-visible service's snapshot, read without choosing a browser or
   issuing a command. A worker that does not answer, answers unreadably or is
   not ready stays in the inventory as an issue instead of being left out. *)
let connection_inventory ~config ~access =
  let reading=R.browser_service_reading ~config ~access in
  match reading.services,reading.unready with
  | [],[] -> Error (Snapshot_unavailable "no browser Add-on is attached")
  | (_::_),_|[],(_::_) ->
    let module I=Browser_connection_inventory in
    let issues=List.map (fun (unready:Lane_addon_unready.t) ->
      I.Source_unready {instance_id=unready.instance_id;message=Lane_addon_unready.message unready}) reading.unready in
    let observations,issues=List.fold_left (fun (observations,issues) (service:R.browser_service) ->
      match snapshot_service ~config ~access ~service with
      | Error (Browser_addon_client.Unavailable detail|Outcome_unknown detail) ->
          Log.Misc.warn "Browser inventory could not read worker %s: %s" service.instance_id detail;
          observations,I.Source_unavailable {instance_id=service.instance_id;message="worker snapshot could not be read"}::issues
      | Ok value ->
        let decoded=let* _=Lane_addon_action.canonical value in Browser_addon_observation.decode_snapshot value in
        (match decoded with
         | Error message -> observations,I.Source_unreadable {instance_id=service.instance_id;message}::issues
         | Ok published -> {I.instance_id=service.instance_id;published}::observations,issues))
      ([],List.rev issues) reading.services in
    Ok (I.build ~observations:(List.rev observations) ~issues:(List.rev issues))
let published_of t served =
  match snapshot_of t served with
  | Error (Browser_addon_client.Unavailable detail|Outcome_unknown detail) -> Error (Snapshot_unavailable detail)
  | Ok value ->
    (let* _=Lane_addon_action.canonical value in Browser_addon_observation.decode_snapshot value)
    |> Result.map_error (fun detail -> Snapshot_unreadable detail)
(* What the host chooses from: each service's answer at the time of the
   request, asked side by side. A service that did not answer is left out of
   this choice only. Live clients are the clients of the services that serve
   a live source, with the service that listed each one; automation and
   Stagehand are what their own service answered. A worker answers only while
   it serves (decode_snapshot), so a live lane it reports is on. *)
type gathered = {
  published : Browser_addon_observation.published;
  selection : Browser_selection.snapshot;
  holders : (string * served) list;
  doubled : string list;
      (** Clients listed by a service whose live source another serves too. *)
}
(* [reach] names the services a request can go to; only those are asked, so
   a slow worker of another source does not hold the request up. Whether a
   live client is usable is judged among every service. *)
let gather t ~reach =
  let among=List.map (fun (served:served) -> served.service.backend) t.services in
  match List.filter reach t.services with
  | [] -> Error (Snapshot_unavailable "no attached browser Add-on serves the requested browser")
  | reached ->
  let answers=Eio.Fiber.List.map (fun served -> served,published_of t served) reached in
  match List.filter_map (fun (_,answer) -> Result.to_option answer) answers,answers with
  | [],(_,Error failure)::_ -> Error failure
  | [],((_,Ok _)::_|[]) -> Error (Snapshot_unavailable "no browser Add-on answered its snapshot")
  | _::_,_ ->
    let published=Browser_addon_observation.merge ~among (List.map (fun ((served:served),answer) ->
      served.service.backend,Result.to_option answer) answers) in
    let live=List.filter_map (fun ((served:served),answer) -> match answer with
      | Ok (listed:Browser_addon_observation.published)
        when Browser_addon_observation.lists_usable_clients ~among served.service.backend -> Some (served,listed)
      | Ok _|Error _ -> None) answers in
    let doubled=List.concat_map (fun ((served:served),answer) -> match answer with
      | Ok (listed:Browser_addon_observation.published)
        when Browser_addon_observation.serves_live served.service.backend
          && not (Browser_addon_observation.lists_usable_clients ~among served.service.backend) ->
          List.map (fun (client:Browser_lane.client_info) -> Browser_lane.client_id_to_string client.client_id) listed.clients
      | Ok _|Error _ -> []) answers in
    Ok {published;doubled;
        selection={live_activity=(match live with [] -> Browser_lane.Unobserved | _::_ -> Browser_lane.Enabled);
          live_clients=published.clients;automation=published.automation;stagehand=published.stagehand};
        holders=List.concat_map (fun (served,(listed:Browser_addon_observation.published)) ->
          List.map (fun (client:Browser_lane.client_info) ->
            Browser_lane.client_id_to_string client.client_id,served) listed.clients) live}
let selection_snapshot t = gather t ~reach:(fun _ -> true) |> Result.map (fun gathered -> gathered.published,gathered.selection)
(* The service a chosen browser is run on. A client two services list cannot
   be told apart, so it is refused rather than sent to one of them. *)
let served_for t gathered = function
  | Browser_selection.Owned_automation ->
      for_backend t Browser_lane.Backend.Automation |> Result.map_error backend_failure_message
  | Owned_stagehand -> for_backend t Browser_lane.Backend.Stagehand |> Result.map_error backend_failure_message
  | Connected (client:Browser_lane.client_info) ->
      let id=Browser_lane.client_id_to_string client.client_id in
      (match List.filter_map (fun (holder,served) -> if String.equal holder id then Some served else None) gathered.holders with
       | [served] -> Ok served
       | [] -> Error "no attached browser Add-on lists that browser client"
       | _::_::_ -> Error "more than one attached browser Add-on lists that browser client, so it is not used")
type receipt = {binding:Browser_binding.t;data:Yojson.Safe.t;
  raw_result:Mcp_protocol.Mcp_types.tool_result}
let goal_space t ~goal_id = Browser_goal_space.find t.config ~goal_id
(* The binding names the installation whose service lists the connection, so
   a Space is bound only through the one service that serves it. *)
let bind_goal_space t ~goal_id ~client_id =
  let* gathered = gather t ~reach:(fun _ -> true) |> Result.map_error (function
    | Snapshot_unavailable detail -> Browser_goal_space.Unavailable detail
    | Snapshot_unreadable detail -> Browser_goal_space.Invalid detail) in
  let id=Browser_lane.client_id_to_string client_id in
  let holders=List.filter_map (fun (holder,(served:served)) ->
    if String.equal holder id then Some served else None) gathered.holders in
  match List.find_opt (fun (client:Browser_lane.client_info) -> client.client_id=client_id) gathered.published.clients with
  | None -> Error (Browser_goal_space.Unavailable "clientId is not an observed browser connection")
  | Some {transport=Ego_task_space;space=None;_}
  | Some {transport=(Web_extension|Webdriver_bidi);_} ->
      Error (Browser_goal_space.Invalid "Goal Space binding requires an observed Ego Space connection")
  | Some {transport=Browser_lane.Ego_task_space;space=Some space;_} ->
    if List.mem id gathered.doubled then
      Error (Browser_goal_space.Conflict "the live source of that browser is served by more than one attached browser Add-on, so it is not used until one is detached")
    else match holders with
      | [served] ->
          Browser_goal_space.bind t.config ~goal_id ~addon_instance_id:served.service.instance_id
            ~space ~actor:(Lane_addon_call_context.actor_label t.principal)
      | [] -> Error (Browser_goal_space.Unavailable "no attached browser Add-on lists that browser client")
      | _::_::_ -> Error (Browser_goal_space.Conflict "more than one attached browser Add-on lists that browser client, so it is not used")
let route_arguments = function
  | Browser_lane.Live_route client -> ["lane",`String "live"] @
      (match client with None -> []|Some id -> ["clientId",`String (Browser_lane.client_id_to_string id)])
  | Automation_route -> ["lane",`String "automation"]
  | Stagehand_route -> ["lane",`String "stagehand"]
(* The worker states no browser identity; the receipt names the browser the
   host chose, in success and failure alike. *)
let stamp binding (result : Mcp_protocol.Mcp_types.tool_result) =
  match result.structured_content,Browser_binding.to_json binding with
  | Some (`Assoc fields),`Assoc identity ->
      let data=`Assoc (fields @ identity) in
      {result with structured_content=Some data;
        content=[Mcp_protocol.Mcp_types.TextContent {type_="text";text=Yojson.Safe.to_string data;annotations=None}]}
  | (None|Some _),_ -> result
let selection_detail ~clients error = `Assoc ["error",Browser_selection.error_to_json error;
  "clients",`List (List.map Browser_lane.client_json clients)]
(* Choose from the worker's snapshot, then run the command once on the chosen
   route. A refusal after the snapshot is returned as the worker gave it; the
   host never sends the command to another browser. *)
let resolve ?goal_space ~required_actions t ~preference verb ~start_time =
  let fail ?metadata ?(data=`Null) ~class_ ~effect_disposition message =
    Error (Tool_result.make_err ~tool_name:Browser_addon_tool.definition.name ~start_time
      ?metadata ~data ~class_ ~effect_disposition message) in
  let refuse ?data detail=fail ?data ~class_:Tool_result.Workflow_rejection ~effect_disposition:Tool_result.Proven_pre_effect detail in
  let unchosen ~clients error=refuse ~data:(selection_detail ~clients error) (Browser_selection.error_message error) in
  let* ()=match verb,required_actions with
    | (Browser_lane.Tabs_list|Session_open _),_ -> Ok ()
    | (Page_read _|Page_document _|Page_downloads _ | Page_console _ | Page_network _ | Page_cookies _|Page_capture _|Page_scene _|Page_snapshot _|Page_native_workflow _|Page_interact _
      |Session_close|Session_status|Page_goto _|Page_elements _|Page_act _|Page_context _
      |Page_instruct _|Page_locate _|Page_extract _),[] -> Ok ()
    | (Page_read _|Page_document _|Page_downloads _ | Page_console _ | Page_network _ | Page_cookies _|Page_capture _|Page_scene _|Page_snapshot _|Page_native_workflow _|Page_interact _
      |Session_close|Session_status|Page_goto _|Page_elements _|Page_act _|Page_context _
      |Page_instruct _|Page_locate _|Page_extract _),_::_ ->
        refuse "requiredActions applies only to initial tab discovery or session open" in
  let* ()=match preference,verb with
    | Browser_selection.Exact (Browser_lane.Live_route None),Browser_lane.Page_act (Browser_lane.Action.Open_tab _|Open_window _|Control _)
    | Automatic,Browser_lane.Page_act (Browser_lane.Action.Control _) ->
        refuse "live creation, control and Page management actions require an explicit observed clientId"
    | Exact (Browser_lane.Automation_route|Stagehand_route),Browser_lane.Page_act (Browser_lane.Action.Control _) ->
        refuse Browser_lane.handoff_refused
    | Exact (Browser_lane.Live_route (Some _)),Browser_lane.Page_act (Browser_lane.Action.Control _) -> Ok ()
    | (Automatic|Exact (Live_route _|Automation_route|Stagehand_route)),
      (Tabs_list|Page_read _|Page_document _|Page_downloads _ | Page_console _ | Page_network _ | Page_cookies _|Page_capture _|Page_scene _|Page_snapshot _|Page_native_workflow _|Page_interact _
      |Session_open _|Session_close|Session_status|Page_goto _|Page_elements _|Page_act (Browser_lane.Action.Open_tab _|Open_window _|On_tab _)|Page_context _
      |Page_instruct _|Page_locate _|Page_extract _) -> Ok () in
  let owned backend browser route=match for_backend t backend with
    | Ok served -> Ok (Browser_binding.of_browser {Browser_selection.route;
        reason=Browser_selection.Explicit_browser} browser,served)
    | Error failure -> fail ~class_:Tool_result.Dependency_unavailable
        ~effect_disposition:Tool_result.Proven_pre_effect (backend_failure_message failure) in
  match preference,required_actions with
    (* An explicit owned route with nothing to check against its snapshot
       names its browser already; the worker checks the lane again before it
       dispatches (RFC #45368 4.2). *)
    | Browser_selection.Exact Browser_lane.Automation_route,[] ->
        owned Browser_lane.Backend.Automation Browser_selection.Owned_automation Browser_lane.Automation_route
    | Exact Stagehand_route,[] ->
        owned Browser_lane.Backend.Stagehand Browser_selection.Owned_stagehand Browser_lane.Stagehand_route
    | (Automatic|Exact (Live_route _)),_ | Exact (Automation_route|Stagehand_route),_::_ ->
      let reach=match preference with
        | Browser_selection.Automatic -> (fun _ -> true)
        | Exact (Browser_lane.Live_route _) ->
            (fun (served:served) -> Browser_addon_observation.serves_live served.service.backend)
        | Exact Browser_lane.Automation_route -> (fun served -> serves served Browser_lane.Backend.Automation)
        | Exact Browser_lane.Stagehand_route -> (fun served -> serves served Browser_lane.Backend.Stagehand) in
      let* gathered=match gather t ~reach with
        | Ok value -> Ok value
        | Error (Snapshot_unavailable detail) -> fail ~class_:Tool_result.Dependency_unavailable
            ~effect_disposition:Tool_result.Proven_pre_effect
            ("browser snapshot is unavailable; no browser command was dispatched: " ^ detail)
        | Error (Snapshot_unreadable detail) -> fail ~class_:Tool_result.Runtime_failure
            ~effect_disposition:Tool_result.Proven_pre_effect
            ("browser snapshot is unreadable; no browser command was dispatched: " ^ detail) in
      let published=gathered.published and snapshot=gathered.selection in
      (* A Goal Space resolves only among the connections the service of its
         own installation lists; the chosen client then meets the same
         doubled-source refusal as an explicit one. *)
      let* preference=match goal_space with
        | None -> Ok preference
        | Some (binding:Browser_goal_space.t) ->
          let owner=List.find_opt (fun (served:served) ->
            String.equal served.service.instance_id binding.addon_instance_id) t.services in
          let listed=List.filter (fun (client:Browser_lane.client_info) ->
            let id=Browser_lane.client_id_to_string client.client_id in
            List.exists (fun (holder,(served:served)) -> String.equal holder id
              && String.equal served.service.instance_id binding.addon_instance_id) gathered.holders) published.clients in
          (match owner with
           | None -> Error (Browser_goal_space.Unavailable
               "the browser Add-on that published the Goal's Ego Space is not attached; no browser command was dispatched")
           | Some (served:served) -> Browser_goal_space.resolve binding ~addon_instance_id:served.service.instance_id listed)
          |> Result.map (fun client_id -> Browser_selection.Exact (Browser_lane.Live_route (Some client_id)))
          |> Result.map_error (fun error -> Tool_result.make_err
              ~tool_name:Browser_addon_tool.definition.name ~start_time
              ~class_:Tool_result.Workflow_rejection ~effect_disposition:Tool_result.Proven_pre_effect
              (Browser_goal_space.error_message error)) in
      let* ()=match preference with
        | Exact (Browser_lane.Live_route (Some id))
          when List.mem (Browser_lane.client_id_to_string id) gathered.doubled ->
            refuse "the live source of that browser is served by more than one attached browser Add-on, so it is not used until one is detached"
        | Automatic|Exact (Browser_lane.Live_route _|Automation_route|Stagehand_route) -> Ok () in
      let* selected=Browser_selection.choose ~required_actions ~verb ~bound:(Browser_selection.bound verb) ~snapshot preference
        |> Result.fold ~ok:Result.ok ~error:(unchosen ~clients:published.clients) in
      let* browser=Browser_selection.target ~verb ~snapshot selected.route
        |> Result.fold ~ok:Result.ok ~error:(fun error -> refuse (Browser_lane.selection_error_message error)) in
      let* ()=Browser_selection.require ~snapshot required_actions browser
        |> Result.fold ~ok:Result.ok ~error:(unchosen ~clients:published.clients) in
      let* served=served_for t gathered browser |> Result.fold ~ok:Result.ok ~error:refuse in
      Ok (Browser_binding.of_browser selected browser,served)
(* Run the command once on the chosen service and route. *)
let invoke ?upload_id t served binding verb ~start_time =
  let grant=match upload_id with None -> []|Some id -> ["uploadId",`String id] in
  match call_served t served ~arguments:(`Assoc (route_arguments (Browser_binding.selected binding).route @ grant
      @ ["command",Browser_lane.verb_json verb])) with
  | Error error -> Error (error_result ~start_time error)
  | Ok result -> Ok (binding,stamp binding result)
let dispatch ?upload_id ~required_actions t ~preference verb ~start_time =
  let* binding,served=resolve ~required_actions t ~preference verb ~start_time in
  invoke ?upload_id t served binding verb ~start_time
(* The public command shape: a missing lane leaves the choice to the host. *)
let parse_command json =
  let* fields=match json with
    | `Assoc fields when List.for_all (fun (key,_) -> List.mem key ["lane";"clientId";"command";"requiredActions";"uploadId"]) fields
        && List.length fields=List.length (List.sort_uniq String.compare (List.map fst fields)) -> Ok fields
    | _ -> Error "browser command accepts only lane, clientId, command, requiredActions and uploadId" in
  let* client=match List.assoc_opt "clientId" fields with
    | None -> Ok None
    | Some (`String raw) -> Browser_lane.client_id_of_string raw |> Result.map Option.some
    | Some _ -> Error "clientId must be a canonical browser UUID" in
  let* preference,route=match List.assoc_opt "lane" fields,client with
    | None,None -> Ok (Browser_selection.Automatic,Browser_lane.Live_route None)
    | (None|Some (`String "live")),Some client ->
        let route=Browser_lane.Live_route (Some client) in Ok (Browser_selection.Exact route,route)
    | Some (`String "live"),None -> Ok (Browser_selection.Exact (Browser_lane.Live_route None),Browser_lane.Live_route None)
    | Some (`String "automation"),None -> Ok (Browser_selection.Exact Browser_lane.Automation_route,Browser_lane.Automation_route)
    | Some (`String "stagehand"),None -> Ok (Browser_selection.Exact Browser_lane.Stagehand_route,Browser_lane.Stagehand_route)
    | Some _,(None|Some _) -> Error "lane must name a browser backend; clientId belongs only to live" in
  let* raw=Option.to_result ~none:"command is required" (List.assoc_opt "command" fields) in
  let* verb=Browser_addon_wire.verb_of_json ~route raw in
  let* required_actions=match List.assoc_opt "requiredActions" fields with
    | None -> Ok []
    | Some value -> Browser_capabilities.parse_required_actions value in
  let* upload_id=match List.assoc_opt "uploadId" fields with
    | None -> Ok None
    | Some (`String raw) -> let* id=Browser_lane.client_id_of_string raw in Ok (Some (Browser_lane.client_id_to_string id))
    | Some _ -> Error "uploadId must be a canonical host grant UUID" in
  Ok (preference,verb,required_actions,upload_id)
let command t ~arguments =
  let start_time=Tool_timing.start () in
  match parse_command arguments with
  | Error detail -> Error (Tool_result.make_err ~tool_name:Browser_addon_tool.definition.name ~start_time
      ~class_:Tool_result.Workflow_rejection ~effect_disposition:Tool_result.Proven_pre_effect detail)
  | Ok (preference,verb,required_actions,upload_id) ->
      dispatch ?upload_id ~required_actions t ~preference verb ~start_time |> Result.map snd
let issue ?goal_space ?upload_paths ?(required_actions=[]) t ~preference verb =
  let start_time=Tool_timing.start () in
  let fail ?metadata ?(data=`Null) ~class_ ~effect_disposition message =
    Error (Tool_result.make_err ~tool_name:Browser_addon_tool.definition.name ~start_time
      ?metadata ~data ~class_ ~effect_disposition message) in
  let initial=match preference,verb with
    | Browser_selection.Automatic,(Browser_lane.Tabs_list|Session_open _) -> true
    | (Automatic|Exact (Live_route _|Automation_route|Stagehand_route)),
      (Tabs_list|Session_open _|Session_close|Session_status|Page_read _|Page_document _|Page_downloads _
      |Page_console _|Page_network _|Page_cookies _|Page_capture _|Page_scene _|Page_snapshot _
      |Page_native_workflow _|Page_interact _|Page_goto _|Page_elements _|Page_act _|Page_context _
      |Page_instruct _|Page_locate _|Page_extract _) -> false in
  let* ()=match goal_space with
    | None -> Ok ()
    | Some _ when initial -> Ok ()
    | Some _ -> fail ~class_:Tool_result.Workflow_rejection
        ~effect_disposition:Tool_result.Proven_pre_effect
        "Goal Space defaults apply only to initial automatic discovery or open" in
  let upload=match verb with
    | Browser_lane.Page_act (Browser_lane.Action.On_tab {interaction=Upload {paths;_};_}) -> Some paths
    | Tabs_list|Page_read _|Page_document _|Page_downloads _ | Page_console _ | Page_network _ | Page_cookies _|Page_capture _|Page_scene _|Page_snapshot _|Page_interact _|Page_native_workflow _
    |Session_open _|Session_close|Session_status|Page_goto _|Page_elements _
    |Page_act (Open_tab _|Open_window _|Control _|On_tab {interaction=Close_tab|Back|Forward|Reload|Accept_dialog _|Dismiss_dialog|Set_cookie _|Delete_cookie _|Set_emulation _|Clear_emulation|Block_requests _|Unblock_requests;_})
    |Page_context _|Page_instruct _|Page_locate _|Page_extract _ -> None in
  (* The grant is staged for the exact route the command goes to: the owned
     Gecko, or a live connection the worker runs, which the selection names. *)
  let preparation=match upload,upload_paths,preference with
    | None,None,_ -> Ok None
    | Some paths,Some supplied,Browser_selection.Exact (Browser_lane.Automation_route|Live_route (Some _) as route)
        when paths=supplied && Browser_lane.Upload_lease.pending ~paths ->
        Ok (Some (Uuidm.(to_string (v4_gen (Random.State.make_self_init ()) ())),route))
    | (None|Some _),(None|Some _),(Browser_selection.Automatic|Exact (Live_route _|Automation_route|Stagehand_route)) ->
        Error "upload requires an exact pending host snapshot batch and the owned automation route or an explicit live browser" in
  let* upload_id=match preparation with
    | Ok id -> Ok id | Error detail -> fail ~class_:Tool_result.Workflow_rejection
        ~effect_disposition:Tool_result.Proven_pre_effect detail in
  (* The browser is chosen first, so the grant is staged on, and discarded
     from, the service the command then goes to. *)
  let* binding,served=resolve ?goal_space ~required_actions t ~preference verb ~start_time in
  let discard ()=Option.iter (fun (id,_) -> Eio.Cancel.protect (fun () ->
    ignore (R.call_browser_service ~config:t.config ~access:t.access ~service:served.service
      ~command:(Browser_addon_wire.Upload_discard id)))) upload_id in
  Fun.protect ~finally:discard (fun () ->
  let* ()=match upload_id with
    | None -> Ok ()
    | Some (id,route) ->
      match R.call_browser_service ~config:t.config ~access:t.access ~service:served.service
        ~command:(Browser_addon_wire.Upload_stage {id;actor=Lane_addon_call_context.actor_label t.principal;
          route;verb}) with
      | Ok Browser_addon_wire.Receipt -> Ok ()
      | Ok (Browser_addon_wire.Snapshot_result _|Model_reply _|Extension_reply _|Download_reply _|Poll_result _|Issue_result _|Service_refusal _) ->
        fail ~class_:Tool_result.Runtime_failure ~effect_disposition:Tool_result.Proven_pre_effect
          "worker upload staging was refused; no browser command was dispatched"
      | Error error -> fail ~class_:Tool_result.Dependency_unavailable ~effect_disposition:Tool_result.Proven_pre_effect
          (match error with Browser_addon_client.Unavailable detail|Outcome_unknown detail -> detail) in
  let* binding,result=invoke ?upload_id:(Option.map fst upload_id) t served binding verb ~start_time in
  let raw=Mcp_protocol.Mcp_types.tool_result_to_yojson result in
  if result.is_error=Some true then
    let class_,effect_disposition=Lane_addon_tool_result.failure result in
    fail ?metadata:result._meta ~data:raw ~class_ ~effect_disposition
      ("Browser command failed; inspect its original receipt before further input. " ^ Agent_core.Mcp.text_of_tool_result result)
  else
  let decode ()=
    let* value=Option.to_result ~none:"browser command lacks structured content" result.structured_content in
    let* _=Lane_addon_action.canonical value in
    let* fields=match value with `Assoc fields -> Ok fields|_ -> Error "browser command receipt must be an object" in
    let identity_keys=["browserSelection";"browserConnection"] in
    let* reply=Browser_addon_wire.reply_of_json (`Assoc (List.filter (fun (key,_) -> not (List.mem key identity_keys)) fields)) in
    match reply with
    | Browser_addon_wire.Issue_result (Ok (Browser_lane.Answered (`Assoc payload))) ->
        (match List.assoc_opt "ok" payload,List.assoc_opt "data" payload with
         | Some (`Bool true),Some data -> Ok {binding;data;raw_result=result}
         | (None|Some _),(None|Some _) -> Error "browser success receipt lacks ok/data")
    | Issue_result (Ok (Answered _|Lane_absent|Timed_out|Refused _|Rejected_before_effect _)|Error _)
    | Service_refusal _|Receipt|Snapshot_result _|Model_reply _|Extension_reply _|Download_reply _|Poll_result _ -> Error "unexpected successful browser command receipt" in
  match decode () with
  | Ok receipt -> Ok receipt
  | Error detail -> fail ?metadata:result._meta ~data:raw ~class_:Tool_result.Runtime_failure
      ~effect_disposition:Tool_result.Effect_outcome_unknown detail)
