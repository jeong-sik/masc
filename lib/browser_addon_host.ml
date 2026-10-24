module R = Lane_addon_runtime
type t = {
  config : Workspace.config;
  access : Lane_addon_sources.access;
  principal : Lane_addon_call_context.principal;
  reserved : string list;
  service : R.browser_service;
  export : R.tool_export;
}
let ( let* ) = Result.bind
let connect ~config ~access ~principal ~reserved =
  let* ()=match principal with
    | Lane_addon_call_context.Anonymous -> Error (R.Host_refusal
        (Lane_addon_call_context.Rejected "browser calls require verified host authority"))
    | Keeper _|Authenticated_agent _|Host_actor _|Operator -> Ok () in
  let browser=R.browser_service_reading ~config ~access in
  let* service=match browser.services with
    | [service] -> Ok service
    | [] -> Error (R.Unavailable (match Lane_addon_unready.summary browser.unready with
        | Some reason -> reason
        | None -> "no browser Add-on is attached"))
    | _::_::_ -> Error (R.Unavailable "multiple visible browser Add-ons are attached") in
  let* reading=R.tool_export_reading ~config ~access ~reserved |> Result.map_error (fun detail -> R.Unavailable detail) in
  let* export=match List.filter (fun (export:R.tool_export) ->
    export.instance_id=service.instance_id && export.tool.name=Browser_addon_tool.definition.name
    && Lane_addon_tool_export.equal_owner export.owner service.owner) reading.exports with
    | [export] -> Ok export
    | []|_::_::_ -> Error (R.Unavailable "the original browser Add-on command is unavailable") in
  Ok {config;access;principal;reserved;service;export}
let call t ~arguments = Machine_addon_host.call ~continuation:None ~principal:t.principal ~config:t.config
  ~access:t.access ~reserved:t.reserved ~export:t.export ~arguments
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
let snapshot t =
  let* reply=R.call_browser_service ~config:t.config ~access:t.access ~service:t.service
    ~command:Browser_addon_wire.Snapshot in
  match reply with
  | Browser_addon_wire.Snapshot_result value -> Ok value
  | Service_refusal {message;disposition=Not_started} -> Error (Browser_addon_client.Unavailable message)
  | Service_refusal {message;disposition=Outcome_unknown} -> Error (Browser_addon_client.Outcome_unknown message)
  | Model_reply _|Extension_reply _|Download_reply _|Receipt|Issue_result _|Poll_result _ -> Error (Browser_addon_client.Outcome_unknown "unexpected browser snapshot reply")
(* A worker answers its snapshot only while it serves (decode_snapshot), so
   the live lane it reports is on. *)
type snapshot_failure = Snapshot_unavailable of string | Snapshot_unreadable of string
let selection_snapshot t =
  match snapshot t with
  | Error (Browser_addon_client.Unavailable detail|Outcome_unknown detail) -> Error (Snapshot_unavailable detail)
  | Ok value ->
    let decoded=let* _=Lane_addon_action.canonical value in Browser_addon_observation.decode_snapshot value in
    match decoded with
    | Error detail -> Error (Snapshot_unreadable detail)
    | Ok published -> Ok (published,{Browser_selection.live_activity=Browser_lane.Enabled;live_clients=published.clients;
        automation=published.automation;stagehand=published.stagehand})
type receipt = {binding:Browser_binding.t;data:Yojson.Safe.t;
  raw_result:Mcp_protocol.Mcp_types.tool_result}
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
let dispatch ?upload_id ~required_actions t ~preference verb ~start_time =
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
        refuse "live open_tab, open_window, hand_off and take_over require an explicit observed clientId"
    | Exact (Browser_lane.Automation_route|Stagehand_route),Browser_lane.Page_act (Browser_lane.Action.Control _) ->
        refuse Browser_lane.handoff_refused
    | Exact (Browser_lane.Live_route (Some _)),Browser_lane.Page_act (Browser_lane.Action.Control _) -> Ok ()
    | (Automatic|Exact (Live_route _|Automation_route|Stagehand_route)),
      (Tabs_list|Page_read _|Page_document _|Page_downloads _ | Page_console _ | Page_network _ | Page_cookies _|Page_capture _|Page_scene _|Page_snapshot _|Page_native_workflow _|Page_interact _
      |Session_open _|Session_close|Session_status|Page_goto _|Page_elements _|Page_act (Browser_lane.Action.Open_tab _|Open_window _|On_tab _)|Page_context _
      |Page_instruct _|Page_locate _|Page_extract _) -> Ok () in
  let* binding=match preference,required_actions with
    (* An explicit owned route with nothing to check against its snapshot
       names its browser already; the worker checks the lane again before it
       dispatches (RFC #45368 4.2). *)
    | Browser_selection.Exact Browser_lane.Automation_route,[] ->
        Ok (Browser_binding.of_browser {Browser_selection.route=Browser_lane.Automation_route;
          reason=Browser_selection.Explicit_browser} Browser_selection.Owned_automation)
    | Exact Stagehand_route,[] ->
        Ok (Browser_binding.of_browser {Browser_selection.route=Browser_lane.Stagehand_route;
          reason=Browser_selection.Explicit_browser} Browser_selection.Owned_stagehand)
    | (Automatic|Exact (Live_route _)),_ | Exact (Automation_route|Stagehand_route),_::_ ->
      let* published,snapshot=match selection_snapshot t with
        | Ok value -> Ok value
        | Error (Snapshot_unavailable detail) -> fail ~class_:Tool_result.Dependency_unavailable
            ~effect_disposition:Tool_result.Proven_pre_effect
            ("browser snapshot is unavailable; no browser command was dispatched: " ^ detail)
        | Error (Snapshot_unreadable detail) -> fail ~class_:Tool_result.Runtime_failure
            ~effect_disposition:Tool_result.Proven_pre_effect
            ("browser snapshot is unreadable; no browser command was dispatched: " ^ detail) in
      let* selected=Browser_selection.choose ~required_actions ~verb ~bound:(Browser_selection.bound verb) ~snapshot preference
        |> Result.fold ~ok:Result.ok ~error:(unchosen ~clients:published.clients) in
      let* browser=Browser_selection.target ~verb ~snapshot selected.route
        |> Result.fold ~ok:Result.ok ~error:(fun error -> refuse (Browser_lane.selection_error_message error)) in
      let* ()=Browser_selection.require ~snapshot required_actions browser
        |> Result.fold ~ok:Result.ok ~error:(unchosen ~clients:published.clients) in
      Ok (Browser_binding.of_browser selected browser) in
  let grant=match upload_id with None -> []|Some id -> ["uploadId",`String id] in
  match call t ~arguments:(`Assoc (route_arguments (Browser_binding.selected binding).route @ grant
      @ ["command",Browser_lane.verb_json verb])) with
  | Error error -> Error (error_result ~start_time error)
  | Ok result -> Ok (binding,stamp binding result)
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
let issue ?upload_paths ?(required_actions=[]) t ~preference verb =
  let start_time=Tool_timing.start () in
  let fail ?metadata ?(data=`Null) ~class_ ~effect_disposition message =
    Error (Tool_result.make_err ~tool_name:Browser_addon_tool.definition.name ~start_time
      ?metadata ~data ~class_ ~effect_disposition message) in
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
  let discard ()=Option.iter (fun (id,_) -> Eio.Cancel.protect (fun () ->
    ignore (R.call_browser_service ~config:t.config ~access:t.access ~service:t.service
      ~command:(Browser_addon_wire.Upload_discard id)))) upload_id in
  Fun.protect ~finally:discard (fun () ->
  let* ()=match upload_id with
    | None -> Ok ()
    | Some (id,route) ->
      match R.call_browser_service ~config:t.config ~access:t.access ~service:t.service
        ~command:(Browser_addon_wire.Upload_stage {id;actor=Lane_addon_call_context.actor_label t.principal;
          route;verb}) with
      | Ok Browser_addon_wire.Receipt -> Ok ()
      | Ok (Browser_addon_wire.Snapshot_result _|Model_reply _|Extension_reply _|Download_reply _|Poll_result _|Issue_result _|Service_refusal _) ->
        fail ~class_:Tool_result.Runtime_failure ~effect_disposition:Tool_result.Proven_pre_effect
          "worker upload staging was refused; no browser command was dispatched"
      | Error error -> fail ~class_:Tool_result.Dependency_unavailable ~effect_disposition:Tool_result.Proven_pre_effect
          (match error with Browser_addon_client.Unavailable detail|Outcome_unknown detail -> detail) in
  let* binding,result=dispatch ?upload_id:(Option.map fst upload_id) ~required_actions t ~preference verb ~start_time in
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
