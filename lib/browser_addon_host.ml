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
let snapshot t =
  let* reply=R.call_browser_service ~config:t.config ~access:t.access ~service:t.service
    ~command:Browser_addon_wire.Snapshot in
  match reply with
  | Browser_addon_wire.Snapshot_result value -> Ok value
  | Service_refusal {message;disposition=Not_started} -> Error (Browser_addon_client.Unavailable message)
  | Service_refusal {message;disposition=Outcome_unknown} -> Error (Browser_addon_client.Outcome_unknown message)
  | Receipt|Issue_result _|Poll_result _ -> Error (Browser_addon_client.Outcome_unknown "unexpected browser snapshot reply")
