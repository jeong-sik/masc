type source = Browser_lane.Lane_name.t = Live | Automation | Stagehand
type request = { route : Browser_selection.preference; tab_id : int option }
type dialog_kind = Alert | Confirm | Prompt | Beforeunload
type dialog = { kind : dialog_kind; message : string; default_value : string option }
let dialog_kind_to_wire = function
  | Alert -> "alert" | Confirm -> "confirm" | Prompt -> "prompt" | Beforeunload -> "beforeunload"
let dialog_kind_of_wire = function
  | "alert" -> Some Alert | "confirm" -> Some Confirm | "prompt" -> Some Prompt
  | "beforeunload" -> Some Beforeunload | _ -> None
type ego_page_origin = Agent_created | Unknown_origin
type ego_page = { label : string option; target_id : string; opened_by : ego_page_origin }
let ego_page_to_json page = `Assoc [
  "label",(match page.label with None -> `Null | Some label -> `String label);
  "targetId",`String page.target_id;
  "openedBy",`String (match page.opened_by with Agent_created -> "agent" | Unknown_origin -> "unknown")]
let ego_page_of_json = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)=["label";"openedBy";"targetId"] ->
    (match List.assoc_opt "label" fields,List.assoc_opt "targetId" fields,List.assoc_opt "openedBy" fields with
     | Some label,Some (`String target_id),Some (`String origin) when String.trim target_id<>"" ->
       let label=match label with `Null -> Ok None
         | `String value when String.trim value<>"" -> Ok (Some value)
         | _ -> Error "invalid Ego Page label" in
       let opened_by=match origin with "agent" -> Ok Agent_created | "unknown" -> Ok Unknown_origin
         | _ -> Error "unknown Ego Page origin" in
       Result.bind label (fun label -> Result.map (fun opened_by -> {label;target_id;opened_by}) opened_by)
     | (None|Some _),(None|Some _),(None|Some _) -> Error "invalid Ego Page provenance")
  | _ -> Error "invalid or duplicate Ego Page provenance fields"
type tab = { id : int; title : string; url : string; active : bool; window_id : int option;
  dialog : dialog option; ego_page : ego_page option }
type selection = Requested of tab | Active of tab | None_active
open Result.Syntax
let field key = function `Assoc fields -> List.assoc_opt key fields | _ -> None
let parse_client_id = function
  | `Assoc fields ->
    (match List.assoc_opt "clientId" fields with
     | None -> Ok None
     | Some (`String value) -> Result.map Option.some (Browser_lane.client_id_of_string value)
     | _ -> Error "invalid_client_id")
  | _ -> Error "body must be a JSON object"
let parse_request = function
  | `Assoc fields ->
    let lane_error = "lane must be " ^ Browser_lane.Lane_name.expected in
    let* source = match List.assoc_opt "lane" fields with
      | None -> Ok None
      | Some (`String raw) -> Option.to_result ~none:lane_error (Browser_lane.Lane_name.of_wire raw)
          |> Result.map Option.some
      | Some _ -> Error lane_error in
    let* tab_id = match List.assoc_opt "tabId" fields with
      | None -> Ok None
      | Some (`Int id) when id >= 0 -> Ok (Some id)
      | _ -> Error "tabId must be a nonnegative integer" in
    let* client_id = parse_client_id (`Assoc fields) in
    let* route = match source, client_id with
      | None, None -> Ok Browser_selection.Automatic
      | (None | Some Live), Some selected ->
          Ok (Browser_selection.Exact (Browser_lane.Live_route (Some selected)))
      | Some Live, None -> Ok (Browser_selection.Exact (Browser_lane.Live_route None))
      | Some Automation, None -> Ok (Browser_selection.Exact Browser_lane.Automation_route)
      | Some Stagehand, None -> Ok (Browser_selection.Exact Browser_lane.Stagehand_route)
      | Some (Automation | Stagehand), Some _ -> Error "client_id_requires_live" in
    let* () = if List.for_all (fun (key, _) -> List.mem key ["lane";"tabId";"clientId"]) fields
      then Ok () else Error "unknown browser read argument" in
    Ok {route; tab_id}
  | _ -> Error "body must be a JSON object"
let decode_tab json =
  let* ()=match json with
    | `Assoc fields when List.length fields=List.length (List.sort_uniq String.compare (List.map fst fields)) -> Ok ()
    | _ -> Error "invalid or duplicate browser tab fields" in
  match field "id" json, field "title" json, field "url" json, field "active" json with
  | Some (`Int id), Some (`String title), Some (`String url), Some (`Bool active) ->
    let* window_id = match field "windowId" json with
      | None -> Ok None
      | Some (`Int window_id) when window_id >= 0 -> Ok (Some window_id)
      | Some _ -> Error "malformed browser tab window" in
    let* dialog = match field "dialog" json with
      | None -> Ok None
      | Some dialog ->
        (match field "type" dialog, field "message" dialog, field "defaultValue" dialog with
         | Some (`String kind), Some (`String message), default_value ->
           (match dialog_kind_of_wire kind, default_value with
            | Some kind, None -> Ok (Some {kind;message;default_value=None})
            | Some kind, Some (`String value) -> Ok (Some {kind;message;default_value=Some value})
            | None, _ | Some _, Some _ -> Error "malformed browser tab dialog")
         | _ -> Error "malformed browser tab dialog") in
    let* ego_page=match field "egoPage" json with
      | None -> Ok None
      | Some value -> Result.map Option.some (ego_page_of_json value) in
    Ok {id;title;url;active;window_id;dialog;ego_page}
  | _ -> Error "malformed browser tab"
let rec decode_tabs = function
  | [] -> Ok []
  | json :: rest -> let* tab = decode_tab json in let* tabs = decode_tabs rest in Ok (tab :: tabs)
type inventory_completeness = Complete | Partial of Yojson.Safe.t list
type inventory = { tabs : tab list; completeness : inventory_completeness }
let decode_inventory = function
  | `List rows -> let* tabs = decode_tabs rows in Ok {tabs; completeness=Complete}
  | `Assoc fields ->
    (match List.assoc_opt "tabs" fields, List.assoc_opt "unavailableTabs" fields,
           List.assoc_opt "complete" fields with
     | Some (`List rows), Some (`List unavailable), Some (`Bool false) ->
       let* tabs = decode_tabs rows in
       let valid = List.for_all (fun row -> match field "id" row, field "error" row with
         | Some (`Int id), Some (`String _) -> id >= 0
         | _ -> false) unavailable in
       if valid then Ok {tabs; completeness=Partial unavailable}
       else Error "malformed unavailable browser tab"
     | _ -> Error "malformed partial browser inventory")
  | _ -> Error "browser tabs must be a list or inventory"
let dialog_json {kind;message;default_value} =
  `Assoc (["type",`String (dialog_kind_to_wire kind);"message",`String message]
    @ match default_value with Some value -> ["defaultValue",`String value] | None -> [])
let tab_json tab = `Assoc (["id",`Int tab.id;"title",`String tab.title;
  "url",`String tab.url;"active",`Bool tab.active]
  @ (match tab.window_id with Some window_id -> ["windowId",`Int window_id] | None -> [])
  @ (match tab.ego_page with None -> [] | Some page -> ["egoPage",ego_page_to_json page])
  @ match tab.dialog with
    | None -> []
    | Some {kind;message;default_value} ->
      ["dialog",dialog_json {kind;message;default_value}])
let source_name route = Browser_lane.Lane_name.to_wire (Browser_lane.route_lane_name route)
let select ~tab_id tabs = match tab_id with
  | Some id -> (match List.find_opt (fun tab -> tab.id = id) tabs with
      | Some tab -> Ok (Requested tab)
      | None -> Error "selected tab is closed or absent from this browser source")
  | None -> Ok (match List.find_opt (fun tab -> tab.active) tabs with
      | Some tab -> Active tab | None -> None_active)
let selection_json = function
  | Requested _ -> `String "requested" | Active _ -> `String "active" | None_active -> `String "none_active"
type read_plan = {inventory:inventory;selection:selection}
let prepare_read ~tab_id raw_tabs =
  let* inventory = decode_inventory raw_tabs in
  let tabs = inventory.tabs in
  let unavailable = match inventory.completeness with
    | Complete -> []
    | Partial unavailable -> unavailable in
  let* () = match tab_id with
    | None -> Ok ()
    | Some id ->
      (match List.find_opt (fun row -> field "id" row = Some (`Int id)) unavailable with
       | None -> Ok ()
       | Some row ->
         let detail = match field "error" row with
           | Some (`String detail) -> detail
           | _ -> "tab metadata could not be observed" in
         Error (Printf.sprintf "selected tab %d is present but unreadable: %s" id detail)) in
  (* Without a requested tab and without an active tab no page is read: the
     answer says [selection = none_active] and [page = null] instead of the
     caller receiving whichever tab the browser listed first. *)
  let* selection = select ~tab_id tabs in
  Ok {inventory;selection}
let selected_tab plan=match plan.selection with
  | None_active -> None | Requested tab|Active tab -> Some tab
let project_read plan ~binding ~started ~page =
  let selected=Browser_binding.selected binding in
  let lane_name=source_name selected.route in
  let check_provenance provenance=match Browser_binding.backend binding,provenance with
    | Browser_capabilities.Connected Browser_lane.Ego_task_space,Some _ -> Ok ()
    | Connected Ego_task_space,None -> Error "Ego tab is missing its Page provenance"
    | (Connected (Web_extension|Webdriver_bidi)|Owned_gecko|Owned_chromium|Safari_unavailable),None -> Ok ()
    | (Connected (Web_extension|Webdriver_bidi)|Owned_gecko|Owned_chromium|Safari_unavailable),Some _ ->
      Error "Ego Page provenance requires an Ego connection" in
  let rec check_tabs = function
    | [] -> Ok ()
    | (tab:tab)::rest -> let* ()=check_provenance tab.ego_page in check_tabs rest in
  let* ()=check_tabs plan.inventory.tabs in
  let rec check_unavailable = function
    | [] -> Ok ()
    | row::rest ->
      let* ()=match row with
        | `Assoc fields when List.length fields=List.length (List.sort_uniq String.compare (List.map fst fields)) -> Ok ()
        | _ -> Error "invalid or duplicate unavailable tab fields" in
      let* provenance=match field "egoPage" row with
        | None -> Ok None | Some value -> Result.map Option.some (ego_page_of_json value) in
      let* ()=check_provenance provenance in check_unavailable rest in
  let* ()=match plan.inventory.completeness with Complete -> Ok () | Partial rows -> check_unavailable rows in
  let* page = match plan.selection,page with
    | None_active,None -> Ok `Null
    | None_active,Some _ | (Requested _|Active _),None -> Error "page does not match the selected tab"
    | (Requested tab|Active tab),Some data ->
      (match field "url" data, field "title" data, field "text" data,
             field "chars" data, field "truncated" data with
       | Some (`String url), Some (`String title), Some (`String text),
         Some (`Int chars), Some (`Bool truncated) ->
         Ok (`Assoc ["tabId",`Int tab.id;"url",`String url;"title",`String title;
           "text",`String text;"chars",`Int chars;"truncated",`Bool truncated])
       | _ -> Error "browser page lacks URL/title/text/length metadata; update the browser connector") in
  let elapsed_ms = Int64.to_float (Int64.sub (Mtime_clock.elapsed_ns ()) started) /. 1e6 in
  Ok (`Assoc (["tabs",`List (List.map tab_json plan.inventory.tabs);"selection",selection_json plan.selection;"page",page;
    "source",`String lane_name; "browserSelection", Browser_selection.to_json selected]
    @ Browser_binding.connection_fields binding
    @ (match plan.inventory.completeness with Complete -> [] | Partial unavailable ->
        ["complete",`Bool false;"unavailableTabs",`List unavailable])
    @ ["elapsed_ms",`Float elapsed_ms]))

(* Captures always name a tab. An absent/closed target must never capture the
   operator's newly active tab instead. The image is a viewport observation,
   not an assertion that the document remained static while being painted. *)
let parse_capture_request json =
  let* request = parse_request json in
  match request.tab_id with
  | Some _ -> Ok request
  | None -> Error "tabId is required for a screenshot"

let parse_screenshot_request = function
  | `Assoc fields when List.for_all (fun (key,_) -> List.mem key ["lane";"clientId";"tabId";"screenshotOptions"]) fields
      && List.length fields=List.length (List.sort_uniq String.compare (List.map fst fields)) ->
    let* request=parse_capture_request (`Assoc (List.remove_assoc "screenshotOptions" fields)) in
    let* options=Browser_lane.Capture.of_optional_json (List.assoc_opt "screenshotOptions" fields) in
    Ok (request,options)
  | _ -> Error "unknown or duplicate screenshot request fields"

let capture_image_from ~binding ~tab_id ~started data =
  let selected=Browser_binding.selected binding in
  let lane_name=source_name selected.route in
  match field "tabId" data, field "url" data, field "title" data,
        field "mimeType" data, field "data" data with
  | Some (`Int actual), Some (`String url), Some (`String title),
    Some (`String "image/png"), Some (`String image) when actual = tab_id ->
    let max_bytes = Keeper_vision_tool.max_image_bytes () in
    let* () = if String.length image > ((max_bytes + 2) / 3) * 4
      then Error "screenshot exceeds Vision image size limit" else Ok () in
    let* bytes = match Base64.decode image with
      | Ok bytes when String.starts_with ~prefix:"\137PNG\r\n\026\n" bytes -> Ok bytes
      | Ok _ -> Error "screenshot payload is not PNG"
      | Error (`Msg detail) -> Error ("invalid screenshot base64: " ^ detail) in
    if String.length bytes = 0 then Error "empty screenshot"
    else
      let elapsed_ms = Int64.to_float (Int64.sub (Mtime_clock.elapsed_ns ()) started) /. 1e6 in
      Ok (`Assoc (["source", `String lane_name; "browserSelection", Browser_selection.to_json selected]
        @ Browser_binding.connection_fields binding
        @ ["tabId", `Int tab_id;
           "title", `String title; "url", `String url; "mimeType", `String "image/png";
           "data", `String image;
           "elapsed_ms", `Float elapsed_ms]))
  | _ -> Error "screenshot response does not match the requested tab or PNG contract"

let capture_from ~binding ~tab_id ~started data =
  let* ()=if field "captureOptions" data=None then Ok ()
    else Error "native screenshot cannot be projected as a viewport pointer frame" in
  let* image=capture_image_from ~binding ~tab_id ~started data in
  let* viewport=match field "viewport" data with
    | Some json -> Browser_lane.Pointer.viewport_of_json json
    | None -> Error "screenshot lacks viewport metadata; update the browser connector" in
  match image with
  | `Assoc fields -> Ok (`Assoc (("viewport",Browser_lane.Pointer.viewport_to_json viewport)::fields))
  | _ -> Error "invalid viewport screenshot projection"

let native_capture_from ~binding ~tab_id ~started ~options data =
  let* ()=match data with
    | `Assoc fields when List.length fields=List.length (List.sort_uniq String.compare (List.map fst fields)) -> Ok ()
    | _ -> Error "invalid or duplicate native screenshot response fields" in
  let* observed=Browser_lane.Capture.of_optional_json (field "captureOptions" data) in
  let* ()=if observed=Some options && field "viewport" data=None then Ok ()
    else Error "native screenshot options or coordinate scope do not match the request" in
  let* image=capture_image_from ~binding ~tab_id ~started data in
  match image with
  | `Assoc fields -> Ok (`Assoc (("scope",`String "page")::
      ("captureOptions",Browser_lane.Capture.to_json options)::fields))
  | _ -> Error "invalid native screenshot projection"
