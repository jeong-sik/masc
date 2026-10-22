module B = Browser_lane
module W = Browser_addon_wire
module S = Mcp_protocol.Mcp_types
let ( let* ) = Result.bind
let field fields name = Option.to_result ~none:("missing browser receipt field: " ^ name)
  (List.assoc_opt name fields)
let object_ = function `Assoc fields -> Ok fields | _ -> Error "invalid browser artifact receipt"
let finalize ~socket ~client ~store ~name ~arguments ~principal ~result =
  if not (String.equal name Browser_addon_tool.definition.name) || result.S.is_error=Some true then Ok result
  else
  let* verb=Browser_addon_tool.command arguments in
  match verb with
  | B.Tabs_list|Page_read _|Page_document _|Page_console _ | Page_network _ | Page_cookies _|Page_capture _|Page_scene _|Page_interact _
  | Session_open _|Session_close|Session_status|Page_goto _|Page_elements _|Page_act _
  | Page_context _|Page_instruct _|Page_locate _|Page_extract _ -> Ok result
  | Page_downloads _ ->
    let* actor=match principal with
      | Lane_addon_call_context.Anonymous -> Error "download finalization requires the original host caller"
      | Keeper _|Authenticated_agent _|Host_actor _|Operator -> Ok (Lane_addon_call_context.actor_label principal) in
    let* value=Option.to_result ~none:"browser download receipt lacks structured content" result.structured_content in
    let* _=Lane_addon_action.canonical value in
    let* fields=object_ value in
    let identity_keys=["browserSelection";"browserConnection"] in
    let* binding=Browser_binding.of_json (`Assoc (List.filter (fun (key,_) -> List.mem key identity_keys) fields)) in
    let route=(Browser_binding.selected binding).route in
    let* ()=match route with
      | B.Automation_route -> Ok ()
      | Stagehand_route|Live_route _ -> Error "download artifacts require the owned Gecko connection" in
    let* reply=W.reply_of_json (`Assoc (List.filter (fun (key,_) -> not (List.mem key identity_keys)) fields)) in
    let* payload=match reply with
      | W.Issue_result (Ok (B.Answered (`Assoc payload))) -> Ok payload
      | Issue_result (Ok (Answered _|Lane_absent|Timed_out|Refused _|Rejected_before_effect _)|Error _)
      | Service_refusal _|Receipt|Snapshot_result _|Model_reply _|Download_reply _|Poll_result _ ->
          Error "download finalization requires an original answered receipt" in
    let* ()=if List.assoc_opt "ok" payload=Some (`Bool true) then Ok ()
      else Error "download receipt was not successful" in
    let* data=field payload "data" in
    let* data=object_ data in
    let* rows=field data "downloads" in
    let* rows=match rows with `List rows -> Ok rows | _ -> Error "download receipt has no rows" in
    let finalize_row row =
      let* fields=object_ row in
      match List.assoc_opt "artifact" fields with
      | None -> Ok row
      | Some (`Assoc ["downloadGrant",`String id]) ->
          let* _=B.client_id_of_string id in
          let* artifact=Browser_addon_client.transfer_download client ~id ~actor ~route ~verb
            ~publish:(Browser_download_artifact.publish_descriptor ~store ~socket) in
          Ok (`Assoc (List.map (fun (key,value) -> key,(if key="artifact" then artifact else value)) fields))
      | Some _ -> Error "download receipt contains an invalid artifact grant" in
    let* rows=List.fold_left (fun result row ->
      let* rows=result in let* row=finalize_row row in Ok (row::rows)) (Ok []) rows in
    let data=`Assoc (List.map (fun (key,value) -> key,(if key="downloads" then `List (List.rev rows) else value)) data) in
    let payload=`Assoc (List.map (fun (key,value) -> key,(if key="data" then data else value)) payload) in
    let value=match W.reply_to_json (W.Issue_result (Ok (B.Answered payload))) with
      | `Assoc reply -> `Assoc (reply @ List.filter (fun (key,_) -> List.mem key identity_keys) fields)
      | value -> value in
    Ok {result with structured_content=Some value;
      content=[S.TextContent {type_="text";text=Yojson.Safe.to_string value;annotations=None}]}
