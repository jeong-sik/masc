(** Browser-lane reader tools (docs/design/browser-lane.md, task-1382).

    [masc_browser_tabs] and [masc_browser_read] ask a connected browser lane
    for what is on screen. Both verbs are reads: the closed verb set in
    {!Browser_lane} classifies them, and the extension side answers from
    live state without touching it. A lane with no recent poll answers
    [Lane_absent] immediately — the operator's browser is not always on. *)

open Tool_args

let default_timeout_sec = 20.

let make_workflow_err ~tool_name ~start_time message =
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Workflow_rejection
    ~start_time
    message
;;

(* The lane names are the closed set the state module admits; anything else
   is refused here rather than queued into a lane that cannot exist. *)
let lane_of ~tool_name ~start_time args =
  match get_string args "lane" "live" with
  | "live" | "automation" as lane -> Ok lane
  | other ->
    Error
      (make_workflow_err ~tool_name ~start_time
         ("lane must be one of: live, automation (got: " ^ other ^ ")"))
;;

let answer_to_result ~tool_name ~start_time = function
  | Browser_lane.Answered (`Assoc fields) ->
    (match List.assoc_opt "ok" fields, List.assoc_opt "data" fields with
     | Some (`Bool true), Some data -> Tool_result.make_ok ~tool_name ~start_time ~data ()
     | Some (`Bool false), _ ->
       let message = match List.assoc_opt "error" fields with
         | Some (`String message) -> message
         | _ -> "browser backend failed without an error message" in
       make_workflow_err ~tool_name ~start_time message
     | _ -> make_workflow_err ~tool_name ~start_time "invalid browser backend response")
  | Browser_lane.Answered _ ->
    make_workflow_err ~tool_name ~start_time "invalid browser backend response"
  | Browser_lane.Lane_absent ->
    make_workflow_err ~tool_name ~start_time
      "no browser lane connected: the live lane needs the operator's browser \
       running with the browser-lane extension and host (connectors/browser)"
  | Browser_lane.Timed_out ->
    make_workflow_err ~tool_name ~start_time "the browser lane did not answer in time"
  | Browser_lane.Refused reason ->
    make_workflow_err ~tool_name ~start_time reason
;;

let handle_tabs ~tool_name ~start_time args : Tool_result.result =
  match lane_of ~tool_name ~start_time args with
  | Error error -> error
  | Ok lane ->
    answer_to_result ~tool_name ~start_time
      (Browser_lane.issue ~lane_name:lane ~verb:Browser_lane.Tabs_list
         ~timeout_sec:default_timeout_sec)
;;

(* Sessions and navigations are automation-lane verbs; the state module
   refuses them on the live lane too (live_lane_refused), so a caller cannot
   route them there even by naming it. *)
let handle_session ~tool_name ~start_time args : Tool_result.result =
  let action = get_string args "action" "" in
  match action with
  | "open" ->
    let headless = Some (get_bool args "headless" true) in
    answer_to_result ~tool_name ~start_time
      (Browser_lane.issue
         ~lane_name:"automation"
         ~verb:(Browser_lane.Session_open { headless })
         ~timeout_sec:60.0)
  | "close" ->
    answer_to_result ~tool_name ~start_time
      (Browser_lane.issue ~lane_name:"automation" ~verb:Browser_lane.Session_close ~timeout_sec:60.0)
  | _ ->
    make_workflow_err ~tool_name ~start_time
      "action must be one of: open, close"
;;

let handle_goto ~tool_name ~start_time args : Tool_result.result =
  let url = get_string args "url" "" in
  if not (String.length url > 7 && (String.starts_with ~prefix:"http://" url || String.starts_with ~prefix:"https://" url))
  then
    make_workflow_err ~tool_name ~start_time
      "url must be a valid http or https URL"
  else
    answer_to_result ~tool_name ~start_time
      (Browser_lane.issue
         ~lane_name:"automation"
         ~verb:(Browser_lane.Page_goto { url })
         ~timeout_sec:45.0)
;;

type read_format = Text | Image
let read_format args =
  match args with
  | `Assoc fields ->
    (match List.assoc_opt "format" fields with
     | None | Some (`String "text") -> Ok Text
     | Some (`String "image") -> Ok Image
     | _ -> Error "format must be text or image")
  | _ -> Error "browser read arguments must be an object"

let handle_read ~tool_name ~start_time args : Tool_result.result =
  match read_format args with
  | Error error -> make_workflow_err ~tool_name ~start_time error
  | Ok Image ->
    let input = match args with
      | `Assoc fields -> `Assoc (List.filter (fun (key, _) -> List.mem key ["lane"; "tabId"]) fields)
      | other -> other in
    (match Result.bind (Browser_surface.parse_capture_request input) Browser_surface.capture with
     | Ok data -> Tool_result.make_ok ~tool_name ~start_time ~data ()
     | Error error -> make_workflow_err ~tool_name ~start_time error)
  | Ok Text ->
    match lane_of ~tool_name ~start_time args with
    | Error error -> error
    | Ok lane ->
      let max_chars = max 1 (min 100_000 (get_int args "maxChars" 50_000)) in
      answer_to_result ~tool_name ~start_time
        (Browser_lane.issue ~lane_name:lane
           ~verb:(Browser_lane.Page_read { tab_id = get_int_opt args "tabId"; max_chars = Some max_chars })
           ~timeout_sec:default_timeout_sec)
;;

let handle_interact ~tool_name ~start_time args : Tool_result.result =
  match Browser_interaction.parse args with
  | Error error -> make_workflow_err ~tool_name ~start_time error
  | Ok request ->
    let lane_name = match request.source with Browser_surface.Live -> "live" | Automation -> "automation" in
    answer_to_result ~tool_name ~start_time
      (Browser_lane.issue ~lane_name
        ~verb:(Browser_lane.Page_interact {tab_id=request.tab_id;
          expected_url=request.expected_url; action=request.action})
        ~timeout_sec:default_timeout_sec)
;;
