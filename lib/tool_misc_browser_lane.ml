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
         ~verb:(Browser_lane.Page_goto { url; tab_id = get_int_opt args "tabId" })
         ~timeout_sec:45.0)
;;

let handle_read ?keeper_name ~tool_name ~start_time args : Tool_result.result =
  match lane_of ~tool_name ~start_time args with
  | Error error -> error
  | Ok lane ->
    match Browser_lane.Action.parse_frame_path args with
    | Error detail -> make_workflow_err ~tool_name ~start_time detail
    | Ok frame_path ->
    let mode = get_string args "mode" "text" in
    if frame_path <> [] || mode = "frames" || mode = "dialog" then
      if lane <> "automation" then make_workflow_err ~tool_name ~start_time "frame and dialog reads require automation"
      else (match get_int_opt args "tabId" with
        | None -> make_workflow_err ~tool_name ~start_time "contextual read requires an observed tabId"
        | Some tab_id when tab_id < 0 -> make_workflow_err ~tool_name ~start_time "tabId must be nonnegative"
        | Some tab_id ->
          let mode = match mode with
            | "text" -> Ok (`Text (get_int args "maxChars" 50_000))
            | "elements" -> Ok `Elements | "frames" -> Ok `Frames
            | "dialog" when frame_path = [] -> Ok `Dialog
            | _ -> Error "framePath supports text, elements and frames; dialogs belong to the top-level tab" in
          match mode with
          | Error detail -> make_workflow_err ~tool_name ~start_time detail
          | Ok mode -> answer_to_result ~tool_name ~start_time
              (Browser_lane.issue ~lane_name:lane
                ~verb:(Browser_lane.Page_context {tab_id;frame_path;mode}) ~timeout_sec:default_timeout_sec))
    else
    let max_chars = max 1 (min 100_000 (get_int args "maxChars" 50_000)) in
    match get_string args "mode" "text" with
    | "downloads" ->
      if lane <> "automation" then make_workflow_err ~tool_name ~start_time "downloads require automation"
      else (match get_int_opt args "tabId" with
        | Some tab_id when tab_id >= 0 -> answer_to_result ~tool_name ~start_time
            (Browser_lane.issue ~lane_name:lane ~verb:(Browser_lane.Page_downloads {tab_id}) ~timeout_sec:default_timeout_sec)
        | _ -> make_workflow_err ~tool_name ~start_time "downloads require an observed nonnegative tabId")
    | "screenshot" ->
      (match keeper_name, get_int_opt args "tabId" with
       | None, _ -> make_workflow_err ~tool_name ~start_time "screenshot requires an owning Keeper"
       | _, None -> make_workflow_err ~tool_name ~start_time "screenshot requires an observed tabId"
       | Some keeper_name, Some tab_id ->
         let result = Browser_lane.issue ~lane_name:lane
             ~verb:(Browser_lane.Page_screenshot {tab_id}) ~timeout_sec:default_timeout_sec
           |> Browser_surface.decode_answer in
         let result = Result.bind result (Browser_screenshot.persist ~keeper_name) in
         match result with
         | Ok data -> Tool_result.make_ok ~tool_name ~start_time ~data ()
         | Error detail -> make_workflow_err ~tool_name ~start_time detail)
    | mode ->
      let verb = match mode with
        | "text" -> Ok (Browser_lane.Page_read {tab_id=get_int_opt args "tabId";max_chars=Some max_chars})
        | "elements" -> Ok (Browser_lane.Page_elements {tab_id=get_int_opt args "tabId"})
        | _ -> Error "mode must be text, elements, screenshot, frames, dialog or downloads" in
      match verb with
      | Error detail -> make_workflow_err ~tool_name ~start_time detail
      | Ok verb -> answer_to_result ~tool_name ~start_time
          (Browser_lane.issue ~lane_name:lane ~verb ~timeout_sec:default_timeout_sec)
;;

let handle_act_with_phase ?upload_paths ~tool_name ~start_time args =
  let pre_error detail =
    make_workflow_err ~tool_name ~start_time detail, Tool_result.Proven_pre_effect in
  let args = match args with
    | `Assoc fields when not (List.mem_assoc "lane" fields) -> `Assoc (("lane",`String "automation") :: fields)
    | _ -> args in
  match lane_of ~tool_name ~start_time args, Browser_lane.Action.parse args with
  | Error error, _ -> error, Tool_result.Proven_pre_effect
  | _, Error detail -> pre_error detail
  | Ok _, Ok (Browser_lane.Action.On_tab {interaction=Upload _;_}) when upload_paths = None ->
    pre_error "upload requires an authoritative Keeper file context"
  | Ok lane, Ok action ->
    let action = match action, upload_paths with
      | Browser_lane.Action.On_tab ({interaction=Upload {selector;_};_} as target), Some paths ->
        Browser_lane.Action.On_tab {target with interaction=Upload {selector;paths}}
      | _ -> action in
    let answer = Browser_lane.issue ~lane_name:lane ~verb:(Browser_lane.Page_act action) ~timeout_sec:60. in
    let phase = match answer with
      | Browser_lane.Rejected_before_effect _ | Browser_lane.Lane_absent -> Tool_result.Proven_pre_effect
      | Browser_lane.Refused _ when lane = "live" -> Tool_result.Proven_pre_effect
      | Browser_lane.Refused _ | Browser_lane.Timed_out | Browser_lane.Answered _ -> Tool_result.Effect_outcome_unknown in
    answer_to_result ~tool_name ~start_time answer, phase
;;
let handle_act ~tool_name ~start_time args = fst (handle_act_with_phase ~tool_name ~start_time args)
