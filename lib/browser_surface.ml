type source = Live | Automation
type request = { route : Browser_lane.route; tab_id : int option }
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
    let* source = match List.assoc_opt "lane" fields with
      | None | Some (`String "live") -> Ok Live
      | Some (`String "automation") -> Ok Automation
      | _ -> Error "lane must be live or automation" in
    let* tab_id = match List.assoc_opt "tabId" fields with
      | None -> Ok None
      | Some (`Int id) when id >= 0 -> Ok (Some id)
      | _ -> Error "tabId must be a nonnegative integer" in
    let* client_id = parse_client_id (`Assoc fields) in
    let* route = match source, client_id with
      | Live, selected -> Ok (Browser_lane.Live_route selected)
      | Automation, None -> Ok Browser_lane.Automation_route
      | Automation, Some _ -> Error "client_id_requires_live" in
    let* () = if List.for_all (fun (key, _) -> List.mem key ["lane";"tabId";"clientId"]) fields
      then Ok () else Error "unknown browser read argument" in
    Ok {route; tab_id}
  | _ -> Error "body must be a JSON object"
type failure = Unselected of Browser_lane.selection_error | Unobserved of string
let failure_message = function
  | Unselected error -> Browser_lane.selection_error_code error
  | Unobserved detail -> detail
let unobserved result = Result.map_error (fun detail -> Unobserved detail) result
let decode_answer = function
  | Browser_lane.Lane_absent -> Error "browser lane is disconnected"
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
let decode_tab json =
  match field "id" json, field "title" json, field "url" json, field "active" json with
  | Some (`Int id), Some (`String title), Some (`String url), Some (`Bool active) ->
    Ok {id;title;url;active}
  | _ -> Error "malformed browser tab"
let rec decode_tabs = function
  | [] -> Ok []
  | json :: rest -> let* tab = decode_tab json in let* tabs = decode_tabs rest in Ok (tab :: tabs)
let tab_json tab = `Assoc ["id",`Int tab.id;"title",`String tab.title;
  "url",`String tab.url;"active",`Bool tab.active]
let source_name = function
  | Browser_lane.Live_route _ -> "live"
  | Browser_lane.Automation_route -> "automation"
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
let exchange ~target ~verb =
  match Browser_lane.issue_for ~target ~verb ~timeout_sec:20. with
  | Error error -> Error (Unselected error)
  | Ok answer -> decode_answer answer |> unobserved
let client_id_json target = match Browser_lane.target_client_id target with
  | None -> `Null | Some id -> `String (Browser_lane.client_id_to_string id)
let read request =
  let started = Mtime_clock.elapsed_ns () in
  let lane_name = source_name request.route in
  let* target = Browser_lane.resolve_target request.route
    |> Result.map_error (fun error -> Unselected error) in
  let issue verb = exchange ~target ~verb in
  let* raw_tabs = issue Browser_lane.Tabs_list in
  let* tabs = unobserved (match raw_tabs with
    | `List tabs -> decode_tabs tabs | _ -> Error "browser tabs must be a list") in
  (* Without a requested tab and without an active tab no page is read: the
     answer says [selection = none_active] and [page = null] instead of the
     caller receiving whichever tab the browser listed first. *)
  let* selection = select ~tab_id:request.tab_id tabs |> unobserved in
  let* page = match selection with
    | None_active -> Ok `Null
    | Requested tab | Active tab ->
      let* data = issue (Browser_lane.Page_read {tab_id=Some tab.id;max_chars=Some 50_000}) in
      (match field "url" data, field "title" data, field "text" data,
             field "chars" data, field "truncated" data with
       | Some (`String url), Some (`String title), Some (`String text),
         Some (`Int chars), Some (`Bool truncated) ->
         Ok (`Assoc ["tabId",`Int tab.id;"url",`String url;"title",`String title;
           "text",`String text;"chars",`Int chars;"truncated",`Bool truncated])
       | _ -> Error (Unobserved "browser page lacks URL/title/text/length metadata; update the browser connector")) in
  let elapsed_ms = Int64.to_float (Int64.sub (Mtime_clock.elapsed_ns ()) started) /. 1e6 in
  Ok (`Assoc ["tabs",`List (List.map tab_json tabs);"selection",selection_json selection;"page",page;
    "source",`String lane_name; "clientId", client_id_json target;
    "elapsed_ms",`Float elapsed_ms])

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
  let lane_name = source_name request.route in
  let* target = Browser_lane.resolve_target request.route
    |> Result.map_error (fun error -> Unselected error) in
  let* data = exchange ~target ~verb:(Browser_lane.Page_capture {tab_id}) in
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
      Ok (`Assoc ["source", `String lane_name; "clientId", client_id_json target; "tabId", `Int tab_id;
        "title", `String title; "url", `String url; "mimeType", `String "image/png";
        "data", `String image; "viewport", Browser_lane.Pointer.viewport_to_json viewport;
        "elapsed_ms", `Float elapsed_ms])
  | _ -> Error "screenshot response does not match the requested tab or PNG contract"
