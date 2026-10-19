type source = Browser_lane.Lane_name.t = Live | Automation | Stagehand
type request = { route : Browser_selection.preference; tab_id : int option }
type tab = { id : int; title : string; url : string; active : bool }
type selection = Requested of tab | Active of tab | None_active
let ( let* ) = Result.bind
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
type failure = Unselected of Browser_lane.selection_error | Unchosen of Browser_selection.error
  | Unobserved of string | Unavailable of string
let failure_message = function
  | Unselected error -> Browser_lane.selection_error_message error
  | Unchosen error -> Browser_selection.error_message error
  | Unobserved detail | Unavailable detail -> detail
let unobserved result = Result.map_error (fun detail -> Unobserved detail) result
let choose_browser ~verb (request : request) =
  Browser_selection.resolve ~verb ~bound:(Option.is_some request.tab_id) request.route
  |> Result.map_error (fun error -> Unchosen error)
let resolve_target ?(required_actions=[]) ~verb request =
  let* selected = Browser_selection.resolve ~required_actions ~verb ~bound:(Option.is_some request.tab_id) request.route
    |> Result.map_error (fun error -> Unchosen error) in
  let* target = Browser_lane.resolve_target ~verb selected.route
    |> Result.map_error (fun error -> Unselected error) in
  let* () = Browser_selection.require_target required_actions target
    |> Result.map_error (fun error -> Unchosen error) in
  Ok (Browser_selection.bind_target selected target, target)
let decode_answer ~lane = function
  | Browser_lane.Lane_absent -> Error (Browser_lane.lane_absent_message lane)
  | Browser_lane.Timed_out -> Error "browser lane timed out"
  | Browser_lane.Refused error | Browser_lane.Rejected_before_effect error -> Error error
  | Browser_lane.Answered json ->
    match field "ok" json, field "data" json with
    | Some (`Bool true), Some data -> Ok data
    | Some (`Bool false), _ ->
      (match field "error" json with
       | Some (`String error) -> Error error
       | _ -> Error "browser backend failed without an error message")
    | _ -> Error "malformed browser response"
let observe_answer ~lane answer =
  match answer with
  | Browser_lane.Lane_absent -> Error (Unavailable (Browser_lane.lane_absent_message lane))
  | Browser_lane.Timed_out -> Error (Unavailable "browser lane timed out; read the current page before repeating an interaction")
  | Browser_lane.Answered _ | Browser_lane.Refused _ | Browser_lane.Rejected_before_effect _ ->
    decode_answer ~lane answer |> unobserved
let decode_tab json =
  match field "id" json, field "title" json, field "url" json, field "active" json with
  | Some (`Int id), Some (`String title), Some (`String url), Some (`Bool active) ->
    Ok {id;title;url;active}
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
let tab_json tab = `Assoc ["id",`Int tab.id;"title",`String tab.title;
  "url",`String tab.url;"active",`Bool tab.active]
let source_name route = Browser_lane.Lane_name.to_wire (Browser_lane.route_lane_name route)
let select ~tab_id tabs = match tab_id with
  | Some id -> (match List.find_opt (fun tab -> tab.id = id) tabs with
      | Some tab -> Ok (Requested tab)
      | None -> Error "selected tab is closed or absent from this browser source")
  | None -> Ok (match List.find_opt (fun tab -> tab.active) tabs with
      | Some tab -> Active tab | None -> None_active)
let selection_json = function
  | Requested _ -> `String "requested" | Active _ -> `String "active" | None_active -> `String "none_active"
(* One exchange with the resolved browser: a browser that left after it was
   resolved is a selection failure, not an unreadable answer. *)
let exchange ~admission ~command =
  let target = Browser_lane.Read_admission.target admission in
  match Browser_lane.Read_admission.issue admission command ~timeout_sec:20. with
  | Error error -> Error (Unselected error)
  | Ok answer -> observe_answer ~lane:(Browser_lane.target_lane target) answer
let read request =
  let started = Mtime_clock.elapsed_ns () in
  let* selected = choose_browser ~verb:Browser_lane.Tabs_list request in
  let* admission = Browser_lane.Read_admission.acquire selected.route
    |> Result.map_error (fun error -> Unselected error) in
  let target = Browser_lane.Read_admission.target admission in
  let selected = Browser_selection.bind_target selected target in
  let lane_name = Browser_lane.Lane_name.to_wire (Browser_lane.target_lane target) in
  let issue command = exchange ~admission ~command in
  let* raw_tabs = issue Browser_lane.Read_admission.Tabs in
  let* inventory = decode_inventory raw_tabs |> unobserved in
  let tabs = inventory.tabs in
  let unavailable = match inventory.completeness with
    | Complete -> []
    | Partial unavailable -> unavailable in
  let* () = match request.tab_id with
    | None -> Ok ()
    | Some id ->
      (match List.find_opt (fun row -> field "id" row = Some (`Int id)) unavailable with
       | None -> Ok ()
       | Some row ->
         let detail = match field "error" row with
           | Some (`String detail) -> detail
           | _ -> "tab metadata could not be observed" in
         Error (Unobserved (Printf.sprintf "selected tab %d is present but unreadable: %s" id detail))) in
  (* Without a requested tab and without an active tab no page is read: the
     answer says [selection = none_active] and [page = null] instead of the
     caller receiving whichever tab the browser listed first. *)
  let* selection = select ~tab_id:request.tab_id tabs |> unobserved in
  let* page = match selection with
    | None_active -> Ok `Null
    | Requested tab | Active tab ->
      let* data = issue (Browser_lane.Read_admission.Page {tab_id=tab.id;max_chars=Some Browser_page_script.default_text_chars}) in
      (match field "url" data, field "title" data, field "text" data,
             field "chars" data, field "truncated" data with
       | Some (`String url), Some (`String title), Some (`String text),
         Some (`Int chars), Some (`Bool truncated) ->
         Ok (`Assoc ["tabId",`Int tab.id;"url",`String url;"title",`String title;
           "text",`String text;"chars",`Int chars;"truncated",`Bool truncated])
       | _ -> Error (Unobserved "browser page lacks URL/title/text/length metadata; update the browser connector")) in
  let elapsed_ms = Int64.to_float (Int64.sub (Mtime_clock.elapsed_ns ()) started) /. 1e6 in
  Ok (`Assoc (["tabs",`List (List.map tab_json tabs);"selection",selection_json selection;"page",page;
    "source",`String lane_name; "browserSelection", Browser_selection.to_json selected]
    @ Browser_lane.target_connection_fields target
    @ (match inventory.completeness with Complete -> [] | Partial unavailable ->
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

let capture request =
  let* tab_id = match request.tab_id with
    | Some id -> Ok id | None -> Error (Unobserved "tabId is required for a screenshot") in
  let started = Mtime_clock.elapsed_ns () in
  let* selected = choose_browser ~verb:(Browser_lane.Page_capture {tab_id}) request in
  let* admission = Browser_lane.Read_admission.acquire selected.route
    |> Result.map_error (fun error -> Unselected error) in
  let target = Browser_lane.Read_admission.target admission in
  let selected = Browser_selection.bind_target selected target in
  let lane_name = Browser_lane.Lane_name.to_wire (Browser_lane.target_lane target) in
  let* data = exchange ~admission ~command:(Browser_lane.Read_admission.Capture {tab_id}) in
  unobserved @@
  match field "tabId" data, field "url" data, field "title" data,
        field "mimeType" data, field "data" data with
  | Some (`Int actual), Some (`String url), Some (`String title),
    Some (`String "image/png"), Some (`String image) when actual = tab_id ->
    let* viewport = match field "viewport" data with
      | Some json -> Browser_lane.Pointer.viewport_of_json json
      | None -> Error "screenshot lacks viewport metadata; update the browser connector" in
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
        @ Browser_lane.target_connection_fields target
        @ ["tabId", `Int tab_id;
           "title", `String title; "url", `String url; "mimeType", `String "image/png";
           "data", `String image; "viewport", Browser_lane.Pointer.viewport_to_json viewport;
           "elapsed_ms", `Float elapsed_ms]))
  | _ -> Error "screenshot response does not match the requested tab or PNG contract"
