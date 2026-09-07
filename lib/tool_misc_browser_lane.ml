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
  match args with
  | `Assoc fields ->
    (match List.assoc_opt "lane" fields with
     | None -> Ok "live"
     | Some (`String ("live" | "automation" as lane)) -> Ok lane
     | _ -> Error (make_workflow_err ~tool_name ~start_time "lane must be live or automation"))
  | _ -> Error (make_workflow_err ~tool_name ~start_time "browser arguments must be an object")
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
  | Browser_lane.Refused reason | Browser_lane.Rejected_before_effect reason ->
    make_workflow_err ~tool_name ~start_time reason
;;

let tool_request args =
  let input = match args with
    | `Assoc fields -> `Assoc (List.filter (fun (key, _) -> List.mem key ["lane"; "tabId"; "clientId"]) fields)
    | other -> other in
  Browser_surface.parse_request input
let add_client target = function
  | Browser_lane.Answered (`Assoc envelope) ->
    let data = match List.assoc_opt "data" envelope with
      | Some (`Assoc fields) -> `Assoc (("clientId", Browser_surface.client_id_json target) :: fields)
      | Some (`List tabs) -> `Assoc ["tabs", `List tabs; "clientId", Browser_surface.client_id_json target]
      | Some other -> other | None -> `Null in
    Browser_lane.Answered (`Assoc (("data", data) :: List.remove_assoc "data" envelope))
  | other -> other
(* Keep the discovery payload in both channels: Keeper's adapter retains [data]
   but its model-facing raw output uses the error message. No tab command runs
   until resolution succeeds, including when a formerly pinned client vanished. *)
let selection_error ~tool_name ~start_time request error =
  let clients = match request.Browser_surface.source with
    | Live -> Browser_lane.active_clients () |> List.map Browser_lane.client_json
    | Automation -> [] in
  let data = `Assoc [
    "error", `String error;
    "clients", `List clients;
    "retry", `String "Choose a connected browser and retry BrowserTabs with its clientId. No browser command was dispatched."] in
  Tool_result.make_err ~tool_name ~start_time
    ~class_:Tool_result.Workflow_rejection ~data (Yojson.Safe.to_string data)

let handle_tabs ~tool_name ~start_time args : Tool_result.result =
  match tool_request args with
  | Error error -> make_workflow_err ~tool_name ~start_time error
  | Ok request ->
    match Browser_surface.resolved_target request with
    | Error error -> selection_error ~tool_name ~start_time request error
    | Ok target ->
      answer_to_result ~tool_name ~start_time
        (Browser_lane.issue_for ~target ~verb:Browser_lane.Tabs_list ~timeout_sec:default_timeout_sec
         |> add_client target)
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
         ~verb:(Browser_lane.Page_goto { url; tab_id = get_int_opt args "tabId" })
         ~timeout_sec:45.0)
;;

let handle_read ?keeper_name ~tool_name ~start_time args : Tool_result.result =
  let unknown_argument = match args with
    | `Assoc fields -> List.exists (fun (key,_) -> not (List.mem key ["lane";"tabId";"maxChars";"mode";"clientId"])) fields
    | _ -> false in
  if unknown_argument then make_workflow_err ~tool_name ~start_time "unknown browser read argument"
  else
  match tool_request args with
  | Error error -> make_workflow_err ~tool_name ~start_time error
  | Ok request ->
    let max_chars = max 1 (min 100_000 (get_int args "maxChars" 50_000)) in
    match get_string args "mode" "text" with
    | "screenshot" ->
      (match keeper_name, get_int_opt args "tabId" with
       | None, _ -> make_workflow_err ~tool_name ~start_time "screenshot requires an owning Keeper"
       | _, None -> make_workflow_err ~tool_name ~start_time "screenshot requires an observed tabId"
       | Some keeper_name, Some tab_id ->
         let result = Result.bind
             (Ok {request with tab_id=Some tab_id})
             Browser_surface.capture in
         let result = Result.bind result (Browser_screenshot.persist ~keeper_name) in
         match result with
         | Ok data -> Tool_result.make_ok ~tool_name ~start_time ~data ()
         | Error detail -> make_workflow_err ~tool_name ~start_time detail)
    | mode ->
      let verb = match mode with
        | "text" -> Ok (Browser_lane.Page_read {tab_id=get_int_opt args "tabId";max_chars=Some max_chars})
        | "elements" -> Ok (Browser_lane.Page_elements {tab_id=get_int_opt args "tabId"})
        | _ -> Error "mode must be text, elements or screenshot" in
      match verb with
      | Error detail -> make_workflow_err ~tool_name ~start_time detail
      | Ok verb ->
        (match Browser_surface.resolved_target request with
         | Error error -> selection_error ~tool_name ~start_time request error
         | Ok target -> answer_to_result ~tool_name ~start_time
           (Browser_lane.issue_for ~target ~verb ~timeout_sec:default_timeout_sec |> add_client target))
;;

let handle_act_with_phase ~tool_name ~start_time args =
  let pre_error detail =
    make_workflow_err ~tool_name ~start_time detail, Tool_result.Proven_pre_effect in
  let args = match args with
    | `Assoc fields when not (List.mem_assoc "lane" fields) -> `Assoc (("lane",`String "automation") :: fields)
    | _ -> args in
  match lane_of ~tool_name ~start_time args, Browser_lane.Action.parse args with
  | Error error, _ -> error, Tool_result.Proven_pre_effect
  | _, Error detail -> pre_error detail
  | Ok lane, Ok action ->
    let answer = Browser_lane.issue ~lane_name:lane ~verb:(Browser_lane.Page_act action) ~timeout_sec:60. in
    let phase = match answer with
      | Browser_lane.Rejected_before_effect _ | Browser_lane.Lane_absent -> Tool_result.Proven_pre_effect
      | Browser_lane.Refused _ when lane = "live" -> Tool_result.Proven_pre_effect
      | Browser_lane.Refused _ | Browser_lane.Timed_out | Browser_lane.Answered _ -> Tool_result.Effect_outcome_unknown in
    answer_to_result ~tool_name ~start_time answer, phase
;;
let handle_act ~tool_name ~start_time args = fst (handle_act_with_phase ~tool_name ~start_time args)

let handle_interact ~tool_name ~start_time args : Tool_result.result =
  match Browser_interaction.parse args with
  | Error error -> make_workflow_err ~tool_name ~start_time error
  | Ok request ->
    let lane_name = match request.source with Browser_surface.Live -> "live" | Automation -> "automation" in
    (match Browser_lane.resolve_target ~lane_name ~client_id:request.client_id with
     | Error error -> make_workflow_err ~tool_name ~start_time error
     | Ok target -> answer_to_result ~tool_name ~start_time
       (Browser_lane.issue_for ~target
         ~verb:(Browser_lane.Page_interact {tab_id=request.tab_id;
           expected_url=request.expected_url; action=request.action})
         ~timeout_sec:default_timeout_sec |> add_client target))
;;
