module B = Browser_lane
module Host = Browser_addon_host
let ( let* ) = Result.bind
let tool_name=Browser_addon_tool.definition.name
let failure ~class_ ~effect_disposition detail = Tool_result.make_err
  ~tool_name ~start_time:(Tool_timing.start ()) ~class_ ~effect_disposition detail
let input result=Result.map_error (failure ~class_:Tool_result.Policy_rejection
  ~effect_disposition:Tool_result.Proven_pre_effect) result
let projection result=Result.map_error (failure ~class_:Tool_result.Runtime_failure
  ~effect_disposition:Tool_result.Proven_pre_effect) result
let surface result=result |> Result.map_error Browser_surface.failure_message |> projection
let run work =
  let start_time=Tool_timing.start () in
  match work () with Ok data -> Tool_result.make_ok ~tool_name ~start_time ~data () | Error error -> error
let parse parser json = let* _=input (Lane_addon_action.canonical json) in input (parser json)
let bound request = match request.Browser_surface.route,request.tab_id with
  | (Browser_selection.Automatic|Exact (B.Live_route None)),Some _ ->
      input (Error (Browser_selection.error_message Binding_required))
  | (Automatic|Exact (B.Live_route None)),None
  | Exact (B.Live_route (Some _)|Automation_route|Stagehand_route),(None|Some _) -> Ok ()
let read host json=run (fun () ->
  let started=Mtime_clock.elapsed_ns () in
  let* request=parse Browser_surface.parse_request json in
  let* ()=bound request in
  let* first=Host.issue host ~preference:request.route B.Tabs_list in
  let* plan=surface (Browser_surface.prepare_read ~tab_id:request.tab_id first.data) in
  let* page=match Browser_surface.selected_tab plan with
    | None -> Ok None
    | Some tab ->
        let* next=Host.issue host ~preference:(Browser_selection.Exact (Browser_binding.selected first.binding).route)
          (B.Page_read {tab_id=Some tab.id;max_chars=Some Browser_page_script.default_text_chars}) in
        let* ()=projection (if Browser_binding.same_connection first.binding next.binding then Ok ()
          else Error "browser changed connection during page observation") in
        Ok (Some next.data) in
  surface (Browser_surface.project_read plan ~binding:first.binding ~started ~page))
let scene host json=run (fun () ->
  let started=Mtime_clock.elapsed_ns () in
  let* request=parse Browser_scene.parse_request json in
  let* ()=bound request.surface in
  let* tab_id=input (Option.to_result ~none:"scene requires tabId" request.surface.tab_id) in
  let* receipt=Host.issue host ~preference:request.surface.route
    (B.Page_scene {tab_id;max_chars=request.max_chars;view=request.view;scope=request.scope}) in
  projection (Browser_scene.project request ~binding:receipt.binding ~started receipt.data))
let capture host json=run (fun () ->
  let started=Mtime_clock.elapsed_ns () in
  let* request=parse Browser_surface.parse_capture_request json in
  let* ()=bound request in
  let* tab_id=input (Option.to_result ~none:"screenshot requires tabId" request.tab_id) in
  let* receipt=Host.issue host ~preference:request.route (B.Page_capture {tab_id}) in
  surface (Browser_surface.capture_from ~binding:receipt.binding ~tab_id ~started receipt.data))
let interact host json=run (fun () ->
  let* request=parse Browser_interaction.parse json in
  let* receipt=Host.issue host ~preference:request.route
    (B.Page_interact {tab_id=request.tab_id;expected_url=request.expected_url;action=request.action}) in
  Ok (Browser_binding.annotate receipt.binding receipt.data))
let request_fields allowed = function
  | `Assoc fields when List.for_all (fun (key,_) -> List.mem key allowed) fields -> Ok fields
  | _ -> Error "unknown browser request argument"
let route fields = Browser_surface.parse_request (`Assoc
  (List.filter (fun (key,_) -> List.mem key ["lane";"clientId";"tabId"]) fields))
let session host json=run (fun () ->
  let* fields=parse (request_fields ["lane";"clientId";"tabId";"action";"headless"]) json in
  let* request=input (route fields) in
  let* headless=input (match List.assoc_opt "headless" fields with
    | None -> Ok (Some false)|Some (`Bool value) -> Ok (Some value)|Some _ -> Error "headless must be boolean") in
  let* verb=input (match List.assoc_opt "action" fields with
    | Some (`String "open") -> Ok (B.Session_open {headless})
    | Some (`String "close") -> Ok B.Session_close
    | Some (`String "status") -> Ok B.Session_status
    | None|Some _ -> Error "action must be open, close or status") in
  let* receipt=Host.issue host ~preference:request.route verb in
  Ok (Browser_binding.annotate receipt.binding receipt.data))
let goto host json=run (fun () ->
  let* fields=parse (request_fields ["lane";"clientId";"tabId";"url"]) json in
  let* request=input (route fields) in
  let* url=input (match List.assoc_opt "url" fields with
    | Some (`String url) -> let uri=Uri.of_string url in
        (match Uri.scheme uri,Uri.host uri with Some ("http"|"https"),Some host when host<>"" -> Ok url
          | (None|Some _),(None|Some _) -> Error "url must be an absolute HTTP(S) URL")
    | None|Some _ -> Error "url is required") in
  let* receipt=Host.issue host ~preference:request.route (B.Page_goto {url;tab_id=request.tab_id}) in
  Ok (Browser_binding.annotate receipt.binding receipt.data))
let clients host=run (fun () ->
  let* value=Host.snapshot host |> Result.map_error (function
    | Browser_addon_client.Unavailable detail|Outcome_unknown detail ->
        failure ~class_:Tool_result.Dependency_unavailable ~effect_disposition:Tool_result.Proven_pre_effect detail) in
  let* _=projection (Lane_addon_action.canonical value) in
  let* rows,automation,stagehand=projection (match value with
    | `Assoc fields ->
        (match List.assoc_opt "state" fields,List.assoc_opt "owned_backends" fields,
          List.assoc_opt "clients" fields with
         | Some (`String "serving"),Some owned,Some (`List rows) ->
             let* automation,stagehand=Browser_addon_inventory.owned_of_json owned in
             Ok (rows,automation,stagehand)
         | (None|Some _),(None|Some _),(None|Some _) -> Error "browser inventory is unavailable")
    | _ -> Error "browser inventory is unavailable") in
  let rec decode acc = function
    | [] -> Ok (List.rev acc)
    | `Assoc fields::rest ->
        let* client=projection (Browser_addon_wire.client_of_json (`Assoc (List.remove_assoc "interactions" fields))) in
        let* ()=projection (if List.exists (fun known -> known.B.client_id=client.client_id) acc
          then Error "duplicate browser inventory client" else Ok ()) in
        decode (client::acc) rest
    | _::_ -> projection (Error "invalid browser inventory client") in
  let* live_clients=decode [] rows in
  let snapshot={Browser_selection.live_activity=B.Enabled;live_clients;automation;stagehand} in
  let decision verb=match Browser_selection.choose ~verb ~bound:false ~snapshot Browser_selection.Automatic with
    | Ok selected -> `Assoc ["ok",`Bool true;"data",Browser_selection.to_json selected]
    | Error error -> `Assoc ["ok",`Bool false;"error",Browser_selection.error_to_json error] in
  Ok (`Assoc ["clients",`List rows;"automatic",`Assoc ["browse",decision B.Tabs_list;
    "work",decision (B.Session_open {headless=Some false})]]))
