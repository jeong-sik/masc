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
  | Browser_lane.Answered data -> Tool_result.make_ok ~tool_name ~start_time ~data ()
  | Browser_lane.Lane_absent ->
    make_workflow_err ~tool_name ~start_time
      "no browser lane connected: the live lane needs the operator's browser \
       running with the browser-lane extension and host (connectors/browser)"
  | Browser_lane.Timed_out ->
    make_workflow_err ~tool_name ~start_time "the browser lane did not answer in time"
;;

let handle_tabs ~tool_name ~start_time args : Tool_result.result =
  match lane_of ~tool_name ~start_time args with
  | Error error -> error
  | Ok lane ->
    answer_to_result ~tool_name ~start_time
      (Browser_lane.issue ~lane_name:lane ~verb:Browser_lane.Tabs_list
         ~timeout_sec:default_timeout_sec)
;;

let handle_read ~tool_name ~start_time args : Tool_result.result =
  match lane_of ~tool_name ~start_time args with
  | Error error -> error
  | Ok lane ->
    let max_chars = max 1 (min 100_000 (get_int args "maxChars" 50_000)) in
    answer_to_result ~tool_name ~start_time
      (Browser_lane.issue
         ~lane_name:lane
         ~verb:(Browser_lane.Page_read { tab_id = get_int_opt args "tabId"; max_chars = Some max_chars })
         ~timeout_sec:default_timeout_sec)
;;
