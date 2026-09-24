(** Browser-lane reader tools (docs/design/browser-lane.md, task-1382).

    [masc_browser_tabs] and [masc_browser_read] ask a connected browser lane
    for what is on screen. Both verbs are reads: the closed verb set in
    {!Browser_lane} classifies them, and the extension side answers from
    live state without touching it. A lane with no recent poll answers
    [Lane_absent] immediately — the operator's browser is not always on. *)

open Tool_args

let default_timeout_sec = 20.

(* These failures come from caller-input parsing, before browser dispatch.
   Waiting for a different page cannot repair the same malformed arguments. *)
let make_input_err ~tool_name ~start_time detail =
  Tool_result.make_err ~tool_name ~start_time
    ~class_:Tool_result.Policy_rejection
    ~effect_disposition:Tool_result.Proven_pre_effect
    ~data:(Tool_error.to_json (Tool_error.Invalid_input {detail}))
    ("Invalid browser arguments: " ^ detail
     ^ ". Correct the arguments using the tool schema and exact observed identities; no browser command was dispatched.")
;;

let make_workflow_err ~tool_name ~start_time message =
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Workflow_rejection
    ~start_time
    message
;;

(* The lane names are the closed set the state module admits; anything else
   is refused here rather than queued into a lane that cannot exist. *)
(* [default] is the lane a missing [lane] means, the one each tool declares. *)
let route_of ~default ~tool_name ~start_time args =
  match args with
  | `Assoc fields ->
    let lane = match List.assoc_opt "lane" fields with
      | None -> Some default
      | Some (`String raw) -> Browser_lane.Lane_name.of_wire raw
      | Some _ -> None in
    (match lane with
     | Some Browser_lane.Lane_name.Live -> Ok (Browser_lane.Live_route None)
     | Some Browser_lane.Lane_name.Automation -> Ok Browser_lane.Automation_route
     | Some Browser_lane.Lane_name.Stagehand -> Ok Browser_lane.Stagehand_route
     | None ->
       Error (make_input_err ~tool_name ~start_time ("lane must be " ^ Browser_lane.Lane_name.expected)))
  | _ -> Error (make_input_err ~tool_name ~start_time "browser arguments must be an object")
;;

(* What an absent backend means on each lane, and where the operator looks. *)
let lane_absent_message = function
  | Browser_lane.Lane_name.Live ->
    "no browser lane connected: the live lane needs the operator's browser \
     running with the browser-lane extension and host (connectors/browser)"
  | Browser_lane.Lane_name.Automation ->
    "the automation lane has no WebDriver: configure browser.geckodriver, or \
     read the server log for why it did not start"
  | Browser_lane.Lane_name.Stagehand ->
    "the stagehand lane has no browser: configure [browser.stagehand], or \
     read the server log for why it did not start"
;;

let answer_to_result ~lane ~tool_name ~start_time = function
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
  | Browser_lane.Lane_absent -> make_workflow_err ~tool_name ~start_time (lane_absent_message lane)
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
(* What a Keeper is told when no connected browser can take its command. The
   Keeper cannot start a browser or move a host, so the text names the cause
   the doctor reports for the same configuration and says the operator acts. *)
let no_client_retry host =
  let cause = match Browser_lane_launcher.verdict host with
    | Browser_lane_launcher.Absent | Browser_lane_launcher.Misconfigured
    | Browser_lane_launcher.Connected | Browser_lane_launcher.Unverified ->
      Browser_lane_launcher.message host
    | Browser_lane_launcher.Aligned ->
      Browser_lane_launcher.message host ^ " The operator opens that browser profile with the \
       extension loaded, or reloads the extension so a new host starts." in
  cause ^ " Only the operator can change this; retrying before they do returns the same \
           answer. No browser command was dispatched."

(* Keep the discovery payload in both channels: Keeper's adapter retains [data]
   but its model-facing raw output uses the error message. No tab command runs
   until resolution succeeds, including when a formerly pinned client vanished,
   and a browser that leaves after resolution is answered the same way. *)
let selection_error ~base_path ~tool_name ~start_time error =
  let clients = Browser_lane.active_clients () |> List.map Browser_lane.client_json in
  let rejection fields =
    let data = `Assoc (("error", `String (Browser_lane.selection_error_code error))
                       :: ("clients", `List clients) :: fields) in
    Tool_result.make_err ~tool_name ~start_time
      ~class_:Tool_result.Workflow_rejection ~data (Yojson.Safe.to_string data) in
  let observe () =
    Browser_lane_launcher.observe ~base_path ~server:(Browser_lane_launcher.current_server ()) in
  match error with
  | Browser_lane.No_live_client ->
    let host = observe () in
    rejection ["host", Browser_lane_launcher.to_json host; "retry", `String (no_client_retry host)]
  | Browser_lane.Selected_client_disconnected client_id ->
    let host = observe () in
    let retry = match clients with
      | _ :: _ -> "That browser is no longer connected. Choose a browser from clients and retry \
                   with its clientId. No browser command was dispatched."
      | [] -> "That browser is no longer connected and none is. " ^ no_client_retry host in
    rejection ["clientId", `String (Browser_lane.client_id_to_string client_id);
               "host", Browser_lane_launcher.to_json host; "retry", `String retry]
  | Browser_lane.Ambiguous_clients _ ->
    rejection ["retry", `String "Choose a connected browser and retry with its clientId. No \
                                 browser command was dispatched."]

let read_failure ~base_path ~tool_name ~start_time = function
  | Browser_surface.Unselected error -> selection_error ~base_path ~tool_name ~start_time error
  | Browser_surface.Unobserved detail -> make_workflow_err ~tool_name ~start_time detail

let handle_tabs ~base_path ~tool_name ~start_time args : Tool_result.result =
  match tool_request args with
  | Error error -> make_input_err ~tool_name ~start_time error
  | Ok request ->
    match Browser_lane.resolve_target request.route with
    | Error error -> selection_error ~base_path ~tool_name ~start_time error
    | Ok target ->
      match Browser_lane.issue_for ~target ~verb:Browser_lane.Tabs_list ~timeout_sec:default_timeout_sec with
      | Error error -> selection_error ~base_path ~tool_name ~start_time error
      | Ok answer ->
        answer_to_result ~lane:(Browser_lane.target_lane target) ~tool_name ~start_time (add_client target answer)
;;

(* Sessions and navigations belong to the lanes the server owns; the live
   browser belongs to the operator, and its lane refuses them too
   (verb_allowed_on_live). A missing lane is automation, as both tools
   declare. *)
let server_lanes = Browser_lane.Lane_name.[ Automation; Stagehand ]
let server_lanes_expected = String.concat " or " (List.map Browser_lane.Lane_name.to_wire server_lanes)

let issue_on_server_lane ~tool_name ~start_time args ~verb ~timeout_sec =
  let lane = match args with
    | `Assoc fields ->
      (match List.assoc_opt "lane" fields with
       | None -> Ok Browser_lane.Lane_name.Automation
       | Some (`String raw) ->
         Option.to_result ~none:("lane must be " ^ server_lanes_expected) (Browser_lane.Lane_name.of_wire raw)
       | Some _ -> Error ("lane must be " ^ server_lanes_expected))
    | _ -> Error "browser arguments must be an object" in
  match lane with
  | Error detail -> make_input_err ~tool_name ~start_time detail
  | Ok (Browser_lane.Lane_name.Automation as lane) ->
    answer_to_result ~lane ~tool_name ~start_time (Browser_lane.issue_automation ~verb ~timeout_sec)
  | Ok (Browser_lane.Lane_name.Stagehand as lane) ->
    answer_to_result ~lane ~tool_name ~start_time (Browser_lane.issue_stagehand ~verb ~timeout_sec:(Some timeout_sec))
  | Ok Browser_lane.Lane_name.Live ->
    make_input_err ~tool_name ~start_time
      ("lane must be " ^ server_lanes_expected ^ ": the live browser belongs to the operator")
;;

let handle_session ~tool_name ~start_time args : Tool_result.result =
  let action = get_string args "action" "" in
  match action with
  | "open" ->
    let headless = Some (get_bool args "headless" true) in
    issue_on_server_lane ~tool_name ~start_time args ~verb:(Browser_lane.Session_open { headless }) ~timeout_sec:60.0
  | "close" -> issue_on_server_lane ~tool_name ~start_time args ~verb:Browser_lane.Session_close ~timeout_sec:60.0
  | "status" ->
    (* Reads the backend's record rather than the browser, so the short timeout
       is the lane round trip, not a page load. *)
    issue_on_server_lane ~tool_name ~start_time args ~verb:Browser_lane.Session_status ~timeout_sec:10.0
  | _ ->
    make_input_err ~tool_name ~start_time
      "action must be one of: open, close, status"
;;

let handle_goto ~tool_name ~start_time args : Tool_result.result =
  let url = get_string args "url" "" in
  if not (String.length url > 7 && (String.starts_with ~prefix:"http://" url || String.starts_with ~prefix:"https://" url))
  then
    make_input_err ~tool_name ~start_time
      "url must be a valid http or https URL"
  else
    issue_on_server_lane ~tool_name ~start_time args
      ~verb:(Browser_lane.Page_goto { url; tab_id = get_int_opt args "tabId" }) ~timeout_sec:45.0
;;

let handle_read ?keeper_name ~base_path ~tool_name ~start_time args : Tool_result.result =
  let unknown_argument = match args with
    | `Assoc fields -> List.exists (fun (key,_) -> not (List.mem key ["lane";"tabId";"maxChars";"mode";"framePath";"clientId";"scope";"expectedUrl";"navigationSource"])) fields
    | _ -> false in
  if unknown_argument then make_input_err ~tool_name ~start_time "unknown browser read argument"
  else
  match tool_request args with
  | Error error -> make_input_err ~tool_name ~start_time error
  | Ok request ->
    let automation = match request.route with
      | Browser_lane.Automation_route -> true
      | Browser_lane.Live_route _ | Browser_lane.Stagehand_route -> false in
    match Browser_lane.Action.parse_frame_path args with
    | Error detail -> make_input_err ~tool_name ~start_time detail
    | Ok frame_path ->
    let mode = get_string args "mode" "text" in
    let scope_present = match args with `Assoc fields -> List.mem_assoc "scope" fields | _ -> false in
    let destination_guard_present = match args with `Assoc fields -> (List.mem_assoc "expectedUrl" fields || List.mem_assoc "navigationSource" fields) | _ -> false in
    if destination_guard_present && (frame_path <> [] || not (List.mem mode ["scene";"regions"])) then
      make_input_err ~tool_name ~start_time "expectedUrl and navigationSource support top-document scene or regions only"
    else if scope_present && (frame_path <> [] || not (List.mem mode ["scene";"regions"])) then
      make_input_err ~tool_name ~start_time "scope supports top-document scene or regions only"
    else if frame_path <> [] || mode = "frames" || mode = "dialog" then
      if not automation then make_input_err ~tool_name ~start_time "frame and dialog reads require automation"
      else (match get_int_opt args "tabId" with
        | None -> make_input_err ~tool_name ~start_time "contextual read requires an observed tabId"
        | Some tab_id when tab_id < 0 -> make_input_err ~tool_name ~start_time "tabId must be nonnegative"
        | Some tab_id ->
          let mode = match mode with
            | "text" -> Ok (`Text (get_int args "maxChars" 50_000))
            | "elements" -> Ok `Elements | "frames" -> Ok `Frames
            | "dialog" when frame_path = [] -> Ok `Dialog
            | _ -> Error "framePath supports text, elements and frames; dialogs belong to the top-level tab" in
          match mode with
          | Error detail -> make_input_err ~tool_name ~start_time detail
          | Ok mode -> answer_to_result ~lane:Browser_lane.Lane_name.Automation ~tool_name ~start_time
              (Browser_lane.issue_automation
                ~verb:(Browser_lane.Page_context {tab_id;frame_path;mode}) ~timeout_sec:default_timeout_sec))
    else
    let max_chars = max 1 (min 100_000 (get_int args "maxChars" 50_000)) in
    match get_string args "mode" "text" with
    | ("scene" | "regions") as mode ->
      (match get_int_opt args "tabId" with
       | Some tab_id when tab_id >= 0 ->
           (let scope = match args with
              | `Assoc fields -> (match List.assoc_opt "scope" fields with
                  | None -> Ok None | Some json -> Result.map Option.some (Browser_scene.scope_of_json json))
              | _ -> Ok None in
            let expected_url = match args with
              | `Assoc fields -> (match List.assoc_opt "expectedUrl" fields with
                  | None -> Ok None
                  | Some (`String value) when String.trim value <> "" -> Ok (Some value)
                  | Some _ -> Error "expectedUrl must be a nonempty string")
              | _ -> Error "browser arguments must be an object" in
            let navigation_source = match args with
              | `Assoc fields -> (match List.assoc_opt "navigationSource" fields with
                  | None -> Ok None
                  | Some value -> Result.map Option.some (Browser_scene.navigation_source_of_json value))
              | _ -> Error "browser arguments must be an object" in
            let parsed = Result.bind navigation_source (fun navigation_source ->
              Result.bind expected_url (fun expected_url ->
                Result.map (fun scope -> navigation_source, expected_url, scope) scope)) in
            match parsed with
            | Error detail -> make_input_err ~tool_name ~start_time detail
            | Ok (navigation_source, expected_url, scope) ->
              match Browser_scene.read ?navigation_source ?expected_url
                ~view:(if mode = "regions" then Browser_lane.Regions else Browser_lane.Content)
                ?scope {request with tab_id=Some tab_id} ~max_chars with
              | Ok data -> Tool_result.make_ok ~tool_name ~start_time ~data ()
              | Error failure -> read_failure ~base_path ~tool_name ~start_time failure)
       | _ -> make_input_err ~tool_name ~start_time "scene requires an observed tabId")
    | "downloads" ->
      if not automation then make_input_err ~tool_name ~start_time "downloads require automation"
      else (match get_int_opt args "tabId" with
        | Some tab_id when tab_id >= 0 -> answer_to_result ~lane:Browser_lane.Lane_name.Automation ~tool_name ~start_time
            (Browser_lane.issue_automation ~verb:(Browser_lane.Page_downloads {tab_id}) ~timeout_sec:default_timeout_sec)
        | _ -> make_input_err ~tool_name ~start_time "downloads require an observed nonnegative tabId")
    | "screenshot" ->
      (match keeper_name, get_int_opt args "tabId" with
       | None, _ -> make_workflow_err ~tool_name ~start_time "screenshot requires an owning Keeper"
       | _, None -> make_input_err ~tool_name ~start_time "screenshot requires an observed tabId"
       | Some keeper_name, Some tab_id ->
         match Browser_surface.capture {request with tab_id=Some tab_id} with
         | Error failure -> read_failure ~base_path ~tool_name ~start_time failure
         | Ok data ->
         match Browser_screenshot.persist ~keeper_name data with
         | Ok data -> Tool_result.make_ok ~tool_name ~start_time ~data ()
         | Error detail -> make_workflow_err ~tool_name ~start_time detail)
    | mode ->
      let verb = match mode with
        | "text" -> Ok (Browser_lane.Page_read {tab_id=get_int_opt args "tabId";max_chars=Some max_chars})
        | "elements" -> Ok (Browser_lane.Page_elements {tab_id=get_int_opt args "tabId"})
        | _ -> Error "mode must be text, elements, scene, regions, screenshot, frames, dialog or downloads" in
      match verb with
      | Error detail -> make_input_err ~tool_name ~start_time detail
      | Ok verb ->
        (match Browser_lane.resolve_target request.route with
         | Error error -> selection_error ~base_path ~tool_name ~start_time error
         | Ok target ->
           match Browser_lane.issue_for ~target ~verb ~timeout_sec:default_timeout_sec with
           | Error error -> selection_error ~base_path ~tool_name ~start_time error
           | Ok answer ->
             answer_to_result ~lane:(Browser_lane.target_lane target) ~tool_name ~start_time (add_client target answer))
;;

(* Retention requires an owner that will commit the observation receipt. *)
let retain_read_result ~base_path ~tool_name ~start_time args result =
  let retained = match args with
    | `Assoc fields ->
      (match List.assoc_opt "mode" fields with
       | Some (`String "scene") -> Browser_observation.retain
           ~base_path ~view:Browser_lane.Content result
       | Some (`String "regions") -> Browser_observation.retain
           ~base_path ~view:Browser_lane.Regions result
       | _ -> Ok result)
    | _ -> Ok result in
  match retained with
  | Ok result -> result
  | Error detail ->
    Tool_result.make_err ~tool_name ~start_time
      ~class_:Tool_result.Runtime_failure
      ~effect_disposition:Tool_result.Proven_pre_effect
      ~data:(Tool_result.data result)
      ("Browser observation received but could not be retained: " ^ detail
       ^ "; retry only the read, not preceding navigation or interaction.")
;;

let handle_read_with_retention ~base_path ?keeper_name ~tool_name ~start_time args =
  handle_read ?keeper_name ~base_path ~tool_name ~start_time args
  |> retain_read_result ~base_path ~tool_name ~start_time args
;;

let handle_act_with_phase ?upload_paths ~base_path ~tool_name ~start_time args =
  let pre_error detail =
    make_workflow_err ~tool_name ~start_time detail, Tool_result.Proven_pre_effect in
  match route_of ~default:Browser_lane.Lane_name.Automation ~tool_name ~start_time args, Browser_lane.Action.parse args with
  | Error error, _ -> error, Tool_result.Proven_pre_effect
  | _, Error detail -> make_input_err ~tool_name ~start_time detail, Tool_result.Proven_pre_effect
  | Ok _, Ok (Browser_lane.Action.On_tab {interaction=Upload _;_}) when upload_paths = None ->
    pre_error "upload requires an authoritative Keeper file context"
  | Ok route, Ok action ->
    let action = match action, upload_paths with
      | Browser_lane.Action.On_tab ({interaction=Upload {selector;_};_} as target), Some paths ->
        Browser_lane.Action.On_tab {target with interaction=Upload {selector;paths}}
      | _ -> action in
    let issued = Result.bind (Browser_lane.resolve_target route) (fun target ->
      Browser_lane.issue_for ~target ~verb:(Browser_lane.Page_act action) ~timeout_sec:60.) in
    match issued with
    | Error error ->
      selection_error ~base_path ~tool_name ~start_time error, Tool_result.Proven_pre_effect
    | Ok answer ->
      let phase = match answer, route with
        | (Browser_lane.Rejected_before_effect _ | Browser_lane.Lane_absent), _ -> Tool_result.Proven_pre_effect
        | Browser_lane.Refused _, Browser_lane.Live_route _ -> Tool_result.Proven_pre_effect
        | Browser_lane.Refused _, (Browser_lane.Automation_route | Browser_lane.Stagehand_route)
        | (Browser_lane.Timed_out | Browser_lane.Answered _), _ -> Tool_result.Effect_outcome_unknown in
      answer_to_result ~lane:(Browser_lane.route_lane_name route) ~tool_name ~start_time answer, phase
;;
let handle_act ~base_path ~tool_name ~start_time args =
  fst (handle_act_with_phase ~base_path ~tool_name ~start_time args)

let handle_interact_with_phase ~base_path ~tool_name ~start_time args =
  match Browser_interaction.parse args with
  | Error error -> make_input_err ~tool_name ~start_time error, Tool_result.Proven_pre_effect
  | Ok request ->
    let issued = Result.bind (Browser_lane.resolve_target request.route) (fun target ->
      Browser_lane.issue_for ~target
        ~verb:(Browser_lane.Page_interact {tab_id=request.tab_id;
          expected_url=request.expected_url; action=request.action})
        ~timeout_sec:default_timeout_sec
      |> Result.map (fun answer -> target, answer)) in
    (match issued with
     | Error error ->
       selection_error ~base_path ~tool_name ~start_time error,
       Tool_result.Proven_pre_effect
     | Ok (target, answer) ->
       let phase = match answer with
         | Browser_lane.Rejected_before_effect _ | Browser_lane.Lane_absent -> Tool_result.Proven_pre_effect
         | Browser_lane.Answered (`Assoc fields) when
             List.assoc_opt "ok" fields = Some (`Bool false)
             && List.assoc_opt "effectPhase" fields = Some (`String "not_started") -> Tool_result.Proven_pre_effect
         | Browser_lane.Answered _ | Browser_lane.Refused _ | Browser_lane.Timed_out -> Tool_result.Effect_outcome_unknown in
       answer_to_result ~lane:(Browser_lane.target_lane target) ~tool_name ~start_time (add_client target answer), phase)
;;
let handle_interact ~base_path ~tool_name ~start_time args =
  fst (handle_interact_with_phase ~base_path ~tool_name ~start_time args)

let instruct_arguments = [ "action"; "instruction"; "tabId"; "schema" ]

let instruct_verb fields =
  let ( let* ) = Result.bind in
  let* instruction =
    match List.assoc_opt "instruction" fields with
    | None -> Ok None
    | Some (`String text) when String.trim text <> "" -> Ok (Some text)
    | Some _ -> Error "instruction must be a nonempty string"
  in
  let* tab_id =
    match List.assoc_opt "tabId" fields with
    | Some (`Int id) when id >= 0 -> Ok id
    | Some _ | None -> Error "tabId must be an observed BrowserTabs id on lane stagehand"
  in
  let* schema =
    match List.assoc_opt "schema" fields with
    | None -> Ok None
    | Some (`String text) ->
      (match Yojson.Safe.from_string text with
       | `Assoc _ as schema -> Ok (Some schema)
       | _ -> Error "schema must be a JSON object"
       | exception Yojson.Json_error detail -> Error ("schema is not JSON: " ^ detail))
    | Some _ -> Error "schema must be JSON Schema text"
  in
  match List.assoc_opt "action" fields, instruction, schema with
  | Some (`String "act"), Some instruction, None -> Ok (Browser_lane.Page_instruct { tab_id; instruction })
  | Some (`String "observe"), instruction, None -> Ok (Browser_lane.Page_locate { tab_id; instruction })
  | Some (`String "extract"), Some instruction, schema -> Ok (Browser_lane.Page_extract { tab_id; instruction; schema })
  | Some (`String ("act" | "extract")), None, _ -> Error "act and extract need an instruction"
  | Some (`String ("act" | "observe")), _, Some _ -> Error "schema is for extract only"
  | (Some _ | None), _, _ -> Error "action must be one of: act, observe, extract"
;;

(* The Stagehand lane only: the sentence verbs are refused everywhere else. *)
let handle_instruct_with_phase ~tool_name ~start_time args =
  let refused_as_input detail = make_input_err ~tool_name ~start_time detail, Tool_result.Proven_pre_effect in
  match args with
  | `Assoc fields when List.for_all (fun (key, _) -> List.mem key instruct_arguments) fields ->
    (match instruct_verb fields with
     | Error detail -> refused_as_input detail
     | Ok verb ->
       (* The exact-output lane may try several slots for each model call,
          and extract may need two calls before page work completes. There
          is no declared upper bound for that sequence, so a separate tool
          deadline could abandon an in-flight page action. The caller may
          still cancel; the backend propagates that cancellation. *)
       let answer = Browser_lane.issue_stagehand ~verb ~timeout_sec:None in
       (* observe and extract read the page; a failed act may have acted. *)
       let phase =
         match answer, Browser_lane.verb_is_read verb with
         | (Browser_lane.Rejected_before_effect _ | Browser_lane.Lane_absent), _ -> Tool_result.Proven_pre_effect
         | (Browser_lane.Refused _ | Browser_lane.Timed_out | Browser_lane.Answered _), true -> Tool_result.Proven_pre_effect
         | (Browser_lane.Refused _ | Browser_lane.Timed_out | Browser_lane.Answered _), false ->
           Tool_result.Effect_outcome_unknown
       in
       answer_to_result ~lane:Browser_lane.Lane_name.Stagehand ~tool_name ~start_time answer, phase)
  | `Assoc _ -> refused_as_input "unknown browser instruct argument"
  | _ -> refused_as_input "browser arguments must be an object"
;;

let handle_instruct ~tool_name ~start_time args = fst (handle_instruct_with_phase ~tool_name ~start_time args)
