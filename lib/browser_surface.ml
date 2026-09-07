type source = Live | Automation
type request = { source : source; tab_id : int option }
type tab = { id : int; title : string; url : string; active : bool }
let ( let* ) = Result.bind
let field key = function `Assoc fields -> List.assoc_opt key fields | _ -> None
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
    let* () = if List.for_all (fun (key, _) -> List.mem key ["lane";"tabId"]) fields
      then Ok () else Error "unknown browser read argument" in
    Ok {source; tab_id}
  | _ -> Error "body must be a JSON object"
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
let source_name = function Live -> "live" | Automation -> "automation"
let read request =
  let started = Mtime_clock.elapsed_ns () in
  let lane_name = source_name request.source in
  let issue verb = Browser_lane.issue ~lane_name ~verb ~timeout_sec:20. |> decode_answer in
  let* raw_tabs = issue Browser_lane.Tabs_list in
  let* tabs = match raw_tabs with `List tabs -> decode_tabs tabs | _ -> Error "browser tabs must be a list" in
  let* selected = match request.tab_id with
    | Some id -> (match List.find_opt (fun tab -> tab.id = id) tabs with
        | Some tab -> Ok (Some tab)
        | None -> Error "selected tab is closed or absent from this browser source")
    | None ->
      Ok (match List.find_opt (fun tab -> tab.active) tabs with
          | Some tab -> Some tab | None -> List.nth_opt tabs 0) in
  let* page = match selected with
    | None -> Ok `Null
    | Some tab ->
      let* data = issue (Browser_lane.Page_read {tab_id=Some tab.id;max_chars=Some 50_000}) in
      (match field "url" data, field "title" data, field "text" data,
             field "chars" data, field "truncated" data with
       | Some (`String url), Some (`String title), Some (`String text),
         Some (`Int chars), Some (`Bool truncated) ->
         Ok (`Assoc ["tabId",`Int tab.id;"url",`String url;"title",`String title;
           "text",`String text;"chars",`Int chars;"truncated",`Bool truncated])
       | _ -> Error "browser page lacks URL/title/text/length metadata; update the browser connector") in
  let elapsed_ms = Int64.to_float (Int64.sub (Mtime_clock.elapsed_ns ()) started) /. 1e6 in
  Ok (`Assoc ["tabs",`List (List.map tab_json tabs);"page",page;
    "source",`String lane_name;
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
    | Some id -> Ok id | None -> Error "tabId is required for a screenshot" in
  let started = Mtime_clock.elapsed_ns () in
  let lane_name = source_name request.source in
  let* data = Browser_lane.issue ~lane_name ~verb:(Browser_lane.Page_capture {tab_id})
      ~timeout_sec:20. |> decode_answer in
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
      Ok (`Assoc ["source", `String lane_name; "tabId", `Int tab_id;
        "title", `String title; "url", `String url; "mimeType", `String "image/png";
        "data", `String image; "elapsed_ms", `Float elapsed_ms])
  | _ -> Error "screenshot response does not match the requested tab or PNG contract"
