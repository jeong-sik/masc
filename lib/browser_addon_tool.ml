module B = Browser_lane
module W = Browser_addon_wire
module S = Mcp_protocol.Mcp_types
open Result.Syntax
let object_schema ?(open_fields=false) ~required properties = `Assoc [
  "type",`String "object";"properties",`Assoc properties;
  "required",`List (List.map (fun key -> `String key) required);
  "additionalProperties",`Bool open_fields]
let text_schema = `Assoc ["type",`String "string"]
let enum names = `Assoc ["type",`String "string";"enum",`List (List.map (fun value -> `String value) names)]
let input_schema = object_schema ~required:["lane";"command"] [
  "lane",enum ["live"];"clientId",text_schema;"uploadId",text_schema;
  "command",object_schema ~required:["verb";"args"] [
    "verb",enum ["tabs.list";"page.read";"page.downloads";"page.capture";
      "page.scene";"page.snapshot";"page.interact";"page.native_workflow";
      "page.goto";"page.elements";"page.act";"page.context"];
    "args",object_schema ~open_fields:true ~required:[] []]]
let output_schema = object_schema ~required:["reply";"answer"] [
  "reply",enum ["issue"];
  "answer",object_schema ~required:["status";"payload"] [
    "status",enum ["answered"];
    "payload",object_schema ~open_fields:true ~required:["ok"] [
      "ok",`Assoc ["type",`String "boolean";"const",`Bool true]]]]
let definition : S.tool = {name=W.command_tool_name;
  title=Some "Browser";description=Some
    "Run one closed browser command on the browser the host chose: lane, and for live its clientId except the task Space reclaim (take_over without a clientId on a lane that published a user-owned refusal). The host chooses the browser and states it in the receipt. No JavaScript or debug-protocol escape hatch. Uploads require a host snapshot grant; completed owned downloads are finalized into host artifacts.";
  input_schema;output_schema=Some output_schema;annotations=None;icon=None;execution=None}
let parse json =
  let* fields=match json with
    | `Assoc fields when List.for_all (fun (key,_) -> List.mem key ["lane";"clientId";"command";"uploadId"]) fields
        && List.length fields=List.length (List.sort_uniq String.compare (List.map fst fields)) -> Ok fields
    | _ -> Error "browser command accepts only lane, clientId, command and uploadId" in
  let* client=match List.assoc_opt "clientId" fields with
    | None -> Ok None
    | Some (`String raw) -> B.client_id_of_string raw |> Result.map Option.some
    | Some _ -> Error "clientId must be a canonical browser UUID" in
  let* route=match List.assoc_opt "lane" fields,client with
    | Some (`String "live"),Some client -> Ok (B.Live_route (Some client))
    | Some (`String "live"),None -> Ok (B.Live_route None)
    | (None|Some _),(None|Some _) ->
        Error "lane must name the browser the host chose; a live lane also names its clientId" in
  let* raw=Option.to_result ~none:"command is required" (List.assoc_opt "command" fields) in
  let* verb=W.verb_of_json ~route raw in
  let* ()=match route with
    | B.Live_route None ->
        (match verb with
         | B.Page_act action ->
             if B.Action.is_take_over action then Ok ()
             else Error "a live lane without a clientId answers only its task Space reclaim"
         | B.Tabs_list
         |B.Page_read _|B.Page_document _|B.Page_downloads _
         | B.Page_capture _|B.Page_scene _|B.Page_snapshot _
         |B.Page_native_workflow _|B.Page_interact _|B.Page_goto _|B.Page_elements _
         |B.Page_context _ ->
             Error "a live lane without a clientId answers only its task Space reclaim")
    | B.Live_route (Some _) -> Ok () in
  let* upload_id=match List.assoc_opt "uploadId" fields with
    | None -> Ok None
    | Some (`String raw) -> let* id=B.client_id_of_string raw in Ok (Some (B.client_id_to_string id))
    | Some _ -> Error "uploadId must be a canonical host grant UUID" in
  Ok (route,verb,upload_id)
let command arguments = parse arguments |> Result.map (fun (route,verb,_) -> route,verb)
let transferable verb upload_id = match verb,upload_id with
  | B.Page_act (B.Action.On_tab {interaction=B.Action.Upload _;_}),Some _ -> Ok ()
  | Page_act (B.Action.On_tab {interaction=B.Action.Upload _;_}),None ->
      Error "upload requires a private host snapshot grant; no command was dispatched"
  | (Tabs_list|Page_read _|Page_document _|Page_downloads _|Page_capture _|Page_scene _|Page_snapshot _|Page_interact _|Page_native_workflow _
  | Page_goto _|Page_elements _
  | Page_act (B.Action.Open_tab _|Control _)
  | Page_act (B.Action.On_tab {interaction=(Close_tab|Back|Forward|Reload|Stop_loading|Accept_dialog _|Dismiss_dialog|Set_emulation _|Clear_emulation|Block_requests _|Unblock_requests);_})
  | Page_context _),None -> Ok ()
  | (Tabs_list|Page_read _|Page_document _|Page_downloads _|Page_capture _|Page_scene _|Page_snapshot _|Page_interact _|Page_native_workflow _
    | Page_goto _|Page_elements _|Page_act (Open_tab _|Control _
      |On_tab {interaction=Close_tab|Back|Forward|Reload|Stop_loading|Accept_dialog _|Dismiss_dialog|Set_emulation _|Clear_emulation|Block_requests _|Unblock_requests;_})
    |Page_context _),Some _ -> Error "uploadId applies only to an upload command"
let result ~start_time ~failure data message : S.tool_result =
  let result=match failure with
    | Some (class_,effect_disposition) -> Tool_result.make_err ~tool_name:definition.name ~start_time
        ~class_ ~effect_disposition ~data message
    | None -> Tool_result.make_ok ~tool_name:definition.name ~start_time ~data () in
  {content=[S.TextContent {type_="text";text=Yojson.Safe.to_string data;annotations=None}];
   structured_content=Some data;is_error=Some (Option.is_some failure);_meta=Lane_addon_tool_result.metadata result}
let refused ~start_time ~class_ detail = result ~start_time ~failure:(Some (class_,Tool_result.Proven_pre_effect))
  (W.reply_to_json (W.Service_refusal {message=detail;disposition=W.Not_started})) detail
(* The browser the caller named or the lane it asked for is not here; a
   choice between browsers is the caller's to make. *)
let selection_failure_class = function
  | B.Activity_rejected _ | No_live_client | Selected_client_disconnected _ -> Tool_result.Dependency_unavailable
  | Ambiguous_clients _ | Transport_unsupported _ -> Tool_result.Workflow_rejection
(* What the reply says happened. The class comes only from the reply's
   variant. A failure whose cause is only in words, which the model reads,
   stays Workflow_rejection with the effect its phase states: an answer from
   the browser or its executor, and the worker's own refusal before dispatch,
   even one whose words say a backend is not attached or the worker retired.
   The variants that say a browser is not here, or that no answer came, are
   Dependency_unavailable. A reply this tool cannot read is its own failure. *)
let failure_of_reply = function
  | W.Issue_result (Ok (B.Answered (`Assoc fields))) ->
      (match List.assoc_opt "ok" fields with
       | Some (`Bool true) -> None
       | Some (`Bool false) -> Some (Tool_result.Workflow_rejection,match List.assoc_opt "effectPhase" fields with
           | Some (`String "not_started") -> Tool_result.Proven_pre_effect
           | Some (`String "partial") -> Tool_result.Proven_post_effect
           | Some _|None -> Tool_result.Effect_outcome_unknown)
       | Some _|None -> Some (Tool_result.Runtime_failure,Tool_result.Effect_outcome_unknown))
  | Issue_result (Error selection) -> Some (selection_failure_class selection,Tool_result.Proven_pre_effect)
  | Service_refusal {disposition=W.Not_started;_} | Issue_result (Ok (B.Rejected_before_effect _)) ->
      Some (Tool_result.Workflow_rejection,Tool_result.Proven_pre_effect)
  | Issue_result (Ok (B.Refused _)) -> Some (Tool_result.Workflow_rejection,Tool_result.Effect_outcome_unknown)
  | Issue_result (Ok B.Lane_absent) -> Some (Tool_result.Dependency_unavailable,Tool_result.Proven_pre_effect)
  | Service_refusal {disposition=W.Outcome_unknown;_} | Issue_result (Ok B.Timed_out) ->
      Some (Tool_result.Dependency_unavailable,Tool_result.Effect_outcome_unknown)
  | Issue_result (Ok (B.Answered _))
  | Snapshot_result _|Download_reply _|Poll_result _|Receipt ->
      Some (Tool_result.Runtime_failure,Tool_result.Effect_outcome_unknown)
let invoke ~owner ~principal arguments =
  let start_time=Tool_timing.start () in
  let run () =
  let prepared=let* actor=match principal with
    | Lane_addon_call_context.Anonymous -> Error "browser execution requires verified host caller context"
    | Keeper _|Authenticated_agent _|Host_actor _|Operator -> Ok (Lane_addon_call_context.actor_label principal) in
    let* route,verb,upload_id=parse arguments in let* ()=transferable verb upload_id in
    Ok (actor,route,verb,upload_id) in
  match prepared with
  | Error detail -> refused ~start_time ~class_:Tool_result.Policy_rejection detail
  | Ok (actor,route,verb,upload_id) ->
    let reply=match upload_id with
      | Some id -> Browser_addon_owner.dispatch_upload owner ~id ~actor ~route ~verb
      | None -> Browser_addon_owner.dispatch owner {W.incarnation=Browser_addon_owner.incarnation owner;
          command=W.Issue {route;verb;actor=Some actor;
            timeout_sec=B.reply_timeout_sec verb;only_if_idle=false}} in
    let data=W.reply_to_json reply in
    (* A scoped elements answer counts only with the page's own match count:
       an extension built before [within] answers with every control. *)
    let unscoped=match reply with
      | W.Issue_result (Ok (B.Answered (`Assoc fields))) when List.assoc_opt "ok" fields=Some (`Bool true) ->
          Result.fold ~ok:(fun _ -> None) ~error:Option.some
            (Browser_page_script.check_scoped_elements ~filter:(B.elements_filter verb)
               (Option.value (List.assoc_opt "data" fields) ~default:`Null))
      | Issue_result (Ok (B.Answered _|Lane_absent|Timed_out|Refused _|Rejected_before_effect _))
      | Issue_result (Error _)|Service_refusal _|Snapshot_result _|Download_reply _
      | Poll_result _|Receipt -> None in
    match unscoped with
    | Some detail -> refused ~start_time ~class_:Tool_result.Dependency_unavailable detail
    | None ->
    (* A read leaves browser content unchanged, but can still publish a host
       artifact. Keep the original receipt's evidence of partial or unknown
       effects instead of authorizing replay from the verb classification. *)
    result ~start_time ~failure:(failure_of_reply reply) data "browser command failed; inspect its original receipt before further input" in
  match run () with
  | value -> value
  | exception (Eio.Cancel.Cancelled _ as cancelled) -> raise cancelled
  | exception exn ->
    Printf.eprintf "browser Add-on tool failed: %s\n%!" (Printexc.to_string exn);
    result ~start_time ~failure:(Some (Tool_result.Runtime_failure,Tool_result.Effect_outcome_unknown))
      (W.reply_to_json (W.Service_refusal {message="browser command failed; outcome unknown";disposition=W.Outcome_unknown}))
      "browser command failed; outcome unknown"
