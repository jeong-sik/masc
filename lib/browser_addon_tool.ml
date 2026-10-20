module B = Browser_lane
module W = Browser_addon_wire
module S = Mcp_protocol.Mcp_types
let ( let* ) = Result.bind
let object_schema ?(open_fields=false) ~required properties = `Assoc [
  "type",`String "object";"properties",`Assoc properties;
  "required",`List (List.map (fun key -> `String key) required);
  "additionalProperties",`Bool open_fields]
let text_schema = `Assoc ["type",`String "string"]
let enum names = `Assoc ["type",`String "string";"enum",`List (List.map (fun value -> `String value) names)]
let input_schema = object_schema ~required:["command"] [
  "lane",enum ["live";"automation";"stagehand"];"clientId",text_schema;
  "command",object_schema ~required:["verb";"args"] [
    "verb",enum ["tabs.list";"page.read";"page.downloads";"page.capture";
      "page.scene";"page.interact";"session.open";"session.close";"session.status";
      "page.goto";"page.elements";"page.act";"page.context";"page.instruct";"page.locate";"page.extract"];
    "args",object_schema ~open_fields:true ~required:[] []]]
let output_schema = object_schema ~required:["reply";"answer";"browserSelection"] [
  "reply",enum ["issue"];
  "answer",object_schema ~required:["status";"payload"] [
    "status",enum ["answered"];
    "payload",object_schema ~open_fields:true ~required:["ok"] [
      "ok",`Assoc ["type",`String "boolean";"const",`Bool true]]];
  "browserSelection",object_schema ~open_fields:true ~required:["lane";"reason"] [
    "lane",enum ["live";"automation";"stagehand"];"reason",text_schema]]
let definition : S.tool = {name="browser_command";
  title=Some "Browser";description=Some
    "Use an installed browser Add-on. Send one closed browser command. With no tab/document binding, browser choice is automatic; retain the returned lane/clientId for later bound commands. No JavaScript or debug-protocol escape hatch. Uploads/downloads require a host artifact broker.";
  input_schema;output_schema=Some output_schema;annotations=None;icon=None;execution=None}
let parse json =
  let* fields=match json with
    | `Assoc fields when List.for_all (fun (key,_) -> List.mem key ["lane";"clientId";"command"]) fields
        && List.length fields=List.length (List.sort_uniq String.compare (List.map fst fields)) -> Ok fields
    | _ -> Error "browser command accepts only lane, clientId and command" in
  let* client=match List.assoc_opt "clientId" fields with
    | None -> Ok None
    | Some (`String raw) -> B.client_id_of_string raw |> Result.map Option.some
    | Some _ -> Error "clientId must be a canonical browser UUID" in
  let* preference,route=match List.assoc_opt "lane" fields,client with
    | None,None -> Ok (Browser_selection.Automatic,B.Live_route None)
    | (None|Some (`String "live")),Some client ->
        let route=B.Live_route (Some client) in Ok (Browser_selection.Exact route,route)
    | Some (`String "live"),None -> Ok (Browser_selection.Exact (B.Live_route None),B.Live_route None)
    | Some (`String "automation"),None -> Ok (Browser_selection.Exact B.Automation_route,B.Automation_route)
    | Some (`String "stagehand"),None -> Ok (Browser_selection.Exact B.Stagehand_route,B.Stagehand_route)
    | Some _,(None|Some _) -> Error "lane must name a browser backend; clientId belongs only to live" in
  let* raw=Option.to_result ~none:"command is required" (List.assoc_opt "command" fields) in
  let* verb=W.verb_of_json ~route raw in Ok (preference,verb)
let bound = function
  | B.Page_read {tab_id;_}|Page_elements {tab_id} -> Option.is_some tab_id
  | Page_act (B.Action.Open_tab _) | Tabs_list | Session_open _ | Session_status -> false
  | Page_document _|Page_downloads _|Page_capture _|Page_scene _|Page_interact _|Session_close
  | Page_goto _|Page_act (B.Action.On_tab _)|Page_context _|Page_instruct _|Page_locate _|Page_extract _ -> true
let transferable = function
  | B.Page_downloads _ | Page_act (B.Action.On_tab {interaction=B.Action.Upload _;_}) ->
      Error "browser file transfers require the host artifact/upload broker; no command was dispatched"
  | Tabs_list|Page_read _|Page_document _|Page_capture _|Page_scene _|Page_interact _
  | Session_open _|Session_close|Session_status|Page_goto _|Page_elements _
  | Page_act (B.Action.Open_tab _)
  | Page_act (B.Action.On_tab {interaction=(Click _|Fill _|Press _|Scroll _|Select _|Close_tab|Back|Forward|Reload|Accept_dialog _|Dismiss_dialog);_})
  | Page_context _|Page_instruct _|Page_locate _|Page_extract _ -> Ok ()
let result ~start_time ~failed ~disposition data message : S.tool_result =
  let result=if failed then Tool_result.make_err ~tool_name:definition.name ~start_time
    ~class_:Tool_result.Workflow_rejection ~effect_disposition:disposition ~data message
    else Tool_result.make_ok ~tool_name:definition.name ~start_time ~data () in
  {content=[S.TextContent {type_="text";text=Yojson.Safe.to_string data;annotations=None}];
   structured_content=Some data;is_error=Some failed;_meta=Lane_addon_tool_result.metadata result}
let refused ~start_time detail = result ~start_time ~failed:true ~disposition:Tool_result.Proven_pre_effect
  (W.reply_to_json (W.Service_refusal {message=detail;disposition=W.Not_started})) detail
let invoke ~owner ~principal arguments =
  let start_time=Tool_timing.start () in
  let run () =
  let prepared=let* actor=match principal with
    | Lane_addon_call_context.Anonymous -> Error "browser execution requires verified host caller context"
    | Keeper _|Authenticated_agent _|Host_actor _|Operator -> Ok (Lane_addon_call_context.actor_label principal) in
    let* preference,verb=parse arguments in let* ()=transferable verb in
    let* selected=Browser_selection.resolve ~verb ~bound:(bound verb) preference
      |> Result.map_error Browser_selection.error_message in
    let* target=B.resolve_target ~verb selected.route |> Result.map_error B.selection_error_message in
    Ok (actor,verb,Browser_selection.bind_target selected target) in
  match prepared with
  | Error detail -> refused ~start_time detail
  | Ok (actor,verb,selected) ->
    let reply=Browser_addon_owner.dispatch owner {W.incarnation=Browser_addon_owner.incarnation owner;
      command=W.Issue {route=selected.route;verb;actor=Some actor;
        timeout_sec=B.default_timeout_sec;only_if_idle=false}} in
    let data=match W.reply_to_json reply with
      | `Assoc fields -> `Assoc (fields @ ["browserSelection",Browser_selection.to_json selected])
      | value -> value in
    let failed,disposition=match reply with
      | W.Issue_result (Ok (B.Answered (`Assoc fields))) ->
          (match List.assoc_opt "ok" fields with
           | Some (`Bool true) -> false,Tool_result.Proven_post_effect
           | Some (`Bool false) -> true,(match List.assoc_opt "effectPhase" fields with
               | Some (`String "not_started") -> Tool_result.Proven_pre_effect
               | Some (`String "partial") -> Tool_result.Proven_post_effect
               | Some _|None -> Tool_result.Effect_outcome_unknown)
           | Some _|None -> true,Tool_result.Effect_outcome_unknown)
      | Service_refusal {disposition=W.Not_started;_}|Issue_result (Error _)
      | Issue_result (Ok (B.Lane_absent|Rejected_before_effect _)) -> true,Tool_result.Proven_pre_effect
      | Service_refusal {disposition=W.Outcome_unknown;_}|Issue_result (Ok (B.Timed_out|Refused _|Answered _))
      | Snapshot_result _|Poll_result _|Receipt -> true,Tool_result.Effect_outcome_unknown in
    result ~start_time ~failed ~disposition data "browser command failed; inspect its original receipt before further input" in
  match run () with
  | value -> value
  | exception (Eio.Cancel.Cancelled _ as cancelled) -> raise cancelled
  | exception exn ->
    Printf.eprintf "browser Add-on tool failed: %s\n%!" (Printexc.to_string exn);
    result ~start_time ~failed:true ~disposition:Tool_result.Effect_outcome_unknown
      (W.reply_to_json (W.Service_refusal {message="browser command failed; outcome unknown";disposition=W.Outcome_unknown}))
      "browser command failed; outcome unknown"
