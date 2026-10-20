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
  let* service=match R.browser_services ~config ~access with
    | [service] -> Ok service
    | [] -> Error (R.Unavailable "no browser Add-on is attached")
    | _::_::_ -> Error (R.Unavailable "multiple visible browser Add-ons are attached") in
  let* exports=R.tool_exports ~config ~access ~reserved |> Result.map_error (fun detail -> R.Unavailable detail) in
  let* export=match List.filter (fun (export:R.tool_export) ->
    export.instance_id=service.instance_id && export.tool.name=Browser_addon_tool.definition.name
    && Lane_addon_tool_export.equal_owner export.owner service.owner) exports with
    | [export] -> Ok export
    | []|_::_::_ -> Error (R.Unavailable "the original browser Add-on command is unavailable") in
  Ok {config;access;principal;reserved;service;export}
let call t ~arguments = Machine_addon_host.call ~principal:t.principal ~config:t.config
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
  | Model_reply _|Receipt|Issue_result _|Poll_result _ -> Error (Browser_addon_client.Outcome_unknown "unexpected browser snapshot reply")
type receipt = {binding:Browser_binding.t;data:Yojson.Safe.t;
  raw_result:Mcp_protocol.Mcp_types.tool_result}
let issue ?upload_paths ?(required_actions=[]) t ~preference verb =
  let start_time=Tool_timing.start () in
  let fail ?metadata ?(data=`Null) ~class_ ~effect_disposition message =
    Error (Tool_result.make_err ~tool_name:Browser_addon_tool.definition.name ~start_time
      ?metadata ~data ~class_ ~effect_disposition message) in
  let route_fields=match preference with
    | Browser_selection.Automatic -> []
    | Exact (Browser_lane.Live_route client) -> ["lane",`String "live"] @
        (match client with None -> []|Some id -> ["clientId",`String (Browser_lane.client_id_to_string id)])
    | Exact Automation_route -> ["lane",`String "automation"]
    | Exact Stagehand_route -> ["lane",`String "stagehand"] in
  let required=match required_actions with [] -> [] | _::_ -> ["requiredActions",`List
    (List.map (fun action -> `String (Browser_capabilities.operation_name action)) required_actions)] in
  let upload=match verb with
    | Browser_lane.Page_act (Browser_lane.Action.On_tab {interaction=Upload {paths;_};_}) -> Some paths
    | Tabs_list|Page_read _|Page_document _|Page_downloads _|Page_capture _|Page_scene _|Page_interact _
    |Session_open _|Session_close|Session_status|Page_goto _|Page_elements _
    |Page_act (Open_tab _|On_tab {interaction=Click _|Fill _|Press _|Scroll _|Select _|Close_tab|Back|Forward|Reload|Accept_dialog _|Dismiss_dialog;_})
    |Page_context _|Page_instruct _|Page_locate _|Page_extract _ -> None in
  let preparation=match upload,upload_paths,preference with
    | None,None,_ -> Ok None
    | Some paths,Some supplied,Browser_selection.Exact Browser_lane.Automation_route
        when paths=supplied && Browser_lane.Upload_lease.pending ~paths ->
        Ok (Some (Uuidm.(to_string (v4_gen (Random.State.make_self_init ()) ()))))
    | (None|Some _),(None|Some _),(Browser_selection.Automatic|Exact (Live_route _|Automation_route|Stagehand_route)) -> Error "upload requires an exact pending host snapshot batch and owned automation route" in
  let* upload_id=match preparation with
    | Ok id -> Ok id | Error detail -> fail ~class_:Tool_result.Workflow_rejection
        ~effect_disposition:Tool_result.Proven_pre_effect detail in
  let discard ()=Option.iter (fun id -> Eio.Cancel.protect (fun () ->
    ignore (R.call_browser_service ~config:t.config ~access:t.access ~service:t.service
      ~command:(Browser_addon_wire.Upload_discard id)))) upload_id in
  Fun.protect ~finally:discard (fun () ->
  let* ()=match upload_id with
    | None -> Ok ()
    | Some id ->
      match R.call_browser_service ~config:t.config ~access:t.access ~service:t.service
        ~command:(Browser_addon_wire.Upload_stage {id;actor=Lane_addon_call_context.actor_label t.principal;
          route=Browser_lane.Automation_route;verb}) with
      | Ok Browser_addon_wire.Receipt -> Ok ()
      | Ok (Browser_addon_wire.Snapshot_result _|Model_reply _|Poll_result _|Issue_result _|Service_refusal _) ->
        fail ~class_:Tool_result.Runtime_failure ~effect_disposition:Tool_result.Proven_pre_effect
          "worker upload staging was refused; no browser command was dispatched"
      | Error error -> fail ~class_:Tool_result.Dependency_unavailable ~effect_disposition:Tool_result.Proven_pre_effect
          (match error with Browser_addon_client.Unavailable detail|Outcome_unknown detail -> detail) in
  let grant=match upload_id with None -> []|Some id -> ["uploadId",`String id] in
  match call t ~arguments:(`Assoc (route_fields @ required @ grant @ ["command",Browser_lane.verb_json verb])) with
  | Error error -> Error (error_result ~start_time error)
  | Ok result ->
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
        let* binding=Browser_binding.of_json (`Assoc (List.filter (fun (key,_) -> List.mem key identity_keys) fields)) in
        let selected=Browser_binding.selected binding in
        let* ()=if (match preference with
          | Browser_selection.Automatic -> true
          | Exact expected -> (match expected,selected.route with
              | Browser_lane.Live_route None,Browser_lane.Live_route (Some _) -> true
              | (Live_route _|Automation_route|Stagehand_route),
                (Live_route _|Automation_route|Stagehand_route) -> expected=selected.route)) then Ok ()
          else Error "browser command receipt changed the requested connection" in
        let* reply=Browser_addon_wire.reply_of_json (`Assoc (List.filter (fun (key,_) -> not (List.mem key identity_keys)) fields)) in
        match reply with
        | Browser_addon_wire.Issue_result (Ok (Browser_lane.Answered (`Assoc payload))) ->
            (match List.assoc_opt "ok" payload,List.assoc_opt "data" payload with
             | Some (`Bool true),Some data -> Ok {binding;data;raw_result=result}
             | (None|Some _),(None|Some _) -> Error "browser success receipt lacks ok/data")
        | Issue_result (Ok (Answered _|Lane_absent|Timed_out|Refused _|Rejected_before_effect _)|Error _)
        | Service_refusal _|Receipt|Snapshot_result _|Model_reply _|Poll_result _ -> Error "unexpected successful browser command receipt" in
      match decode () with
      | Ok receipt -> Ok receipt
      | Error detail -> fail ?metadata:result._meta ~data:raw ~class_:Tool_result.Runtime_failure
          ~effect_disposition:Tool_result.Effect_outcome_unknown detail)
