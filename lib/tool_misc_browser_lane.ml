(** Browser-lane reader tools (docs/design/browser-lane.md, task-1382).

    [masc_browser_tabs] and [masc_browser_read] ask a connected browser lane
    for what is on screen. Both verbs are reads: the closed verb set in
    {!Browser_lane} classifies them, and the extension side answers from
    live state without touching it. A lane with no recent poll answers
    [Lane_absent] immediately — the operator's browser is not always on. *)

open Tool_args

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

(* Decode the host's effect receipt at the wire boundary. A created tab is
   a confirmed effect even when navigation or its page summary failed. *)
let backend_failure_phase fields =
  match List.assoc_opt "effectPhase" fields with
  | Some (`String "not_started") -> Tool_result.Proven_pre_effect
  | Some (`String "partial") -> Tool_result.Proven_post_effect
  | Some _ | None -> Tool_result.Effect_outcome_unknown

let answer_to_result ~lane ~tool_name ~start_time = function
  | Browser_lane.Answered (`Assoc fields) ->
    (match List.assoc_opt "ok" fields, List.assoc_opt "data" fields with
     | Some (`Bool true), Some data -> Tool_result.make_ok ~tool_name ~start_time ~data ()
     | Some (`Bool false), _ ->
       let message = match List.assoc_opt "error" fields with
         | Some (`String message) -> message
         | _ -> "browser backend failed without an error message" in
       let effect_disposition = backend_failure_phase fields in
       let data = List.assoc_opt "data" fields in
       (* Keeper raw output is the failure message. Carry the recovery receipt
          there too, so its exact connection and tab IDs reach the model. *)
       let message = match effect_disposition,data with
         | Tool_result.Proven_post_effect,Some receipt ->
           Yojson.Safe.to_string (`Assoc ["error",`String message;"data",receipt])
         | (Tool_result.Proven_pre_effect | Tool_result.Effect_outcome_unknown), (Some _ | None)
         | Tool_result.Proven_post_effect,None -> message in
       Tool_result.make_err ~tool_name ~start_time ~class_:Tool_result.Workflow_rejection
         ?data ~effect_disposition message
     | _ -> Tool_result.make_err ~tool_name ~start_time ~class_:Tool_result.Runtime_failure
         "invalid browser backend response")
  | Browser_lane.Answered _ ->
    Tool_result.make_err ~tool_name ~start_time ~class_:Tool_result.Runtime_failure
      "invalid browser backend response"
  | Browser_lane.Lane_absent ->
    Tool_result.make_err ~tool_name ~start_time ~class_:Tool_result.Dependency_unavailable
      ~effect_disposition:Tool_result.Proven_pre_effect (Browser_lane.lane_absent_message lane)
  | Browser_lane.Timed_out ->
    Tool_result.make_err ~tool_name ~start_time ~class_:Tool_result.Dependency_unavailable
      "the browser lane did not answer in time; the dispatched outcome is unknown. Read the current page before repeating an interaction."
  | Browser_lane.Rejected_before_effect reason ->
    Tool_result.make_err ~tool_name ~start_time ~class_:Tool_result.Workflow_rejection
      ~effect_disposition:Tool_result.Proven_pre_effect reason
  | Browser_lane.Refused reason -> make_workflow_err ~tool_name ~start_time reason
;;

let tool_request args =
  let input = match args with
    | `Assoc fields -> `Assoc (List.filter (fun (key, _) -> List.mem key ["lane"; "tabId"; "clientId"]) fields)
    | other -> other in
  Browser_surface.parse_request input
let add_client ?selection target = function
  | Browser_lane.Answered (`Assoc envelope) ->
    let binding = ["lane", `String (Browser_lane.Lane_name.to_wire (Browser_lane.target_lane target))]
      @ (match selection with None -> [] | Some selected ->
          ["browserSelection", Browser_selection.to_json selected]) in
    let data = match List.assoc_opt "data" envelope with
      | Some (`Assoc fields) -> `Assoc (binding @ Browser_lane.with_connection_fields target
          (List.filter (fun (key,_) -> not (List.mem key ["lane";"browserSelection"])) fields))
      | Some (`List tabs) -> `Assoc (binding @ Browser_lane.target_connection_fields target @ ["tabs", `List tabs])
      | Some other -> other | None -> `Null in
    Browser_lane.Answered (`Assoc (("data", data) :: List.remove_assoc "data" envelope))
  | ( Browser_lane.Answered _ | Browser_lane.Timed_out
    | Browser_lane.Rejected_before_effect _ | Browser_lane.Lane_absent
    | Browser_lane.Refused _ ) as other -> other
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
(* What the server's start of the Keeper's BiDi connection did for this
   request (RFC-browser-keeper-firefox §3.5): the connection it shows, with
   a retry that starts from that connection's own tabs, or why it shows
   none, with a retry that says what retrying does. A start nobody asks for
   here changes nothing in the answer. *)
let bidi_start_fields =
  let module Starter = Browser_keeper_firefox_starter in
  let from_its_tabs =
    " Its tab IDs are its own: list its tabs and observe the page again with its clientId, then \
     retry. No browser command was dispatched." in
  function
  | None | Some Starter.Not_asked_for -> None, []
  | Some (Starter.Attached { client; started }) ->
    let what, done_ = match started with
      | Starter.Firefox_and_host ->
        "firefox_and_host", "MASC started this workspace's Keeper Firefox and its BiDi host."
      | Starter.Host_only ->
        "host_only", "MASC started the BiDi host for this workspace's Keeper Firefox."
      | Starter.Nothing -> "nothing", "The Keeper's BiDi connection is listed now." in
    let connection = match Browser_lane.client_json client with
      | `Assoc fields -> `Assoc (fields @ [ "started", `String what ])
      | other -> other in
    Some (done_ ^ " The connection in bidiConnection serves this work." ^ from_its_tabs),
    [ "bidiConnection", connection ]
  | Some (Starter.Not_attached reason) ->
    let kind, why, retry = match reason with
      | Starter.Operator_needed why -> "operator_needed", why, None
      | Starter.Start_failed why ->
        "start_failed", why,
        Some "MASC tried to start the Keeper's BiDi connection and could not, as bidiStartFailed \
              says. A retry tries again. No browser command was dispatched."
      | Starter.Not_listed_in_time why ->
        "not_listed_in_time", why,
        Some "MASC started the Keeper's BiDi connection, and it was not listed in time, as \
              bidiStartFailed says. A retry after a short wait may find it listed. No browser \
              command was dispatched." in
    retry, [ "bidiStartFailed", `Assoc [ "kind", `String kind; "message", `String why ] ]

let selection_error ?bidi_start ~base_path ~tool_name ~start_time error =
  let clients () = Browser_lane.active_clients () |> List.map Browser_lane.client_json in
  let started_retry, started_fields = bidi_start_fields bidi_start in
  (* [deciding] are the short fields that say what was refused and what to do
     next; [listing] are the connection lists, which grow with the number of
     browsers. The lists go last because several readers of a recorded
     rejection keep only its beginning. *)
  let rejection ~deciding ~listing =
    let deciding =
      (match started_retry with
       | None -> deciding
       | Some retry -> List.map (function "retry", _ -> "retry", `String retry | field -> field) deciding)
      @ started_fields in
    let data =
      `Assoc ((("error", `String (Browser_lane.selection_error_code error)) :: deciding) @ listing) in
    Tool_result.make_err ~tool_name ~start_time
      ~class_:Tool_result.Workflow_rejection ~effect_disposition:Tool_result.Proven_pre_effect
      ~data (Yojson.Safe.to_string data) in
  (* With no connection left to carry the work, what the BiDi host's own
     record says is the rest of the answer: whether one runs, and why the
     last one ended. The operator acts on it, so the answer carries it —
     without it a workspace that lives on a BiDi host alone reads a host
     that ended with the bare no_live_client. A host that runs is named
     whatever the lists say: one that polls here stands in them, and one
     they lack is exactly what its report tells the operator to look into.
     For a host that has ended, the lists being empty is what makes the
     ending the reason the work cannot go on: while any connection remains,
     choosing among them is the remedy, and the ending says nothing about
     that. *)
  let bidi_host_field (observation : Browser_bidi_host_status.observation) ~remaining =
    (* Every state answers here, no catch-all: a record the reader cannot
       make out still says whether a host holds the workspace's lock, and
       one that does is running — the paragraph says so, and the remedy is
       not choosing among connections. A lock that could not be asked is
       carried by the no-connection arm, where the host's word is due
       whatever it would have said. *)
    let running = match observation.record with
      | Browser_bidi_host_record.Running _
      | Browser_bidi_host_record.Record_missing_but_locked
      | Browser_bidi_host_record.Unreadable { held = Some true; _ } -> true
      | Browser_bidi_host_record.Unreadable { held = Some false | None; _ }
      | Browser_bidi_host_record.Never_started
      | Browser_bidi_host_record.Ended _
      | Browser_bidi_host_record.Died _ -> false in
    if running || remaining = [] then
      ["bidiHost", Browser_bidi_host_status.summary_to_json observation]
    else []
  in
  (* One observation answers for the launcher, the host's record and the
     connections: the record is read first and the server asked last, so the
     list an answer shows is the one its host paragraph was written from. *)
  (* An answer that carries what the start it asked for came to says it
     there, in bidiStartFailed or bidiConnection, and not again in the host
     paragraph. *)
  let observed () =
    let observation =
      Browser_bidi_host_status.observe ~base_path ~configuration:(Runtime.browser_configuration ()) in
    match bidi_start with
    | Some _ -> Browser_bidi_host_status.without_last_start observation
    | None -> observation in
  let observe () =
    let observation = observed () in
    let clients =
      Browser_bidi_host_status.listed_clients observation |> List.map Browser_lane.client_json in
    observation, clients in
  match error with
  | Browser_lane.Activity_rejected refusal ->
    rejection ~deciding:["message", `String (Browser_lane.activity_rejection_message refusal)]
      ~listing:[]
  | Browser_lane.No_live_client ->
    let observation, clients = observe () in
    let host = observation.lane in
    rejection ~deciding:(["retry", `String (no_client_retry host);
                          "host", Browser_lane_launcher.to_json host]
                         @ bidi_host_field observation ~remaining:clients)
      ~listing:["clients", `List clients]
  | Browser_lane.Selected_client_disconnected client_id ->
    let observation, clients = observe () in
    let host = observation.lane in
    let retry = match clients with
      | _ :: _ -> "That browser is no longer connected. Choose a browser from clients and retry \
                   with its clientId. No browser command was dispatched."
      | [] -> "That browser is no longer connected and none is. " ^ no_client_retry host in
    rejection ~deciding:(["clientId", `String (Browser_lane.client_id_to_string client_id);
                          "retry", `String retry; "host", Browser_lane_launcher.to_json host]
                         @ bidi_host_field observation ~remaining:clients)
      ~listing:["clients", `List clients]
  | Browser_lane.Ambiguous_clients _ ->
    rejection ~deciding:["retry", `String "Choose a connected browser and retry with its clientId. \
                                           No browser command was dispatched."]
      ~listing:["clients", `List (clients ())]
  | Browser_lane.Transport_unsupported { client_id; transport; capability } ->
    let serving_transports = Browser_lane.live_transports_serving capability in
    (* An answer lists the lane's connections once. Where BiDi serves the
       work, the BiDi host's record is read first, which can let other
       fibers run, and the list is the one that observation holds: a host
       that attached meanwhile is in it, offered and not reported on. *)
    let host =
      if List.mem Browser_lane.Webdriver_bidi serving_transports
      then Some (observed ())
      else None in
    let listed =
      match host with
      | Some host -> Browser_bidi_host_status.listed_clients host
      | None -> Browser_lane.active_clients () in
    let serving_clients =
      List.filter (fun (info : Browser_lane.client_info) ->
        Browser_lane.live_transport_serves info.transport capability) listed in
    (* A connection of the other kind may belong to another browser profile,
       and its tab IDs are its own, so the retry starts from its tabs. *)
    let retry = match serving_clients with
      | _ :: _ ->
        "This browser connection cannot do that. A connection in servingClients can: list its \
         tabs and observe the page again with its clientId, then retry there. Tab IDs and \
         observations belong to their connection. No browser command was dispatched."
      | [] ->
        "No connected browser connection can do that: "
        ^ String.concat "; or " (List.map Browser_lane.live_transport_setup serving_transports)
        ^ ". The same request returns the same answer until then; other work this \
           connection serves is unaffected. No browser command was dispatched." in
    (* With no connection that serves work BiDi does, the answer says what
       the BiDi host's own record says: whether one runs and why the last
       one ended. The operator acts on it, not the Keeper. A connection that
       serves the work makes that beside the point: the Keeper retries
       there. The state and the paragraph sit with the fields that decide.
       The paragraph does not grow with what a host has done. Its length
       follows the workspace path, the address the last host was given, the
       reason for ending and, for a host that met another profile, the two
       profile paths: a host writes each of those in at most 515 bytes, and
       the expected path is named twice. Where MASC starts the Keeper
       Firefox it also names that profile and, unless this answer carries
       the start it asked for, the last start's message, kept in at most
       1027 bytes. The address has no limit of its own. The record itself
       is not sent: its
       list of results grows while a host runs. *)
    let bidi_host =
      match serving_clients, host with
      | [], Some host -> ["bidiHost", Browser_bidi_host_status.summary_to_json host]
      | [], None | _ :: _, (Some _ | None) -> [] in
    rejection
      ~deciding:(["capability", `String (Browser_lane.live_capability_to_wire capability);
                 "transport", `String (Browser_lane.live_transport_to_string transport);
                 "clientId", `String (Browser_lane.client_id_to_string client_id);
                 "retry", `String retry;
                 "servingTransports", `List (List.map (fun transport ->
                   `String (Browser_lane.live_transport_to_string transport)) serving_transports)]
                 @ bidi_host)
      ~listing:["servingClients", `List (List.map Browser_lane.client_json serving_clients);
                "clients", `List (List.map Browser_lane.client_json listed)]

let browser_choice_error ~tool_name ~start_time error =
  let data = Browser_selection.error_to_json error in
  Tool_result.make_err ~tool_name ~start_time ~class_:Tool_result.Workflow_rejection
    ~effect_disposition:Tool_result.Proven_pre_effect ~data (Yojson.Safe.to_string data)

let read_failure ~base_path ~tool_name ~start_time = function
  | Browser_surface.Unselected error -> selection_error ~base_path ~tool_name ~start_time error
  | Browser_surface.Unchosen error ->
      browser_choice_error ~tool_name ~start_time error
  | Browser_surface.Unobserved detail -> make_workflow_err ~tool_name ~start_time detail
  | Browser_surface.Unavailable detail ->
    Tool_result.make_err ~tool_name ~start_time ~class_:Tool_result.Dependency_unavailable detail

let required_actions args = match args with
  | `Assoc fields -> (match List.filter (fun (key,_) -> key="requiredActions") fields with
      | [] -> Ok []
      | [(_,value)] -> Browser_capabilities.parse_required_actions value
      | _::_::_ -> Error "requiredActions must occur only once")
  | _ -> Error "body must be a JSON object"
let with_capabilities target required = function
  | Browser_lane.Answered (`Assoc envelope) -> (match List.assoc_opt "data" envelope with
      | Some (`Assoc fields) ->
          let data = `Assoc (("browserCapabilities",Browser_capabilities.to_json (Browser_capabilities.backend_of_target target))
            :: ("requiredActions",`List (List.map (fun operation -> `String (Browser_capabilities.operation_name operation)) required))
            :: List.filter (fun (key,_) -> not (List.mem key ["browserCapabilities";"requiredActions"])) fields) in
          Browser_lane.Answered (`Assoc (("data",data)::List.remove_assoc "data" envelope))
      | Some (`List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null) | None ->
          Browser_lane.Answered (`Assoc envelope))
  | (Browser_lane.Answered _ | Browser_lane.Timed_out | Browser_lane.Rejected_before_effect _
     | Browser_lane.Lane_absent | Browser_lane.Refused _) as answer -> answer

let handle_tabs ~base_path ~tool_name ~start_time args : Tool_result.result =
  match tool_request args, required_actions args with
  | Error error, _ | _, Error error -> make_input_err ~tool_name ~start_time error
  | Ok {tab_id=Some _;_}, Ok (_::_) -> make_input_err ~tool_name ~start_time "requiredActions applies only to initial discovery without tabId; retain the observed browser identity for bound tabs."
  | Ok request, Ok required_actions ->
    match Browser_surface.resolve_target ~required_actions ~verb:Browser_lane.Tabs_list request with
    | Error error -> read_failure ~base_path ~tool_name ~start_time error
    | Ok (selected, target) ->
      match Browser_lane.issue_for ~target ~verb:Browser_lane.Tabs_list ~timeout_sec:Browser_lane.default_timeout_sec with
      | Error error -> selection_error ~base_path ~tool_name ~start_time error
      | Ok answer ->
        answer_to_result ~lane:(Browser_lane.target_lane target) ~tool_name ~start_time (add_client ~selection:selected target answer |> with_capabilities target required_actions)
;;

(* Initial work-session selection shares the discovery policy. Once a tab
   is observed, its concrete lane/client must accompany every later action. *)
let issue_on_server_lane ?(required_actions=[]) ~tool_name ~start_time args ~verb ~timeout_sec =
  match tool_request args with
  | Error detail -> make_input_err ~tool_name ~start_time detail
  | Ok request ->
    let bound = match verb with
      | Browser_lane.Session_close | Browser_lane.Page_goto _ -> true
      | Browser_lane.Session_open _ | Browser_lane.Session_status | Browser_lane.Tabs_list
      | Browser_lane.Page_read _ | Browser_lane.Page_document _ | Browser_lane.Page_downloads _
      | Browser_lane.Page_capture _ | Browser_lane.Page_scene _ | Browser_lane.Page_interact _
      | Browser_lane.Page_elements _ | Browser_lane.Page_act _ | Browser_lane.Page_context _
      | Browser_lane.Page_instruct _ | Browser_lane.Page_locate _ | Browser_lane.Page_extract _ ->
        Option.is_some request.tab_id in
    match Browser_selection.resolve ~required_actions ~verb ~bound request.route with
    | Error error ->
      browser_choice_error ~tool_name ~start_time error
    | Ok selected ->
      let owned = match selected.route with
        | Browser_lane.Automation_route -> Some (Browser_lane.Server_automation, Browser_lane.Automation)
        | Browser_lane.Stagehand_route -> Some (Browser_lane.Server_stagehand, Browser_lane.Stagehand)
        | Browser_lane.Live_route _ -> None in
      match owned with
      | None -> make_input_err ~tool_name ~start_time
          ("Use an owned work browser for session management or navigation; " ^ Browser_lane.server_lane_refused)
      | Some (lane, target) ->
        match Browser_selection.require_target required_actions target with
        | Error error -> browser_choice_error ~tool_name ~start_time error
        | Ok () ->
          answer_to_result ~lane:(Browser_lane.server_lane_name lane) ~tool_name ~start_time
            (Browser_lane.issue_server_lane lane ~verb ~timeout_sec |> add_client ~selection:selected target
              |> with_capabilities target required_actions)
;;

let handle_session ~tool_name ~start_time args : Tool_result.result =
  let action = get_string args "action" "" in
  match action, required_actions args with
  | _, Error error -> make_input_err ~tool_name ~start_time error
  | ("close" | "status"), Ok _ when (match args with `Assoc fields -> List.mem_assoc "requiredActions" fields | _ -> false) ->
      make_input_err ~tool_name ~start_time "requiredActions applies only to initial BrowserSession action=open."
  | "open", Ok required_actions ->
    let headless = Some (get_bool args "headless" false) in
    issue_on_server_lane ~required_actions ~tool_name ~start_time args ~verb:(Browser_lane.Session_open { headless }) ~timeout_sec:60.0
  | "close", Ok _ -> issue_on_server_lane ~tool_name ~start_time args ~verb:Browser_lane.Session_close ~timeout_sec:60.0
  | "status", Ok _ ->
    (* Reads the backend's record rather than the browser, so the short timeout
       is the lane round trip, not a page load. *)
    issue_on_server_lane ~tool_name ~start_time args ~verb:Browser_lane.Session_status ~timeout_sec:10.0
  | _, Ok _ ->
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

(* The [mode] argument of [masc_browser_read], read once. The six top-level
   reads take the page as a whole; [frames] and [dialog] read the automation
   lane's page context. The tool schema's enum names the same values. *)
type top_level_read =
  [ `Text | `Elements | `Scene | `Regions | `Screenshot | `Downloads ]
[@@deriving enumerate]

type read_mode = [ top_level_read | `Frames | `Dialog ] [@@deriving enumerate]

let read_mode_to_string : read_mode -> string = function
  | `Text -> "text"
  | `Elements -> "elements"
  | `Scene -> "scene"
  | `Regions -> "regions"
  | `Screenshot -> "screenshot"
  | `Downloads -> "downloads"
  | `Frames -> "frames"
  | `Dialog -> "dialog"
;;

let read_mode_of_args args : (read_mode, string) result =
  let unknown () =
    Error
      ("mode must be one of "
       ^ String.concat ", " (List.map read_mode_to_string all_of_read_mode))
  in
  match Json_util.assoc_member_opt "mode" args with
  | None -> Ok `Text
  | Some (`String raw) ->
    (match
       List.find_opt
         (fun mode -> String.equal (read_mode_to_string mode) raw)
         all_of_read_mode
     with
     | Some mode -> Ok mode
     | None -> unknown ())
  | Some _ -> unknown ()
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
    let missing_binding = match request.route,request.tab_id with
      | Browser_selection.Automatic,Some _ -> true
      | Browser_selection.Automatic,None | Browser_selection.Exact _,_ -> false in
    if missing_binding then
      read_failure ~base_path ~tool_name ~start_time (Browser_surface.Unchosen Browser_selection.Binding_required)
    else
    let automation = match request.route with
      | Browser_selection.Exact Browser_lane.Automation_route -> true
      | Browser_selection.Automatic
      | Browser_selection.Exact (Browser_lane.Live_route _ | Browser_lane.Stagehand_route) -> false in
    match Browser_lane.Action.parse_frame_path args with
    | Error detail -> make_input_err ~tool_name ~start_time detail
    | Ok frame_path ->
    match read_mode_of_args args with
    | Error detail -> make_input_err ~tool_name ~start_time detail
    | Ok mode ->
    let top_document_view = match mode with
      | `Scene | `Regions -> frame_path = []
      | `Text | `Elements | `Screenshot | `Downloads | `Frames | `Dialog -> false in
    let scope_present = match args with `Assoc fields -> List.mem_assoc "scope" fields | _ -> false in
    let destination_guard_present = match args with `Assoc fields -> (List.mem_assoc "expectedUrl" fields || List.mem_assoc "navigationSource" fields) | _ -> false in
    if destination_guard_present && not top_document_view then
      make_input_err ~tool_name ~start_time "expectedUrl and navigationSource support top-document scene or regions only"
    else if scope_present && not top_document_view then
      make_input_err ~tool_name ~start_time "scope supports top-document scene or regions only"
    else
    let contextual_read () =
      if not automation then make_input_err ~tool_name ~start_time "frame and dialog reads require automation"
      else (match get_int_opt args "tabId" with
        | None -> make_input_err ~tool_name ~start_time "contextual read requires an observed tabId"
        | Some tab_id when tab_id < 0 -> make_input_err ~tool_name ~start_time "tabId must be nonnegative"
        | Some tab_id ->
          let mode = match mode with
            | `Text -> Ok (`Text (get_int args "maxChars" Browser_page_script.default_text_chars))
            | `Elements -> Ok `Elements | `Frames -> Ok `Frames
            | `Dialog when frame_path = [] -> Ok `Dialog
            | `Dialog | `Scene | `Regions | `Screenshot | `Downloads ->
              Error "framePath supports text, elements and frames; dialogs belong to the top-level tab" in
          match mode with
          | Error detail -> make_input_err ~tool_name ~start_time detail
          | Ok mode ->
            let verb = Browser_lane.Page_context {tab_id;frame_path;mode} in
            (match Browser_surface.resolve_target ~verb request with
             | Error error -> read_failure ~base_path ~tool_name ~start_time error
             | Ok (selected,target) ->
               match Browser_lane.issue_for ~target ~verb ~timeout_sec:Browser_lane.default_timeout_sec with
               | Error error -> selection_error ~base_path ~tool_name ~start_time error
               | Ok answer -> answer_to_result ~lane:(Browser_lane.target_lane target) ~tool_name ~start_time
                   (add_client ~selection:selected target answer)))
    in
    if frame_path <> [] then contextual_read ()
    else
    match mode with
    | `Frames | `Dialog -> contextual_read ()
    | #top_level_read as top ->
    (* One rule for the cap, the one every lane's executor applies: a value
       out of range is refused, not quietly clamped. *)
    match Browser_page_script.text_cap (get_int_opt args "maxChars") with
    | Error detail -> make_input_err ~tool_name ~start_time detail
    | Ok max_chars ->
    let read_scene view =
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
                ~view
                ?scope {request with tab_id=Some tab_id} ~max_chars with
              | Ok data -> Tool_result.make_ok ~tool_name ~start_time ~data ()
              | Error failure -> read_failure ~base_path ~tool_name ~start_time failure)
       | _ -> make_input_err ~tool_name ~start_time "scene requires an observed tabId")
    in
    let read_top_level verb =
      match Browser_surface.resolve_target ~verb request with
      | Error error -> read_failure ~base_path ~tool_name ~start_time error
      | Ok (selected, target) ->
        match Browser_lane.issue_for ~target ~verb ~timeout_sec:Browser_lane.default_timeout_sec with
        | Error error -> selection_error ~base_path ~tool_name ~start_time error
        | Ok answer ->
          answer_to_result ~lane:(Browser_lane.target_lane target) ~tool_name ~start_time (add_client ~selection:selected target answer)
    in
    match top with
    | `Scene -> read_scene Browser_lane.Content
    | `Regions -> read_scene Browser_lane.Regions
    | `Downloads ->
      if not automation then make_input_err ~tool_name ~start_time "downloads require automation"
      else (match get_int_opt args "tabId" with
        | Some tab_id when tab_id >= 0 -> read_top_level (Browser_lane.Page_downloads {tab_id})
        | _ -> make_input_err ~tool_name ~start_time "downloads require an observed nonnegative tabId")
    | `Screenshot ->
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
    | `Text ->
      read_top_level
        (Browser_lane.Page_read {tab_id=get_int_opt args "tabId";max_chars=Some max_chars})
    | `Elements -> read_top_level (Browser_lane.Page_elements {tab_id=get_int_opt args "tabId"})
;;

(* Retention requires an owner that will commit the observation receipt. *)
let retain_read_result ~base_path ~tool_name ~start_time args result =
  let retained = match read_mode_of_args args with
    | Ok `Scene -> Browser_observation.retain ~base_path ~view:Browser_lane.Content result
    | Ok `Regions -> Browser_observation.retain ~base_path ~view:Browser_lane.Regions result
    | Ok (`Text | `Elements | `Screenshot | `Downloads | `Frames | `Dialog) | Error _ -> Ok result in
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

let act_route ~tool_name ~start_time args action =
  match tool_request args with
  | Error detail -> Error (make_input_err ~tool_name ~start_time detail)
  | Ok request ->
    let bound = match action with Browser_lane.Action.Open_tab _ -> false | On_tab _ -> true in
    match Browser_selection.resolve ~verb:(Browser_lane.Page_act action) ~bound request.route with
    | Error error ->
        Error (browser_choice_error ~tool_name ~start_time error)
    | Ok selected ->
      match selected.route with
      | Browser_lane.Live_route None -> Error (make_input_err ~tool_name ~start_time
          "live open_tab requires an explicit observed clientId")
      | Browser_lane.Live_route (Some _) | Browser_lane.Automation_route | Browser_lane.Stagehand_route -> Ok selected

let handle_act_with_phase ?upload_paths ~base_path ~tool_name ~start_time args =
  let pre_error detail =
    make_workflow_err ~tool_name ~start_time detail, Tool_result.Proven_pre_effect in
  match Browser_lane.Action.parse args with
  | Error detail -> make_input_err ~tool_name ~start_time detail, Tool_result.Proven_pre_effect
  | Ok action ->
  match act_route ~tool_name ~start_time args action with
  | Error error -> error, Tool_result.Proven_pre_effect
  | Ok _ when (match action with Browser_lane.Action.On_tab {interaction=Upload _;_} -> upload_paths=None
        | Open_tab _ | On_tab {interaction=(Click _|Fill _|Press _|Select _|Scroll _|Accept_dialog _|Dismiss_dialog|Back|Forward|Reload|Close_tab);_} -> false) ->
    pre_error "upload requires an authoritative Keeper file context"
  | Ok selected ->
    let route = selected.Browser_selection.route in
    let action = match action, upload_paths with
      | Browser_lane.Action.On_tab ({interaction=Upload {selector;_};_} as target), Some paths ->
        Browser_lane.Action.On_tab {target with interaction=Upload {selector;paths}}
      | Browser_lane.Action.Open_tab _, (None | Some _)
      | Browser_lane.Action.On_tab { interaction = Upload _; _ }, None
      | Browser_lane.Action.On_tab
          { interaction =
              ( Click _ | Fill _ | Press _ | Select _ | Scroll _ | Accept_dialog _
              | Dismiss_dialog | Back | Forward | Reload | Close_tab )
          ; _ }, (None | Some _) -> action in
    let verb = Browser_lane.Page_act action in
    let issued = Result.bind (Browser_lane.resolve_target ~verb route) (fun target ->
      Browser_lane.issue_for ~target ~verb ~timeout_sec:60.
      |> Result.map (fun answer -> target,answer)) in
    match issued with
    | Error error ->
      selection_error ~base_path ~tool_name ~start_time error, Tool_result.Proven_pre_effect
    | Ok (target,answer) ->
      let phase = match answer, route with
        | (Browser_lane.Rejected_before_effect _ | Browser_lane.Lane_absent), _ -> Tool_result.Proven_pre_effect
        | Browser_lane.Refused _, Browser_lane.Live_route _ -> Tool_result.Proven_pre_effect
        | Browser_lane.Refused _, (Browser_lane.Automation_route | Browser_lane.Stagehand_route) -> Tool_result.Effect_outcome_unknown
        | Browser_lane.Answered (`Assoc fields), _ when
            List.assoc_opt "ok" fields = Some (`Bool false) -> backend_failure_phase fields
        | (Browser_lane.Timed_out | Browser_lane.Answered _), _ -> Tool_result.Effect_outcome_unknown in
      let selected = Browser_selection.bind_target selected target in
      answer_to_result ~lane:(Browser_lane.target_lane target) ~tool_name ~start_time
        (add_client ~selection:selected target answer), phase
;;
let handle_act ~base_path ~tool_name ~start_time args =
  fst (handle_act_with_phase ~base_path ~tool_name ~start_time args)

(* Work only a BiDi connection serves, refused because no listed connection
   serves it, has the server start the Keeper's BiDi connection
   (RFC-browser-keeper-firefox §3.5): with the chosen one gone or of another
   transport. An interact request always names a tab, and a tab names the
   connection it was observed on, so it never reaches this with no connection
   or with several to choose from: [Browser_selection.resolve] answers an
   unchosen route with [Binding_required] while a tab is named. The request
   itself is not sent there: its tab and point were observed on another
   connection. *)
let bidi_start_for verb (error : Browser_lane.selection_error) =
  match Browser_lane.live_capability verb with
  | None -> None
  | Some capability ->
    let bidi_only =
      List.equal ( = ) (Browser_lane.live_transports_serving capability) [ Browser_lane.Webdriver_bidi ] in
    let wanting_a_connection =
      match error with
      | Browser_lane.Selected_client_disconnected _ | Browser_lane.Transport_unsupported _ -> true
      | Browser_lane.No_live_client | Browser_lane.Ambiguous_clients _
      | Browser_lane.Activity_rejected _ -> false in
    let served () =
      List.exists
        (fun (info : Browser_lane.client_info) -> Browser_lane.live_transport_serves info.transport capability)
        (Browser_lane.active_clients ()) in
    if bidi_only && wanting_a_connection && not (served ()) then
      Some (Browser_keeper_firefox_starter.bring_up ())
    else None

let handle_interact_with_phase ?actor ~base_path ~tool_name ~start_time args =
  match Browser_interaction.parse args with
  | Error error -> make_input_err ~tool_name ~start_time error, Tool_result.Proven_pre_effect
  | Ok request ->
    let verb = Browser_lane.Page_interact {tab_id=request.tab_id;
      expected_url=request.expected_url; action=request.action} in
    let surface_request : Browser_surface.request = {route=request.route;tab_id=Some request.tab_id} in
    let issued = Result.bind (Browser_surface.resolve_target ~verb surface_request) (fun (selected, target) ->
      Browser_lane.issue_for_actor ~actor ~target ~verb
        ~timeout_sec:Browser_lane.default_timeout_sec
      |> Result.map_error (fun error -> Browser_surface.Unselected error)
      |> Result.map (fun answer -> selected, target, answer)) in
    (match issued with
     | Error (Browser_surface.Unselected error) ->
       selection_error ?bidi_start:(bidi_start_for verb error) ~base_path ~tool_name ~start_time error,
       Tool_result.Proven_pre_effect
     | Error ((Browser_surface.Unchosen _ | Browser_surface.Unobserved _ | Browser_surface.Unavailable _) as error) ->
       read_failure ~base_path ~tool_name ~start_time error, Tool_result.Proven_pre_effect
     | Ok (selected, target, answer) ->
       let phase = match answer with
         | Browser_lane.Rejected_before_effect _ | Browser_lane.Lane_absent -> Tool_result.Proven_pre_effect
         | Browser_lane.Answered (`Assoc fields) when
             List.assoc_opt "ok" fields = Some (`Bool false)
             && List.assoc_opt "effectPhase" fields = Some (`String "not_started") -> Tool_result.Proven_pre_effect
         | Browser_lane.Answered _ | Browser_lane.Refused _ | Browser_lane.Timed_out -> Tool_result.Effect_outcome_unknown in
       answer_to_result ~lane:(Browser_lane.target_lane target) ~tool_name ~start_time (add_client ~selection:selected target answer), phase)
;;
let handle_interact ?actor ~base_path ~tool_name ~start_time args =
  fst (handle_interact_with_phase ?actor ~base_path ~tool_name ~start_time args)

let instruct_arguments = [ "action"; "instruction"; "tabId"; "schema" ]

(* The extension and host model responder share one sentence deadline. Leave
   the existing browser transport wait after it so their refusal can arrive
   before the outer lane deadline. *)
let instruct_timeout_sec =
  (float_of_int (Browser_stagehand_wire.timeout_ms Browser_stagehand_wire.sentence_timeout) /. 1000.)
  +. Browser_lane.default_timeout_sec
;;

type instruct_action = Act | Observe | Extract

let instruct_action = function
  | Some (`String "act") -> Ok Act
  | Some (`String "observe") -> Ok Observe
  | Some (`String "extract") -> Ok Extract
  | Some _ | None -> Error "action must be one of: act, observe, extract"
;;

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
  let* action = instruct_action (List.assoc_opt "action" fields) in
  match action, instruction, schema with
  | Act, Some instruction, None -> Ok (Browser_lane.Page_instruct { tab_id; instruction })
  | Observe, instruction, None -> Ok (Browser_lane.Page_locate { tab_id; instruction })
  | Extract, Some instruction, schema -> Ok (Browser_lane.Page_extract { tab_id; instruction; schema })
  | (Act | Extract), None, _ -> Error "act and extract need an instruction"
  | (Act | Observe), _, Some _ -> Error "schema is for extract only"
;;

(* The Stagehand lane only: the sentence verbs are refused everywhere else. *)
let handle_instruct_with_phase ~tool_name ~start_time args =
  let refused_as_input detail = make_input_err ~tool_name ~start_time detail, Tool_result.Proven_pre_effect in
  match args with
  | `Assoc fields when List.for_all (fun (key, _) -> List.mem key instruct_arguments) fields ->
    (match instruct_verb fields with
     | Error detail -> refused_as_input detail
     | Ok verb ->
       let answer = Browser_lane.issue_stagehand ~verb ~timeout_sec:(Some instruct_timeout_sec) in
       (* observe and extract read the page; a failed act may have acted. *)
       let phase =
         match answer, Browser_lane.verb_is_read verb with
         | (Browser_lane.Rejected_before_effect _ | Browser_lane.Lane_absent), _ -> Tool_result.Proven_pre_effect
         | (Browser_lane.Refused _ | Browser_lane.Timed_out | Browser_lane.Answered _), true -> Tool_result.Proven_pre_effect
         | (Browser_lane.Refused _ | Browser_lane.Timed_out | Browser_lane.Answered _), false ->
           Tool_result.Effect_outcome_unknown
       in
       answer_to_result ~lane:Browser_lane.Lane_name.Stagehand ~tool_name ~start_time answer, phase)
  | `Assoc fields ->
    let unknown =
      List.filter_map
        (fun (key, _) -> if List.mem key instruct_arguments then None else Some key)
        fields
    in
    let hint =
      if List.mem "lane" unknown then "; BrowserInstruct is stagehand only and takes no lane"
      else ""
    in
    refused_as_input ("unknown browser instruct argument: " ^ String.concat ", " unknown ^ hint)
  | _ -> refused_as_input "browser arguments must be an object"
;;

let handle_instruct ~tool_name ~start_time args = fst (handle_instruct_with_phase ~tool_name ~start_time args)
