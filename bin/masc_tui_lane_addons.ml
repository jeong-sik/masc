module Row = Masc.Lane_addon_types
module Document = Masc_tui_lane_declaration
module Action = Masc.Lane_addon_action
module Application = Masc_tui_lane_application

(* Split written line breaks before neutralising terminal controls. These are
   document blocks (JSON, readings, receipts), not single-line table cells.
   Cell splitting preserves indentation, blank lines and exact value spaces. *)
let document_rows ~width text =
  Masc_tui_text_block.lines text
  |> List.concat_map (fun line ->
      Masc_tui_message_layout.split_cells ~max_cells:(max 1 width)
        (Masc.Tui_terminal_text.sanitize_terminal_text line))
type runtime_presence = Live_entry | Retained_binding | Presence_unknown
type host_wait =
  | Host_wait_exact of Masc.Lane_addon_exact.not_final
  | Host_wait_operator
  | Host_wait_source of string
type host_issue =
  | Host_listing_failed of string
  | Host_listing_refused of string
  | Host_relisted_delivered_request of string
  | Host_result_delivery_failed of { request_id : string; detail : string }
  | Host_exact_record_failed of { request_id : string; detail : string }
  | Host_ask_record_failed of { request_id : string; detail : string }
  | Host_no_exact_runner
  | Host_no_web_search_runner
type host_requests = {
  hr_cycles : int;
  hr_waiting : (string * host_wait) list;
  hr_issue : host_issue option;
}
type instance = {
  id : string; run_id : string; addon_id : string; title : string;
  revision : string; phase : Row.phase; runtime_presence : runtime_presence;
  observation_seq : int; rows_count : int;
  installation_id : string option; source_path : string option; configuration_revision : string option; binding : Yojson.Safe.t; outputs : Row.output_ports;
  skills_directory : string option; ui_category : Masc.Lane_addon_category.t option; incarnation : string; action_schema : Yojson.Safe.t option; binding_schema : Yojson.Safe.t option; display : Masc.Lane_addon_presentation.t;
  host_requests : (host_requests, string) result option;
  row_actions : Masc.Lane_addon_row_action.verdict list option;
  action_tool : string option;
}
type declaration_origin = Parsed_declaration | Issue_only
type declaration = {
  source_path : string; installation_id : string option; ui_category : Masc.Lane_addon_category.t option; enabled : bool option; desired : string option;
  applied : string option; instance_id : string option; issues : string list;
  origin : declaration_origin;
  application : Application.observation option;
}
type configuration = { directory : string; complete : bool; declarations : declaration list }
type snapshot = { instances : instance list; output : Row.output; complete : bool option;
  configuration : configuration option }
type connection_workers = {
  installation_workers : instance list;
  other_path_owners : instance list;
}
type action_request = { instance_id : string; incarnation : string; request_id : string; action : Yojson.Safe.t }
type request = Inspect | Attach of Yojson.Safe.t | Observe of string | Detach of string
  | Slice of (string * string) list | Evidence of Yojson.Safe.t
  | Act of action_request | Action_status of action_request
  | Subscriptions of Yojson.Safe.t
type row_entry = {
  index : int; label : string;
  filled : (Masc.Lane_addon_row_action.filled, Masc.Lane_addon_row_action.unfilled list) result;
}
type row_stage =
  | Row_list of { row_id : string; row_title : string; entries : row_entry list }
  | Row_form of { row_id : string; index : int; label : string; locked : (string * Yojson.Safe.t) list }
type action_menu = {
  target_id : string; target_incarnation : string; target_title : string; request_id : string;
  tool_name : string; schema : Yojson.Safe.t; choices : Yojson.Safe.t list; cursor : int;
  form : Masc_tui_schema_form.t option;
  row : row_stage option;
}
type focus = Timeline | Connections | Configurations | Instances | Rows
type presentation = Summary | Technical | Flow
type screen = Overview | Detail of string * string
type overview_mode = Current_installations | Retained_runs
type overview_anchor = Worker_anchor of string * string | Declaration_anchor of string * string option
type overview_selection = Unvisited | No_selection | Selection of overview_anchor
type diagnostic =
  | Detail_read_failure of string
  | Request_failure of string
  | Input_failure of string
(* Marked rows leave the view as one frozen bundle under their owning worker.
   Handing the bundle's reference to a Keeper is a separate choice made here by
   name, so the operator neither types JSON nor delivers by accident. [choice] 0
   preserves only; [choice] n selects [List.nth keepers (n-1)]. Delivery is an
   optional message the Keeper may use, defer or ignore. *)
type evidence_prompt = {
  evidence : Yojson.Safe.t; owner_title : string; row_count : int;
  keepers : string list; choice : int; broadcast_request_id : string;
}
type t = {
  installer : Masc_tui_lane_installer.t option;
  package_directory : string option;
  subscription_panel : Masc_tui_lane_subscriptions.t option;
  evidence_prompt : evidence_prompt option;
  pending_broadcasts : (Yojson.Safe.t * string) list;
  presentation : presentation; screen : screen; overview_mode : overview_mode; help_open : bool;
  current_selection : overview_selection; history_selection : overview_selection;
  action_menu : action_menu option;
  records : Masc_tui_lane_records.t option;
  snapshot : snapshot option; loading : bool; error : diagnostic option;
  application_reading : configuration Application.reading;
  snapshot_read_error : string option;
  detail_read_error : (string * string * string) option;
  receipt : Yojson.Safe.t option; generation : int; instance_cursor : int;
  row_cursor : int; selected : string list; scroll : int; focus : focus;
  draft : string option; naming : bool; configuration_cursor : int;
  documents : Document.session list; document_key : string option; editor_ready : bool; last_action : action_request option; action_receipt : Action.receipt option;
}
let initial = { installer=None;package_directory=None;subscription_panel=None;evidence_prompt=None; pending_broadcasts=[]; presentation=Summary; screen=Overview; overview_mode=Current_installations; help_open=false; current_selection=Unvisited; history_selection=Unvisited; action_menu=None; records=None; snapshot = None; loading = false; error = None; snapshot_read_error=None; detail_read_error=None; application_reading=Application.empty; receipt = None;
  generation = 0; instance_cursor = 0; row_cursor = 0; selected = []; scroll = 0;
  focus = Instances; draft = None; naming = false; configuration_cursor = 0;
  documents = []; document_key = None; editor_ready = false; last_action=None;action_receipt=None }

(* Whether a typed character is text on the screen this view is showing. The
   installer, an action form and a draft line take the characters; every
   other screen reads them as commands. The main loop asks this before
   reading a Hangul character back into the Latin key a Korean input method
   replaced (Masc_tui_key_ime), so it does not restate the three. *)
let text_entry_open view =
  Option.is_some view.installer
  || (match view.action_menu with
      | Some { form = Some _; _ } -> true
      | Some _ | None -> false)
  || (match view.records with
      | Some overlay -> Masc_tui_lane_records.text_entry_open overlay
      | None -> false)
  || Option.is_some view.draft
open Result.Syntax
let field name = function
  | `Assoc fields -> (match List.assoc_opt name fields with Some v -> Ok v | None -> Error ("missing " ^ name))
  | _ -> Error "expected object"
let text = function `String s when String.trim s <> "" -> Ok s | _ -> Error "expected non-blank string"
let count = function `Int n when n >= 0 -> Ok n | _ -> Error "expected non-negative integer"
let get f name json = let* value = field name json in f value
let rec array parse = function
  | `List [] -> Ok []
  | `List (head :: tail) -> let* head = parse head in let* tail = array parse (`List tail) in Ok (head :: tail)
  | _ -> Error "expected array"
let nullable parse = function `Null -> Ok None | value -> Result.map Option.some (parse value)
let boolean = function `Bool value -> Ok value | _ -> Error "expected boolean"
let optional name parse json = get (nullable parse) name json
module Category = Masc.Lane_addon_category
(* Only an omitted key is unclassified. Explicit null, blank or unknown values
   are rejected by the shared parser rather than defaulted. *)
let ui_category_of fields =
  match List.filter (fun (name, _) -> String.equal name "ui_category") fields with
  | [] -> Ok None
  | [(_, value)] -> Result.map Option.some (Category.of_json value)
  | _ :: _ :: _ -> Error "duplicate ui_category"
let output_ports = function
  | `Assoc fields ->
      List.fold_right (fun (id, value) acc ->
        let* ports = acc in
        let* selection = match value with
          | `Assoc ["all_lanes", `Bool true] -> Ok Row.All_lanes
          | `Assoc ["lanes", lanes] -> let* lanes = array text lanes in
              if lanes=[] then Error "named output lane selection must not be empty" else Ok (Row.Selected_lanes lanes)
          | _ -> Error "unknown output selection" in
        Ok ((id, selection) :: ports)) fields (Ok [])
  | _ -> Error "expected named outputs"
let configuration = function
  | `Null -> Ok None
  | json ->
      let* directory = get text "directory" json in
      let* complete = get boolean "complete" json in
      let* declarations = get (array (fun json ->
        let* application = Application.decode json in
        let {Application.source_path;installation_id;enabled;desired_revision=desired;_} = application.target in
        let* applied = optional "applied_revision" text json in
        let* instance_id = optional "instance_id" text json in
        let* ui_category = match json with `Assoc fields -> ui_category_of fields | _ -> Error "expected declaration object" in
        Ok {source_path;installation_id=Some installation_id;ui_category;enabled=Some enabled;desired=Some desired;applied;instance_id;issues=[];origin=Parsed_declaration;application=Some application})) "declarations" json in
      let* issues = get (array (fun json ->
        let* source_path = get text "source_path" json in
        let* installation_id = optional "id" text json in
        let* message = get text "message" json in Ok (source_path, installation_id, message))) "issues" json in
      let declarations = List.fold_left (fun declarations (path, id, message) ->
        if List.exists (fun (d : declaration) -> d.source_path = path) declarations
        then List.map (fun (d : declaration) -> if d.source_path = path then {d with issues=d.issues @ [message]} else d) declarations
        else declarations @ [{source_path=path;installation_id=id;ui_category=None;enabled=None;desired=None;applied=None;instance_id=None;issues=[message];origin=Issue_only;application=None}]) declarations issues in
      Ok (Some {directory;complete;declarations})
let decode_configuration json =
  let* configuration = get configuration "configuration" json in
  match configuration with Some configuration -> Ok configuration
  | None -> Error "Configuration observation is unavailable"
let begin_application_read view =
  if view.loading then None else
  Option.map (fun (application_reading, ticket) ->
    {view with application_reading}, ticket)
    (Application.start ~generation:view.generation view.application_reading)
let finish_application_read view ticket result =
  {view with application_reading=Application.finish ~generation:view.generation
      ticket result view.application_reading}
let receive_application_inventory view result =
  {view with application_reading=Application.accept result}
let phase json =
  let* kind = get text "kind" json in
  match kind with
  | "attached" -> Ok Row.Attached | "observing" -> Ok Row.Observing
  | "detaching" -> Ok Row.Detaching | "detached" -> Ok Row.Detached
  | "failed" -> let* detail = get text "message" json in Ok (Row.Failed detail)
  | _ -> Error "unknown add-on phase"
let runtime_presence json =
  match field "runtime_presence" json with
  | Error _ -> Ok Presence_unknown
  | Ok (`String "live") -> Ok Live_entry
  | Ok (`String "retained") -> Ok Retained_binding
  | Ok _ -> Error "unknown runtime presence"
let live_entry instance = match instance.runtime_presence with
  | Live_entry -> true
  | Retained_binding | Presence_unknown -> false
let host_wait json =
  match json with
  | `Assoc ["reason", `String "awaiting_operator"] -> Ok Host_wait_operator
  | `Assoc fields when List.assoc_opt "reason" fields = Some (`String "source_unavailable") ->
      (match List.sort compare fields with
       | ["detail", `String detail; "reason", _] -> Ok (Host_wait_source detail)
       | _ -> Error "source_unavailable carries exactly its detail")
  | json -> Result.map (fun reason -> Host_wait_exact reason) (Masc.Lane_addon_exact.not_final_of_json json)
(* A request id is non-blank because the host's listing decoder refuses a
   blank one; a detail is whatever text the failure carried. *)
let detail_text = function `String s -> Ok s | _ -> Error "expected string"
let host_issue json =
  let* kind = get text "kind" json in
  let request_detail make =
    let* request_id = get text "request_id" json in
    let* detail = get detail_text "detail" json in
    Ok (make request_id detail) in
  match kind with
  | "listing_failed" -> let* detail = get detail_text "detail" json in Ok (Host_listing_failed detail)
  | "listing_refused" -> let* detail = get detail_text "detail" json in Ok (Host_listing_refused detail)
  | "relisted_delivered_request" ->
      let* request_id = get text "request_id" json in Ok (Host_relisted_delivered_request request_id)
  | "result_delivery_failed" ->
      request_detail (fun request_id detail -> Host_result_delivery_failed { request_id; detail })
  | "exact_record_failed" ->
      request_detail (fun request_id detail -> Host_exact_record_failed { request_id; detail })
  | "ask_record_failed" ->
      request_detail (fun request_id detail -> Host_ask_record_failed { request_id; detail })
  | "no_exact_runner" -> Ok Host_no_exact_runner
  | "no_web_search_runner" -> Ok Host_no_web_search_runner
  | other -> Error ("not a host request issue of this host: " ^ other)
let host_requests json =
  let* hr_cycles = get count "cycles" json in
  let* hr_waiting = get (array (fun item ->
    let* request_id = get text "request_id" item in
    let* reason = get host_wait "reason" item in
    Ok (request_id, reason))) "waiting" json in
  let* hr_issue = optional "issue" host_issue json in
  Ok { hr_cycles; hr_waiting; hr_issue }
let instance json =
  let* id = get text "instance_id" json in
  let* run_id = get text "run_id" json in
  let* addon_id = get text "addon_id" json in
  let* title = get text "title" json in
  let* revision = get text "revision" json in
  let* phase = get phase "phase" json in
  let* runtime_presence = runtime_presence json in
  let* observation_seq = get count "observation_seq" json in
  let* rows_count = get count "rows_count" json in
  let* owner = optional "configuration" (fun config ->
    let* installation_id = get text "id" config in
    let* source_path = get text "source_path" config in
    let* configuration_revision = get text "revision" config in
    Ok (installation_id, source_path, configuration_revision)) json in
  let installation_id = Option.map (fun (id,_,_) -> id) owner in
  let source_path = Option.map (fun (_,path,_) -> path) owner in
  let configuration_revision = Option.map (fun (_,_,revision) -> revision) owner in
  let* binding = field "binding" json in
  let* package = field "package" json in
  let* outputs = get output_ports "outputs" package in
  let* skills_directory = optional "skills_directory" text package in
  let* action_tool = optional "action_tool" text package in
  let* ui_category = match package with `Assoc fields -> ui_category_of fields | _ -> Error "expected package object" in
  let* incarnation = get text "incarnation" json in
  let* action_schema = optional "action_schema" (function `Assoc _ as schema -> Ok schema | _ -> Error "expected action schema") json in
  let* package_fields = match package with `Assoc fields -> Ok fields | _ -> Error "expected package object" in
  let* binding_schema = match List.assoc_opt "binding_schema" package_fields with
    | None | Some `Null -> Ok None
    | Some (`Assoc _ as schema) -> Ok (Some schema)
    | _ -> Error "expected binding schema object" in
  let* display = match List.assoc_opt "presentation" package_fields with
    | None -> Ok Masc.Lane_addon_presentation.empty
    | Some value -> Masc.Lane_addon_presentation.of_json value in
  let host_requests = match json with
    | `Assoc fields -> Option.map host_requests (List.assoc_opt "host_requests" fields)
    | _ -> None in
  (* The host writes [row_actions] only for a package that declares row
     actions; one verdict stands for each declared action, in order. *)
  let* row_actions = match json with
    | `Assoc fields -> (match List.assoc_opt "row_actions" fields with
        | None -> Ok None
        | Some value -> Masc.Lane_addon_row_action.snapshot_of_json value)
    | _ -> Error "expected instance object" in
  let* () = match row_actions with
    | Some verdicts when List.length verdicts <> List.length display.Masc.Lane_addon_presentation.actions ->
        Error "row action verdicts do not match the declared row actions"
    | Some _ | None -> Ok () in
  Ok { id; run_id; addon_id; title; revision; phase; runtime_presence; observation_seq; rows_count;
    installation_id;source_path;configuration_revision;binding;outputs;skills_directory;ui_category;incarnation;action_schema;binding_schema;display;
    host_requests; row_actions; action_tool }
let output json =
  let* rows = field "rows" json in
  let* coverage = field "coverage" json in
  Row.output_of_json (`Assoc ["rows", rows; "coverage", coverage])
let decode json =
  let* instances = get (array instance) "instances" json in
  let* output = output json in
  let* configuration = get configuration "configuration" json in
  Ok { instances; output; complete = None; configuration }
let decode_slice ~snapshot json =
  let* output = output json in
  let* complete = get (function `Bool value -> Ok value | _ -> Error "expected complete boolean") "complete" json in
  Ok { snapshot with output; complete = Some complete }
let json_object arg =
  try match Yojson.Safe.from_string arg with
    | `Assoc _ as json -> Ok json
    | _ -> Error "expected JSON object"
  with Yojson.Json_error detail -> Error detail
let action_request json =
  let* () = match json with
    | `Assoc fields when List.sort String.compare (List.map fst fields)
        = ["action";"expected_incarnation";"instance_id";"request_id"] -> Ok ()
    | _ -> Error "act/action requires exactly instance_id, expected_incarnation, request_id and action" in
  let* instance_id = get text "instance_id" json in
  let* incarnation = get text "expected_incarnation" json in
  let* request_id = get text "request_id" json in
  let* action = get (function `Assoc _ as action -> Action.canonical action | _ -> Error "action must be an object") "action" json in
  Ok {instance_id;incarnation;request_id;action}
let action_json (request : action_request) = `Assoc ["instance_id",`String request.instance_id;
  "expected_incarnation",`String request.incarnation;"request_id",`String request.request_id;"action",request.action]
let action_receipt (request : action_request) json =
  let* receipt = Action.of_json json in
  if receipt.instance_id=request.instance_id && receipt.incarnation=request.incarnation
    && receipt.request_id=request.request_id && receipt.action=request.action
  then Ok receipt else Error "Action receipt does not match the requested instance, incarnation, request and input"
let parse_request input =
  let input = String.trim input in
  let command, arg = match String.index_opt input ' ' with
    | None -> input, ""
    | Some i -> String.sub input 0 i, String.trim (String.sub input (i + 1) (String.length input - i - 1)) in
  match command, arg with
  | "subscriptions", "" -> Ok (Subscriptions (`Assoc ["operation",`String "inspect"]))
  | "subscriptions", arg -> let* json=json_object arg in Ok (Subscriptions json)
  | ("" | "inspect"), "" -> Ok Inspect
  | "observe", id when id <> "" -> Ok (Observe id)
  | "detach", id when id <> "" -> Ok (Detach id)
  | "act", _ -> let* json = json_object arg in let* request = action_request json in Ok (Act request)
  | "action", _ -> let* json = json_object arg in let* request = action_request json in Ok (Action_status request)
  | "attach", _ -> let* json = json_object arg in Ok (Attach json)
  | "evidence", _ -> let* json = json_object arg in Ok (Evidence json)
  | "slice", _ ->
      let* json = json_object arg in
      let fields = match json with `Assoc fields -> fields | _ -> [] in
      let rec query = function
        | [] -> Ok []
        | (key, value) :: rest ->
            let* value = match key, value with
              | ("run_id" | "lane_id"), `String s -> Ok s
              | ("since" | "until"), `Int n -> Ok (string_of_int n)
              | ("since" | "until"), `Float n when Float.is_finite n -> Ok (string_of_float n)
              | _ -> Error "slice accepts run_id/lane_id strings and since/until Unix seconds" in
            let* rest = query rest in Ok ((key, value) :: rest) in
      let* query = query fields in Ok (Slice query)
  | _ -> Error "Use inspect, attach {manifest_path,run_id,binding}, observe ID, detach ID, slice {run_id,since,until,lane_id}, evidence {instance_id,row_ids,keeper_name?}, act/action {instance_id,expected_incarnation,request_id,action}"
let at_cursor items cursor = if cursor < 0 then None else List.nth_opt items cursor
let detail_instance view snapshot =
  match view.screen with
  | Overview -> None
  | Detail (id, incarnation) ->
      List.find_opt (fun (instance : instance) ->
        String.equal instance.id id && String.equal instance.incarnation incarnation)
        snapshot.instances
let lane_owner instances lane_id =
  List.find_opt (fun (instance : instance) ->
    String.starts_with ~prefix:(instance.id ^ "/") lane_id) instances
let row_owner instances (row : Row.row) = lane_owner instances row.lane_id
let row_is_result (instance : instance) (row : Row.row) =
  match instance.display.readings with
  | [] -> true
  | readings -> List.exists (fun (reading : Masc.Lane_addon_presentation.reading) ->
      String.equal row.lane_id (instance.id ^ "/" ^ reading.lane_id)) readings
(* Where a lane stands among its instance's lanes: the place its package
   first names it in the presentation readings. The package says which lane
   a reader meets first and in what order Left/Right walks them; sorting lane
   ids by name put quiz/items ahead of the scorecard the quiz is read for.
   Lanes the readings do not name follow the named ones by name, and lanes of
   different instances keep apart by name. *)
let reading_rank (instance : instance) lane_id =
  let rec find index = function
    | [] -> None
    | (reading : Masc.Lane_addon_presentation.reading) :: rest ->
        if String.equal lane_id (instance.id ^ "/" ^ reading.lane_id) then Some index
        else find (index + 1) rest in
  find 0 instance.display.readings
let compare_result_lanes instances a b =
  match lane_owner instances a, lane_owner instances b with
  | Some owner, Some other when String.equal owner.id other.id ->
      (match reading_rank owner a, reading_rank owner b with
       | Some x, Some y -> Int.compare x y
       | Some _, None -> -1
       | None, Some _ -> 1
       | None, None -> String.compare a b)
  | (Some _ | None), (Some _ | None) -> String.compare a b
let rows_in_screen view snapshot =
  let rows = List.mapi (fun index row -> index, row) snapshot.output.rows in
  match view.screen with
  | Overview -> rows
  | Detail _ ->
      (match detail_instance view snapshot with
       | None -> []
       | Some target -> List.filter (fun (_, row) ->
           match row_owner snapshot.instances row with
           | Some owner -> owner.id = target.id && owner.incarnation = target.incarnation
           | None -> false) rows)
let selected_declaration view = Option.bind view.snapshot (fun snapshot ->
  Option.bind snapshot.configuration (fun configuration ->
    match view.screen with
    | Overview -> at_cursor configuration.declarations view.configuration_cursor
    | Detail _ -> Option.bind (detail_instance view snapshot) (fun item ->
        List.find_opt (fun (declaration : declaration) ->
          declaration.instance_id = Some item.id
          && Some declaration.source_path = item.source_path) configuration.declarations)))
let retained (instance : instance) = match instance.phase with
  | Row.Detached -> true
  | Row.Attached | Row.Observing | Row.Failed _ | Row.Detaching -> false
let history_group (instance : instance) = instance.source_path, instance.run_id, instance.addon_id
let overview_entries_raw ?(mode=Current_installations) snapshot =
  let instances = match mode with
    | Current_installations -> List.filter (fun item -> not (retained item)) snapshot.instances
    | Retained_runs -> List.filter retained snapshot.instances
        |> List.stable_sort (fun a b -> Stdlib.compare (history_group a) (history_group b)) in
  List.map (fun (instance : instance) -> `Instance instance) instances
  @ (match mode with
     | Retained_runs -> []
     | Current_installations ->
       match snapshot.configuration with
       | None -> []
       | Some config ->
           List.mapi (fun index (declaration : declaration) -> index, declaration) config.declarations
           |> List.filter_map (fun (index, declaration) ->
                let has_worker = Option.fold ~none:false ~some:(fun id ->
                  List.exists (fun (instance : instance) ->
                    instance.id=id && instance.source_path=Some declaration.source_path) instances)
                  declaration.instance_id in
                if has_worker then None else Some (`Declaration (index, declaration))))
let category_label = function
  | Category.Memory_and_judgment -> "Memory & judgment"
  | Category.Browser -> "Browser"
  | Category.External_communications -> "External communications"
  | Category.Voice_and_media -> "Voice & media"
  | Category.Execution_environment -> "Execution environment"
  | Category.Analysis -> "Analysis"
type current_category = Classified of Category.t | Unclassified | Unverified
let declared_category = function
  | Some category -> Classified category
  | None -> Unclassified
(* The current declaration speaks only for an exact installation and path in a
   complete, unique, issue-free reading. A worker keeps its original metadata;
   it never supplies a missing or replacement declaration's current category. *)
let current_category snapshot entry =
  let trusted_declaration ~id ~path =
    match snapshot.configuration with
    | Some {complete=true; declarations; _} ->
        let claims (d : declaration) =
          String.equal d.source_path path
          || Option.fold ~none:false ~some:(fun id -> d.installation_id=Some id) id in
        (match List.filter claims declarations with
         | [d] when d.installation_id=id && String.equal d.source_path path ->
             (match d.origin, d.issues with
              | Parsed_declaration, [] -> declared_category d.ui_category
              | Parsed_declaration, _ :: _ | Issue_only, ([] | _ :: _) -> Unverified)
         | [] | [_] | _ :: _ :: _ -> Unverified)
    | Some {complete=false; _} | None -> Unverified in
  match entry with
  | `Declaration (_, (d : declaration)) ->
      trusted_declaration ~id:d.installation_id ~path:d.source_path
  | `Instance (i : instance) ->
      match i.installation_id, i.source_path with
      | Some id, Some path -> trusted_declaration ~id:(Some id) ~path
      | None, None -> declared_category i.ui_category
      | Some _, None | None, Some _ -> Unverified
let category_rank = function
  | Classified Category.Memory_and_judgment -> 0
  | Classified Category.Browser -> 1
  | Classified Category.External_communications -> 2
  | Classified Category.Voice_and_media -> 3
  | Classified Category.Execution_environment -> 4
  | Classified Category.Analysis -> 5
  | Unclassified -> 6
  | Unverified -> 7
let category_heading = function
  | Classified c -> category_label c
  | Unclassified -> "Unclassified"
  | Unverified -> "Category unverified"
(* Current installations are grouped by role; within a group the order is the
   raw order, so identity-based cursor anchors stay stable. Retained runs keep
   their run grouping. *)
let overview_entries ?(mode=Current_installations) snapshot =
  let entries = overview_entries_raw ~mode snapshot in
  match mode with
  | Retained_runs -> entries
  | Current_installations ->
      List.stable_sort (fun a b ->
        Int.compare (category_rank (current_category snapshot a)) (category_rank (current_category snapshot b))) entries
let overview_count ?(mode=Current_installations) snapshot = List.length (overview_entries ~mode snapshot)
let selectable_overview_entries view snapshot =
  let entries = overview_entries ~mode:view.overview_mode snapshot in
  if view.presentation=Flow then
    List.filter (function `Instance _ -> true | `Declaration _ -> false) entries
  else entries
let move_instance view delta =
  match view.snapshot with
  | None -> view
  | Some snapshot ->
      let count = List.length (selectable_overview_entries view snapshot) in
      let instance_cursor = if count=0 then -1
        else max 0 (min (count - 1) (view.instance_cursor + delta)) in
      {view with instance_cursor; scroll=0}
let overview_anchor = function
  | `Instance (instance : instance) -> Worker_anchor (instance.id, instance.incarnation)
  | `Declaration (_, declaration) -> Declaration_anchor (declaration.source_path, declaration.installation_id)
let select_overview_anchor view selected =
  let instance_cursor = Option.bind selected (fun anchor ->
    Option.bind view.snapshot (fun snapshot ->
      List.find_index (fun entry -> overview_anchor entry=anchor)
        (selectable_overview_entries view snapshot)))
    |> Option.value ~default:(-1) in
  {view with instance_cursor}
let set_presentation view presentation =
  if view.presentation=presentation then view else
  (* Detail keeps its pinned screen identity, but also retains the original
     hidden list target when the operator returns from it to Overview. *)
  let selected = Option.bind view.snapshot (fun snapshot ->
    Option.map overview_anchor
      (at_cursor (selectable_overview_entries view snapshot) view.instance_cursor)) in
  select_overview_anchor {view with presentation} selected
let toggle_history view = match view.screen with
  | Detail _ -> view
  | Overview ->
      let view = set_presentation view Summary in
      let entries mode = Option.fold ~none:[] ~some:(overview_entries ~mode) view.snapshot in
      let saved = match at_cursor (entries view.overview_mode) view.instance_cursor with
        | None -> No_selection | Some entry -> Selection (overview_anchor entry) in
      let overview_mode, current_selection, history_selection, restore = match view.overview_mode with
        | Current_installations -> Retained_runs, saved, view.history_selection, view.history_selection
        | Retained_runs -> Current_installations, view.current_selection, saved, view.current_selection in
      let instance_cursor = match restore with
        | Unvisited -> if entries overview_mode=[] then -1 else 0
        | No_selection -> -1
        | Selection anchor ->
            List.find_index (fun entry -> overview_anchor entry=anchor) (entries overview_mode)
            |> Option.value ~default:(-1) in
      {view with overview_mode;current_selection;history_selection;instance_cursor;scroll=0;selected=[];
        focus=Instances;document_key=None}
let selected_document view = Option.bind view.document_key (fun key ->
  List.find_opt (fun (s : Document.session) -> s.file_name = key) view.documents)
let put_document view (document : Document.session) =
  (* The records overlay edits its own copy of the draft. A stored session
     whose text moved on without it — a reload, a revision switch, an
     external edit — leaves the overlay showing another text, so only an
     unchanged text keeps it open. *)
  let records = match view.records with
    | Some overlay when String.equal (Masc_tui_lane_records.title overlay) document.file_name
                        && String.equal (Masc_tui_lane_records.text overlay) document.text -> view.records
    | Some _ | None -> None in
  {view with documents=document :: List.filter (fun (s : Document.session) -> s.file_name <> document.file_name) view.documents;
    document_key=Some document.file_name; records}
let selected_row view = Option.bind view.snapshot (fun snapshot ->
  List.find_map (fun (index, row) ->
    let selectable = match view.screen, view.presentation, view.focus with
      | Detail _, Summary, (Timeline | Instances) ->
          Option.fold ~none:false ~some:(fun item -> row_is_result item row)
            (detail_instance view snapshot)
      | (Overview | Detail _), Flow, _ -> false
      | Overview, (Summary | Technical), _ | Detail _, Technical, _
      | Detail _, Summary, (Rows | Connections | Configurations) -> true in
    if index = view.row_cursor && selectable then Some row else None)
    (rows_in_screen view snapshot))
let reconcile_snapshot view snapshot =
  let locate key items wanted =
    let rec loop index = function
      | [] -> -1
      | item :: rest -> if key item = wanted then index else loop (index + 1) rest in
    loop 0 items in
  let declarations snapshot = Option.fold ~none:[]
      ~some:(fun (configuration : configuration) -> configuration.declarations) snapshot.configuration in
  let anchor key old_items new_items cursor =
    match at_cursor old_items cursor with
    | None -> -1
    | Some item -> locate key new_items (key item) in
  match view.snapshot with
  | None -> {view with snapshot=Some snapshot;scroll=0}
  | Some previous ->
      let row_cursor = anchor (fun (row : Row.row) -> row.id)
          previous.output.rows snapshot.output.rows view.row_cursor in
      let owner_identity instances row = Option.bind row (row_owner instances)
          |> Option.map (fun (instance : instance) -> instance.id, instance.incarnation) in
      let row_cursor =
        if owner_identity previous.instances (selected_row view)
           = owner_identity snapshot.instances (at_cursor snapshot.output.rows row_cursor)
        then row_cursor else -1 in
      let configuration_cursor = anchor (fun (declaration : declaration) -> declaration.source_path)
          (declarations previous) (declarations snapshot) view.configuration_cursor in
      let declaration_owner snapshot cursor =
        Option.map (fun (declaration : declaration) ->
          let worker = Option.bind declaration.instance_id (fun id ->
            List.find_opt (fun (instance : instance) -> instance.id=id) snapshot.instances)
            |> Option.map (fun (instance : instance) -> instance.id, instance.incarnation, instance.run_id) in
          declaration.installation_id, declaration.instance_id, worker)
          (at_cursor (declarations snapshot) cursor) in
      let configuration_cursor =
        if declaration_owner previous view.configuration_cursor = declaration_owner snapshot configuration_cursor
        then configuration_cursor else -1 in
      (* A vanished identity leaves no selection. Selecting a replacement is
         an explicit navigation action, never a side effect of a refresh. *)
      let previous_entries = selectable_overview_entries view previous in
      let entries = selectable_overview_entries view snapshot in
      let instance_cursor =
        if previous_entries=[] && entries<>[] then 0
        else anchor overview_anchor previous_entries entries view.instance_cursor in
      {view with snapshot=Some snapshot; row_cursor; instance_cursor;
        configuration_cursor}
let selected_instance view = Option.bind view.snapshot (fun snapshot ->
  match view.screen with
  | Detail (id, incarnation) ->
      List.find_opt (fun (instance : instance) ->
        String.equal instance.id id && String.equal instance.incarnation incarnation) snapshot.instances
  | Overview ->
      (match view.focus with
       | Configurations when view.presentation=Technical || Option.is_some view.document_key -> Option.bind (selected_declaration view) (fun declaration ->
           Option.bind declaration.instance_id (fun id ->
             List.find_opt (fun (instance : instance) ->
               instance.id=id && (match view.overview_mode with
                 | Current_installations -> not (retained instance)
                 | Retained_runs -> true)) snapshot.instances))
       | Timeline | Rows | Configurations | Connections | Instances ->
           (match at_cursor (selectable_overview_entries view snapshot) view.instance_cursor with
            | Some (`Instance item) -> Some item | Some (`Declaration _) | None -> None)))
let ordered_rows view snapshot =
  rows_in_screen view snapshot
  |> List.stable_sort (fun (_, (a : Row.row)) (_, (b : Row.row)) ->
    let time = Float.compare a.observed_at b.observed_at in
    if time=0 then String.compare a.id b.id else time)
let toggle_flow view =
  let presentation = if view.presentation=Flow then Summary else Flow in
  { (set_presentation view presentation) with
    focus=(if view.screen=Overview then Instances else view.focus);
    document_key=None; scroll=0}
(* Presentation readings identify user-facing results. Supporting context
   records stay available in Records and raw details without becoming result
   navigation targets. Packages without readings retain their generic view. *)
let ordered_result_rows view snapshot =
  let rows = ordered_rows view snapshot in
  match view.screen, detail_instance view snapshot with
  | Detail _, Some item ->
      (* Grouped by Lane in the order Left/Right and the activity timeline
         use, and by time within a Lane, so j/k walks the list the Results
         pane draws. *)
      List.filter (fun (_, row) -> row_is_result item row) rows
      |> List.stable_sort (fun (_, (a : Row.row)) (_, (b : Row.row)) ->
           compare_result_lanes [item] a.lane_id b.lane_id)
  | Overview, _ | Detail _, _ -> rows
let select_initial_result view =
  match view.snapshot, selected_instance view with
  | Some snapshot, Some _ ->
      let row_cursor = match ordered_result_rows view snapshot with
        | (index, _) :: _ -> index
        | [] -> -1 in
      {view with row_cursor}
  | _ -> view
let open_selected_instance view =
  match view.snapshot with
  | None -> view
  | Some snapshot ->
      match at_cursor (selectable_overview_entries view snapshot) view.instance_cursor with
      | Some (`Declaration (index, _)) ->
          { (set_presentation view Technical) with focus=Configurations; configuration_cursor=index;
            scroll=0; selected=[]; document_key=None}
      | Some (`Instance item) ->
          select_initial_result {view with screen=Detail (item.id,item.incarnation); focus=Timeline;
            scroll=0; selected=[]; document_key=None}
      | None -> view
(* Opening a declaration from the Lane inventory shows its document. The
   cursor has to name the same declaration: every action that reads
   [selected_declaration] -- detach, observe, add -- reaches the row the
   cursor names, and a cursor left on another row would act on that one
   while this document is on screen. A declaration the snapshot does not
   list, or no snapshot yet, names no row. *)
let open_declaration view path =
  let configuration_cursor =
    Option.bind view.snapshot (fun snapshot ->
      Option.bind snapshot.configuration (fun (configuration : configuration) ->
        List.find_index (fun (declaration : declaration) -> declaration.source_path = path)
          configuration.declarations))
    |> Option.value ~default:(-1)
  in
  let current_selection =
    Option.bind view.snapshot (fun snapshot ->
      Option.bind snapshot.configuration (fun config ->
        Option.map (fun (declaration : declaration) ->
          Selection (Declaration_anchor (declaration.source_path, declaration.installation_id)))
          (at_cursor config.declarations configuration_cursor)))
    |> Option.value ~default:No_selection in
  { (set_presentation view Technical) with screen=Overview; focus=Configurations; configuration_cursor;
    current_selection;
    scroll=0; error=None; editor_ready=false}
let evidence_target view =
  let* snapshot = Option.to_result ~none:"Observation snapshot unavailable" view.snapshot in
  let* () = if view.selected=[] then Error "Select evidence rows first" else Ok () in
  let rec owners = function
    | [] -> Ok []
    | id::rest ->
        let* row = Option.to_result ~none:"Selected evidence is outside the current view; select again"
          (List.find_map (fun (_, (row : Row.row)) -> if row.id=id then Some row else None)
            (rows_in_screen view snapshot)) in
        let* owner = Option.to_result ~none:"Selected evidence owner unavailable"
          (row_owner snapshot.instances row) in
        let* rest=owners rest in Ok (owner::rest) in
  let* owners=owners view.selected in
  match List.sort_uniq (fun (a : instance) (b : instance) -> String.compare a.id b.id) owners with
  | [owner] -> Ok (owner, `Assoc ["instance_id",`String owner.id;
      "row_ids",`List (List.sort String.compare view.selected |> List.map (fun id -> `String id))])
  | _ -> Error "Selected evidence spans multiple instances; select one owner at a time"
let evidence_request view =
  let* _, evidence = evidence_target view in Ok (Evidence evidence)
let open_evidence ~request_id ~keepers view =
  let* owner, evidence = evidence_target view in
  let broadcast_request_id = match List.find_opt (fun (previous,_) -> Yojson.Safe.equal previous evidence) view.pending_broadcasts with
    | Some (_, id) -> id | None -> request_id in
  Ok {view with evidence_prompt=Some {evidence;owner_title=owner.title;
    row_count=List.length view.selected;keepers=List.sort_uniq String.compare keepers;choice=0;broadcast_request_id};
    error=None;scroll=0}
let move_evidence view delta = match view.evidence_prompt with
  | None -> view
  | Some prompt ->
      let choice = max 0 (min (List.length prompt.keepers + 1) (prompt.choice + delta)) in
      {view with evidence_prompt=Some {prompt with choice}}
let evidence_keeper prompt = if prompt.choice=0 then None else List.nth_opt prompt.keepers (prompt.choice-1)
let submit_evidence view = match view.evidence_prompt with
  | None -> Error "No evidence export is open"
  | Some prompt ->
      let fields = match prompt.evidence with `Assoc fields -> fields | _ -> [] in
      let request = if prompt.choice=List.length prompt.keepers + 1
        then `Assoc (fields @ ["broadcast",`Bool true;"request_id",`String prompt.broadcast_request_id])
        else match evidence_keeper prompt with
          | None -> prompt.evidence
          | Some keeper -> `Assoc (fields @ ["keeper_name",`String keeper]) in
      let pending_broadcasts = if prompt.choice=List.length prompt.keepers + 1 then
        (prompt.evidence,prompt.broadcast_request_id) :: List.filter
          (fun (_,id) -> not (String.equal id prompt.broadcast_request_id)) view.pending_broadcasts
        else view.pending_broadcasts in
      Ok ({view with evidence_prompt=None;pending_broadcasts}, Evidence request)
let acknowledge_broadcast view receipt =
  match get (field "request_id") "delivery" receipt, get (field "status") "delivery" receipt with
  | Ok (`String request_id), Ok (`String "committed") ->
      {view with pending_broadcasts=List.filter
        (fun (_,id) -> not (String.equal id request_id)) view.pending_broadcasts}
  | (Ok _ | Error _), (Ok _ | Error _) -> view
let evidence_lines prompt =
  let choice index label = (if prompt.choice=index then "> " else "  ") ^ label in
  [Printf.sprintf "Preserve %d marked row%s from %s" prompt.row_count
     (if prompt.row_count=1 then "" else "s") prompt.owner_title;
   "Evidence stays preserved; sharing sends its reference. Reads and actions are separate.";
   "An unanswered Broadcast retries the original saved send, including after restart.";
   "j/k:choose  Enter:preserve  Esc:back"]
  @ [choice 0 "Preserve only"]
  @ List.mapi (fun index keeper -> choice (index+1) ("Preserve and send the reference to " ^ keeper)) prompt.keepers
  @ [choice (List.length prompt.keepers+1) "Preserve and share the reference via Broadcast"]
(* The receipt names what was frozen and, separately, whether the optional
   message reached its Keeper. A failed delivery leaves the bundle preserved. *)
let evidence_receipt_lines json =
  let member key = function `Assoc fields -> List.assoc_opt key fields | _ -> None in
  match member "evidence" json with
  | None -> []
  | Some evidence ->
      let text value = match value with Some (`String s) -> Some s | _ -> None in
      let count = match member "row_count" json with Some (`Int n) -> Printf.sprintf "%d row%s" n (if n=1 then "" else "s") | _ -> "rows" in
      let frozen = "Evidence preserved: " ^ count
        ^ (match text (member "sha256" evidence) with Some sha -> " · sha256 " ^ sha | None -> "") in
      let selection = Option.fold ~none:[] ~some:(fun id -> ["Evidence owner: " ^ id])
          (text (member "instance_id" json))
        @ (match member "row_ids" json with
           | Some (`List ids) -> List.filter_map (fun id ->
               Option.map (fun id -> "Selected row: " ^ id) (text (Some id))) ids
           | Some _ | None -> []) in
      let delivery = match member "delivery" json with
        | None -> ["Not shared."]
        | Some delivery ->
            let destination = match text (member "destination" delivery) with
              | Some "broadcast" -> "Broadcast"
              | _ -> "Keeper delivery" ^ Option.fold ~none:"" ~some:(fun name -> " to " ^ name)
                  (text (member "keeper_name" delivery)) in
            (match text (member "status" delivery), text (member "error" delivery) with
             | Some "failed", Some error -> [destination ^ " failed: " ^ error ^ " · the bundle stays preserved"]
             | Some "pending_commit", _ -> [destination ^ " queued · workspace commit is pending; retry uses the same request"]
             | Some "outcome_unknown", _ -> [destination ^ " outcome unknown · evidence preserved; verify before resending"]
             | Some "committed", _ -> [destination ^ " committed · Keeper reads and actions are unverified"]
             | Some "accepted", _ -> [destination ^ " accepted · Keeper reads and actions are unverified"]
             | Some status, _ -> [destination ^ " " ^ status]
             | None, _ -> [destination ^ " status unknown"]) in
      frozen :: selection @ delivery
let selected_source_path view =
  Option.bind view.snapshot (fun snapshot ->
    Option.bind snapshot.configuration (fun config ->
      let instance_path = Option.bind (selected_instance view) (fun instance ->
        List.find_map (fun (d : declaration) ->
          if d.instance_id=Some instance.id && Some d.source_path=instance.source_path
          then Some d.source_path else None) config.declarations) in
      let path = match view.focus, view.screen with
        | (Configurations, Overview) | (Configurations, Detail (_, _)) -> Option.map (fun (d : declaration) -> d.source_path) (selected_declaration view)
        | Instances, Overview ->
            (match at_cursor (selectable_overview_entries view snapshot) view.instance_cursor with
             | Some (`Declaration (_, declaration)) -> Some declaration.source_path
             | Some (`Instance _) | None -> instance_path)
        | ((Timeline | Connections | Rows), Overview)
        | ((Timeline | Connections | Instances | Rows), Detail (_, _)) -> instance_path in
      Option.bind path (fun path ->
        if Document.editable_source_path ~directory:config.directory path then Some path else None)))
let subscription_targets view =
  match view.snapshot with
  | Some {configuration=Some config;instances;_} when config.complete ->
      List.concat_map (fun (declaration:declaration) ->
        match declaration.installation_id,declaration.instance_id with
        | Some installation_id,Some id when declaration.issues=[] ->
            (match List.find_opt (fun (instance:instance) -> instance.id=id
                && instance.source_path=Some declaration.source_path
                && (match instance.phase with
                  | Row.Attached | Row.Observing -> true
                  | Row.Failed _ | Detaching | Detached -> false)) instances with
             | None -> []
             | Some instance -> List.map (fun (output_id,_) ->
                 ({installation_id;run_id=instance.run_id;output_id;instance_id=instance.id;title=instance.title}
                  : Masc_tui_lane_subscriptions.target)) instance.outputs)
        | _ -> []) config.declarations
  | _ -> []
let phase_label = function
  | Row.Attached -> "attached" | Row.Observing -> "observing" | Row.Detaching -> "detaching"
  | Row.Detached -> "detached" | Row.Failed detail -> "failed: " ^ detail
let utc_stamp time =
  try let t=Unix.gmtime time in
    Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d.%03d"
      (t.Unix.tm_year+1900) (t.Unix.tm_mon+1) t.Unix.tm_mday
      t.Unix.tm_hour t.Unix.tm_min t.Unix.tm_sec
      (int_of_float ((time -. floor time)*.1000.))
  with Unix.Unix_error _ | Invalid_argument _ -> Printf.sprintf "epoch %.6g" time
let timeline_lines ~instances ?selected ~width rows =
  match rows with
  | [] -> List.map (fun instance -> instance.title ^ " | " ^ phase_label instance.phase
      ^ " | no observations in this view") instances
  | first :: rest ->
      let first : Row.row = first in
      let since, until = List.fold_left (fun (a, b) (row : Row.row) ->
        min a row.observed_at, max b row.observed_at) (first.observed_at, first.observed_at) rest in
      let lanes = (List.map (fun (row : Row.row) -> row.lane_id) rows
        @ List.concat_map (fun instance -> List.concat_map (fun (_,selection) ->
            match selection with Row.All_lanes -> []
            | Row.Selected_lanes lanes -> List.map (fun lane -> instance.id ^ "/" ^ lane) lanes) instance.outputs) instances)
        |> List.sort_uniq (compare_result_lanes instances) in
      (* A lane id is "<instance id>/<lane>". The detail screen draws one
         instance, which its heading already names, so a lane is labelled by
         the part after the slash and the label column is as wide as the
         widest label, up to a cap. *)
      let local lane =
        match String.index_opt lane '/' with
        | Some separator when separator > 0 ->
            String.sub lane (separator + 1) (String.length lane - separator - 1)
        | _ -> lane in
      let label_width = List.fold_left (fun widest lane ->
          max widest (Masc_tui_message_layout.display_width (local lane))) 1 lanes
        |> min (min 28 (max 8 (width / 3))) in
      let axis_width = max 2 (width - label_width - 4) in
      let label lane = Masc_tui_message_layout.fit_width (local lane) label_width in
      let position time = if since = until then axis_width / 2 else
        let span = until -. since in
        let fraction = if Float.is_finite span then (time -. since) /. span
          else (time /. 2. -. since /. 2.) /. (until /. 2. -. since /. 2.) in
        max 0 (min (axis_width - 1) (int_of_float (fraction *. float_of_int (axis_width - 1)))) in
      [Printf.sprintf "Wall time %s UTC"
         (if since = until then utc_stamp since
          else utc_stamp since ^ " → " ^ utc_stamp until)]
      @ List.map (fun lane ->
          let axis = Bytes.make axis_width '-' in
          List.iter (fun (row : Row.row) -> if row.lane_id = lane then
            Bytes.set axis (position row.observed_at) (match row.kind with Row.Event -> 'o' | Row.Value -> 'v' | Row.Relation -> '*')) rows;
          (match selected with Some (row : Row.row) when row.lane_id=lane -> ">" | _ -> " ")
          ^ label lane ^ " |" ^ Bytes.to_string axis ^ "|") lanes
      @ ["o event · v value · * relation"]
      @ List.filter_map (fun instance ->
          if List.exists (fun (row : Row.row) ->
            String.starts_with ~prefix:(instance.id ^ "/") row.lane_id) rows then None
          else Some (instance.title ^ " | " ^ phase_label instance.phase ^ " | no observations in this view")) instances
let track_application view target =
  match Application.value view.application_reading with
  | None -> Application.Unavailable "Waiting for an application observation"
  | Some (Error detail) -> Application.Unavailable detail
  | Some (Ok configuration) ->
      (* The server folds a parsed declaration's issues into its own application
         observation, which a complete inventory reports as Failed. Only a file
         that has no observation, because it could not be parsed, answers with
         its raw issues. *)
      let issues = List.concat_map (fun (d : declaration) ->
        match d.application with
        | Some _ -> []
        | None ->
            if d.source_path=target.Application.source_path
               || d.installation_id=Some target.installation_id then d.issues else []) configuration.declarations in
      if issues <> [] then Application.Unavailable (String.concat "; " issues)
      else Application.track ~target ~complete:configuration.complete
        (List.filter_map (fun (d : declaration) -> d.application) configuration.declarations)
let declaration_application view (declaration : declaration) =
  match declaration.application with
  | None -> "Application unknown · declaration could not be read"
  | Some observation -> Application.describe (track_application view observation.target)
let document_application_lines view session =
  ["Accepted file application · " ^ (match Document.application_target session with
    | Error detail -> Application.describe (Application.Unavailable detail)
    | Ok target -> Application.describe (track_application view target));
   (if Application.pending view.application_reading then "Refreshing application · draft remains editable"
    else "Application follows visible-pane refresh · r:read now")]
let configuration_lines view snapshot = match snapshot.configuration with
  | None -> ["TOML configuration status unknown"]
  | Some config ->
      ["TOML installations · " ^ config.directory ^ (if config.complete then " · inventory complete" else " · inventory partial")]
      @ List.concat (List.mapi (fun index (declaration : declaration) ->
        [Printf.sprintf "%s %s · %s" (if view.configuration_cursor=index then ">" else " ")
           (Option.value ~default:"unresolved installation" declaration.installation_id) declaration.source_path;
         (match declaration.enabled with
          | Some false -> "   Configured off"
          | Some true -> "   Configured on"
          | None -> "   Desired activity unknown");
         "   " ^ declaration_application view declaration;
         "   desired " ^ Option.value ~default:"unknown" declaration.desired;
         "   applied " ^ Option.value ~default:"none" declaration.applied]
        @ (if Document.editable_source_path ~directory:config.directory declaration.source_path then []
           else ["   Configuration issue; no declaration file to edit"])
        @ List.map (fun message -> "   Error: " ^ message) declaration.issues) config.declarations)
type technical_part =
  | Technical_text of string
  | Technical_json of { value : Yojson.Safe.t; indent : int }

let technical_text lines = List.map (fun line -> Technical_text line) lines

let evidence_text (evidence : Row.evidence) =
  "Evidence " ^ evidence.uri ^ " · sha256 " ^ Option.value ~default:"unknown" evidence.sha256

(* One document part as screen rows. JSON is code: it takes the code gutter
   and the lexer colours that every other JSON view draws. *)
let technical_rows ~width = function
  | Technical_text text -> document_rows ~width text
  | Technical_json {value;indent} ->
      let lines = Yojson.Safe.pretty_to_string value
        |> String.split_on_char '\n'
        |> List.map Masc.Tui_terminal_text.sanitize_terminal_text in
      let source = String.concat "\n" lines in
      (* The gutter and indentation must not take space from a grapheme
         that would otherwise fit in the pane. *)
      let palette = Masc_tui_markdown_theme.palette ~closing:"" in
      let gutter = Masc_tui_message_layout.display_width palette.code_gutter in
      let widest = List.fold_left (fun widest line ->
        max widest (Masc_tui_message_layout.widest_grapheme_cells line)) 0 lines in
      if width < gutter + widest then document_rows ~width source
      else
        let indent = min indent (width - gutter - widest) in
        Masc_tui_markdown_theme.code ~language:"json" ~width:(width - indent) source
        |> List.map (fun line -> String.make indent ' ' ^ line)

let instance_parts view instances =
  List.concat (List.mapi (fun i item ->
    technical_text [Printf.sprintf "%s %s · %s · %s · run %s · rev %s · seq %d · rows %d"
       (if view.instance_cursor=i then ">" else " ") item.id item.title (phase_label item.phase)
       item.run_id item.revision item.observation_seq item.rows_count;
     "   TOML " ^ Option.value ~default:"manual attachment" item.source_path;
     "   binding"]
    @ [Technical_json {value=item.binding;indent=5}]
    @ technical_text (List.map (fun (id, selection) -> "   output " ^ id ^ " → " ^ (match selection with
      | Row.All_lanes -> "all supplied lanes" | Row.Selected_lanes lanes -> String.concat ", " lanes)) item.outputs)
    @ technical_text (match item.skills_directory with None -> [] | Some directory -> ["   Skills " ^ directory])
    @ (match item.action_schema with None -> [] | Some schema ->
        [Technical_text ("   action schema · incarnation " ^ item.incarnation);
         Technical_json {value=schema;indent=5}])) instances)
let action_parts view = match view.last_action with
    | None -> []
    | Some request -> technical_text ["Action request " ^ request.request_id ^ " · t:read status (never replays)";
        "  instance " ^ request.instance_id ^ " · incarnation " ^ request.incarnation]
        @ (match view.action_receipt with
          | None -> technical_text ["  receipt unknown; t queries this exact request"]
          | Some receipt -> technical_text ["  state " ^ (match receipt.Action.state with
              | Action.Queued -> "queued" | Action.Running -> "running" | Action.Confirmed -> "confirmed"
              | Action.Failed_before_effect -> "failed_before_effect" | Action.Outcome_unknown -> "outcome_unknown");
              "  requester " ^ receipt.requester ^ " · executor " ^ Option.fold ~none:"unknown" ~some:Masc.Lane_addon_lifecycle.resource_to_string receipt.executor]
              @ technical_text (match receipt.detail with None -> [] | Some detail -> ["  " ^ detail])
              @ (match receipt.result with None -> [] | Some result -> [Technical_json {value=result;indent=0}]))
let action_lines view =
  List.concat_map (function
    | Technical_text text -> [text]
    | Technical_json {value;indent} ->
        String.split_on_char '\n' (Yojson.Safe.pretty_to_string value)
        |> List.map (fun line -> String.make indent ' ' ^ line)) (action_parts view)
let move_observation view delta =
  match view.snapshot with
  | None -> view
  | Some snapshot ->
      let rows = ordered_result_rows view snapshot in
      let rec find position = function
        | [] -> -1
        | (index, _) :: rest -> if index=view.row_cursor then position else find (position+1) rest in
      let position = max 0 (min (List.length rows-1) (find 0 rows + delta)) in
      match List.nth_opt rows position with
      | None -> view
      | Some (row_cursor, _) -> {view with row_cursor;scroll=0;document_key=None}
let move_record view delta =
  match view.snapshot with
  | None -> view
  | Some snapshot ->
      let rows = ordered_rows view snapshot in
      let rec find position = function
        | [] -> -1
        | (index, _) :: rest -> if index=view.row_cursor then position else find (position+1) rest in
      let position = max 0 (min (List.length rows-1) (find 0 rows + delta)) in
      match List.nth_opt rows position with
      | None -> view
      | Some (row_cursor, _) -> {view with row_cursor;scroll=0;document_key=None}
let move_lane view delta =
  match view.snapshot, selected_row view with
  | Some snapshot, Some row ->
      let rows = match view.focus with
        | Timeline | Instances -> ordered_result_rows view snapshot
        | Rows | Connections | Configurations -> ordered_rows view snapshot in
      let lanes = rows
        |> List.map (fun (_, (row : Row.row)) -> row.lane_id)
        |> List.sort_uniq (compare_result_lanes snapshot.instances) in
      let rec find index = function [] -> 0 | lane :: rest ->
        if lane=row.lane_id then index else find (index+1) rest in
      let index = max 0 (min (List.length lanes-1) (find 0 lanes + delta)) in
      (match List.nth_opt lanes index with
       | None -> view
       | Some lane ->
           let candidates = List.filter (fun (_, (candidate : Row.row)) -> candidate.lane_id=lane) rows in
           let target = match List.find_opt (fun (_, (candidate : Row.row)) -> candidate.observed_at>=row.observed_at) candidates with
             | Some _ as target -> target
             | None -> List.nth_opt candidates (List.length candidates-1) in
           match target with
           | None -> view
           | Some (row_cursor, _) -> {view with row_cursor;scroll=0;document_key=None})
  | _ -> view
(* Nothing asked for yet, so the operator's next step is to ask. The status
   row and the body under it both say this. *)
let no_reading_yet_text = "No reading yet · r:refresh"

let diagnostic_text = function
  | Detail_read_failure detail -> "Detail read: " ^ detail
  | Request_failure detail -> "Request: " ^ detail
  | Input_failure detail -> "Input: " ^ detail

let detail_read_note view =
  match view.screen, view.detail_read_error with
  | Detail (id, incarnation), Some (owner, epoch, detail)
      when id=owner && incarnation=epoch ->
      Some ("Results read failed: " ^ detail
        ^ " · previous rows, if any, retained · r:retry")
  | (Overview | Detail _), (Some _ | None) -> None

let previous_read_note (view : t) =
  match view.snapshot_read_error, view.error with
  | Some detail, Some (Detail_read_failure _ | Request_failure _ | Input_failure _) ->
      Some ("Previous Plugins read: " ^ detail)
  | (Some _ | None), None | None, Some _ -> None

let diagnostic_lines view =
  Option.to_list (Option.map diagnostic_text view.error)
  @ (match view.snapshot_read_error, view.error with
     | Some detail, None -> ["Read: " ^ detail]
     | Some _, Some _ -> Option.to_list (previous_read_note view)
     | None, (Some _ | None) -> [])
  @ Option.to_list (detail_read_note view)

(* What the body says while the view holds no reading. It used to say
   [no_reading_yet_text] under a status row reading "Reading · nothing held
   yet", telling the operator to press [r] for a read already on its way; the
   list screens said "Refreshing…" over a first read that refreshes nothing. *)
let unread_body_text ~failed_note (view : t) =
  match view.error, view.snapshot_read_error, view.loading with
  | Some _, _, (true | false) | None, Some _, (true | false) -> failed_note
  | None, None, true -> "Reading…"
  | None, None, false -> no_reading_yet_text

(* What the status row says about a read or interaction. Kept whole here rather than
   inside the row it draws, so a view can be asked what the row would say.

   The row used to match on [loading] alone, so a read in flight claimed a
   previous reading whatever the view held: a first read said one remained
   visible while the rows under it said "No reading yet" in the same frame. *)
let status_text (view : t) =
  let current = match view.loading, view.snapshot, view.error, view.snapshot_read_error with
  | true, Some _, Some diagnostic, _ ->
      diagnostic_text diagnostic ^ " · previous reading remains visible"
  | false, Some _, Some diagnostic, _ -> diagnostic_text diagnostic
  | true, Some _, None, Some detail ->
      "Read: " ^ detail ^ " · previous reading remains visible"
  | false, Some _, None, Some detail ->
      "Read: " ^ detail ^ " · previous reading retained"
  | true, Some _, None, None -> "Refreshing · previous reading remains visible"
  (* A read that failed and is being tried again holds nothing either, and
     the failure is the part an operator can act on. *)
  | true, None, Some diagnostic, _ ->
      diagnostic_text diagnostic ^ " · request in progress"
  | false, None, Some diagnostic, _ -> diagnostic_text diagnostic
  | true, None, None, Some detail -> "Read: " ^ detail ^ " · reading again"
  | false, None, None, Some detail -> "Read: " ^ detail
  | true, None, None, None -> "Reading · nothing held yet"
  | false, None, None, None -> no_reading_yet_text
  | false, Some _, None, None -> "Recorded observations · r:refresh"
  in
  String.concat " · "
    (current :: Option.to_list (previous_read_note view)
     @ Option.to_list (detail_read_note view))

(* Enumerate only values explicitly closed by the package's schema. Required
   open-ended fields have no invented default and use the advanced command. *)
let rec finite_values = function
  | `Assoc fields ->
      (match List.assoc_opt "const" fields, List.assoc_opt "enum" fields with
       | Some value, _ -> Some [value]
       | None, Some (`List values) -> Some values
       | _ ->
           match List.assoc_opt "type" fields,
                 List.assoc_opt "properties" fields,
                 List.assoc_opt "required" fields with
           | Some (`String "object"), Some (`Assoc properties), Some (`List required)
             when List.length properties=List.length required ->
               let rec expand = function
                 | [] -> Some [[]]
                 | `String key :: rest ->
                     let values = Option.bind (List.assoc_opt key properties) finite_values in
                     (match values, expand rest with
                      | Some values, Some tails ->
                          Some (List.concat_map (fun value ->
                            List.map (fun tail -> (key,value)::tail) tails) values)
                      | _ -> None)
                 | _ -> None
               in
               Option.map (List.map (fun fields -> `Assoc fields)) (expand required)
           | _ -> None)
  | _ -> None

let technical_lines ?(height=24) ?(failed_note = "") ~width view =
  let _ = height in
  let raw_row (row : Row.row) =
    technical_text ([row.title; "Row " ^ row.id; "Lane " ^ row.lane_id;
     "Observed " ^ utc_stamp row.observed_at ^ " UTC";
     "Subject " ^ row.subject_id]
    @ Option.to_list (Option.map (fun actor -> "Actor " ^ actor) row.actor)
    @ Option.to_list (Option.map (fun (clock : Row.clock) ->
        "Clock " ^ clock.domain ^ " · " ^ clock.value) row.clock))
    @ [Technical_json {value=`Assoc row.fields;indent=0}]
    @ technical_text (List.map evidence_text row.evidence
    @ (if row.related_ids=[] then []
       else ["Related " ^ String.concat ", " row.related_ids])) in
  let content = match view.snapshot with
    | None -> technical_text [unread_body_text ~failed_note view]
    | Some snapshot ->
        let selected = match view.screen with
          | Overview -> at_cursor (selectable_overview_entries view snapshot) view.instance_cursor
          | Detail _ -> Option.map (fun item -> `Instance item)
              (detail_instance view snapshot) in
        let worker = match selected with
          | Some (`Instance item) -> instance_parts {view with instance_cursor=0} [item]
          | Some (`Declaration _) | None -> [] in
        let declaration = match selected with
          | Some (`Declaration (_, item)) -> Some item
          | Some (`Instance _) | None ->
              if view.focus=Configurations then selected_declaration view else None in
        let configuration = match declaration, snapshot.configuration with
          | Some item, Some config ->
              configuration_lines {view with configuration_cursor=0}
                {snapshot with configuration=Some {config with declarations=[item]}}
          | None, _ when view.focus<>Configurations -> []
          | None, _ | _, None -> ["TOML installation selection unavailable"] in
        let rows = match view.screen, selected with
          | Overview, Some _ -> []
          | Overview, None -> snapshot.output.rows
          | Detail _, _ -> Option.to_list (selected_row view) in
        technical_text ["Raw details";
         "Snapshot " ^ (match snapshot.complete with
           | Some true -> "complete" | Some false -> "partial" | None -> "unknown")]
        @ (if rows=[] then [] else Technical_text "Records" :: List.concat_map raw_row rows)
        @ worker @ technical_text configuration
        @ technical_text (if snapshot.output.coverage=[] then [] else
             "Coverage" :: List.map (fun (source : Row.coverage) ->
               source.source_id ^ " · " ^ (if source.complete then "complete" else "partial")
               ^ " · incarnation " ^ source.incarnation
               ^ " · cursor " ^ Option.value ~default:"unknown" source.cursor
               ^ Option.fold ~none:"" ~some:(fun detail -> " · " ^ detail) source.detail)
               snapshot.output.coverage) in
  let receipt = match view.receipt with
    | None -> []
    | Some json ->
        technical_text (evidence_receipt_lines json @ ["Last receipt:"])
        @ [Technical_json {value=json;indent=0}] in
  let draft = match view.draft with
    | None -> []
    | Some text -> [(if view.naming then "New TOML filename: " else "Plugin command: ") ^ text] in
  let document = match selected_document view with
    | None -> [] | Some session -> document_application_lines view session @ Document.summary session in
  List.concat_map (technical_rows ~width)
    (technical_text (["?:help  Esc:back  J/K:scroll"] @ diagnostic_lines view)
     @ content @ technical_text (draft @ document) @ action_parts view @ receipt)

let installation_detail_lines ~width view =
  let wrap = document_rows ~width in
  let edit_hint = if Option.is_some (selected_source_path view) then "  E:edit TOML" else "" in
  let refresh_hint = if view.loading then "  Reading …" else "  r:refresh" in
  let body = match view.snapshot with
    | Some ({configuration=Some configuration;_} as snapshot) ->
        (match selected_declaration view with
         | Some declaration ->
             ["Installation details · " ^
                Option.value ~default:(Filename.basename declaration.source_path) declaration.installation_id;
              "Esc:back" ^ edit_hint ^ refresh_hint; ""]
             @ configuration_lines {view with configuration_cursor=0}
                 {snapshot with configuration=Some {configuration with declarations=[declaration]}}
         | None -> ["Installation selection changed · Esc:back" ^ refresh_hint])
    | _ -> ["Installation inventory unread · Esc:back" ^ refresh_hint] in
  List.concat_map wrap (diagnostic_lines view @ body)

let pending_action view =
  match view.last_action, view.action_receipt with
  | Some request, Some {Action.state=(Action.Queued | Action.Running);_} -> Some request
  | (None | Some _), None
  | None, Some {Action.state=(Action.Queued | Action.Running | Action.Confirmed
                              | Action.Failed_before_effect | Action.Outcome_unknown);_}
  | Some _, Some {Action.state=(Action.Confirmed | Action.Failed_before_effect
                                | Action.Outcome_unknown);_} -> None

let action_target view = selected_instance view

let can_observe (instance : instance) = match instance.runtime_presence with
  | Retained_binding | Presence_unknown -> false
  | Live_entry -> match instance.phase with
    | Row.Attached | Row.Observing | Row.Failed _ -> true
    | Row.Detaching | Row.Detached -> false

let removal_block_reason view (instance : instance) =
  let refusal detail = Some (detail ^ "; correct TOML or refresh before removal; nothing was removed.") in
  match instance.installation_id, instance.source_path, instance.configuration_revision with
  | None, None, _ -> None
  | Some id, Some path, Some revision ->
      (match view.snapshot with
       | Some {configuration=Some config;_} when config.complete ->
           let matches = List.filter (fun (d : declaration) ->
             d.origin=Parsed_declaration && d.installation_id=Some id) config.declarations in
           let conflicts = List.exists (fun (d : declaration) ->
             d.issues<>[] && d.installation_id=Some id) config.declarations in
           (match matches with
            | _ when conflicts -> refusal "Lane configuration identity has issues"
            | [d] when d.desired=Some revision -> None
            | [_] -> refusal "Lane configuration changed"
            | [] when List.exists (fun (d : declaration) -> d.source_path=path) config.declarations ->
                refusal "Lane declaration is invalid"
            | [] -> None
            | _ -> refusal "Lane configuration identity is ambiguous")
       | _ -> refusal "Lane configuration inventory is incomplete")
  | _ -> refusal "Lane configuration owner is incomplete"

let instance_controls view (instance : instance) =
  let removal = match removal_block_reason view instance with
    | Some reason -> "  " ^ reason
    | None -> match instance.source_path with
    | Some _ -> "  d:remove TOML + worker"
    | None -> "  d:remove worker" in
  match instance.phase with
  | Row.Attached | Row.Observing ->
      (if can_observe instance then
         "o:observe" ^ (if Option.is_some instance.action_schema then "  a:actions" else "")
       else "worker execution unavailable") ^ removal
  | Row.Detaching -> "worker cleanup pending"
  | Row.Detached -> "retained history · D:details"
  | Row.Failed _ ->
      (if can_observe instance then
         "o:retry observation" ^ (if Option.is_some instance.action_schema then "  a:actions" else "")
       else "worker execution unavailable") ^ removal

(* [drop_hint_items] drops whole items from the back. Keep the way out at
   the front so it remains easy to find even when the other hints give way. *)
let overview_hints view =
  if view.help_open then "Esc:close help"
  else if Option.is_some view.document_key then
    "?:help  Esc:back  Space:on/off draft  E:edit  R:records  s:save  l:reload  u/U:revision  Colon:palette  A:command"
  else match view.screen with
  | Overview when view.presentation=Technical && view.focus=Configurations
      && Option.is_none view.document_key ->
      "?:help  Esc:back"
      ^ (if Option.is_some (selected_source_path view) then "  E:edit TOML" else "")
      ^ "  Colon:palette  A:command"
      ^ (if view.loading then "  Reading …" else "  r:refresh")
  | Overview ->
      "?:help  Colon:palette  Esc:back  Enter:open  h:history/current  i:install  n:new  S:subs  A:command"
      ^ (if view.loading then "  Reading …" else "  r:refresh")
  | Detail _ ->
      "?:help  Colon:palette  Esc:back  A:command  1-4:section  Tab:next section  j/k:move  " ^
      (match selected_instance view with None -> "" | Some instance -> instance_controls view instance ^ "  ") ^
      "D:raw  J/K:scroll"
      ^ (if view.loading then "  Reading …" else "  r:refresh")

(* The advertised lane action tool, its name and its [action] property, the
   part the operator fills. The host checks a send under the package's tool
   name, so the screen checks under the same one. *)
let advertised_action (instance : instance) =
  let* () = if can_observe instance then Ok () else Error "This instance is unavailable for actions; D shows its state and retained evidence." in
  let* tool_name,schema = match instance.action_tool,instance.action_schema with
    | Some tool_name,Some schema -> Ok (tool_name,schema)
    | Some _,None | None,(Some _ | None) -> Error "This Plugin provides observations only. Press o to observe." in
  let* () = Action.validate_schema schema in
  let* action_schema =
    let* properties = field "properties" schema in
    field "action" properties in
  Ok (tool_name,schema,action_schema)

(* Installation details can own a worker independently of the overview
   cursor. The menu and the list it returns to keep that exact worker. *)
let with_menu view (instance : instance) menu =
  let view = select_overview_anchor (set_presentation view Summary)
      (Some (Worker_anchor (instance.id, instance.incarnation))) in
  {view with action_menu=Some menu;scroll=0;error=None}

let instance_menu ~request_id view (instance : instance) =
  let* tool_name,schema,action_schema = advertised_action instance in
  let* choices,form = match finite_values action_schema with
    | Some (_::_ as choices) -> Ok (choices,None)
    | Some [] | None ->
        let* form = Masc_tui_schema_form.create ~schema:action_schema ~initial:(`Assoc []) in
        Ok ([],Some form) in
  let choices = List.filter (fun action ->
    Result.is_ok (Action.validate ~schema ~name:tool_name
      (Action.arguments ~instance_id:instance.id ~request_id ~action))) choices in
  if choices=[] && Option.is_none form then Error "The advertised schema has no valid preset action. D shows details."
  else Ok (with_menu view instance {
      target_id=instance.id;target_incarnation=instance.incarnation;target_title=instance.title;request_id;
      tool_name;schema;choices;form;cursor=0;row=None})

(* RFC lane-row-offers-actions-filled-from-its-own-fields §2.6: the actions the
   row's lane declares, each with what this row gives it. Screens read this
   value; an unfillable action stays in it with its reasons. *)
let row_action_entries (instance : instance) (row : Row.row) =
  let rec pairs actions verdicts = match actions,verdicts with
    | action :: actions,verdict :: verdicts -> (action,verdict) :: pairs actions verdicts
    | [],_ | _,[] -> [] in
  match instance.action_tool,instance.action_schema,instance.row_actions with
  | Some tool_name,Some tool_schema,Some verdicts ->
      List.concat (List.mapi (fun index ((action : Masc.Lane_addon_presentation.row_action),verdict) ->
        if String.equal row.lane_id (instance.id ^ "/" ^ action.lane_id) then
          [{index;label=action.label;
            filled=Masc.Lane_addon_row_action.fill ~tool_name ~tool_schema verdict action (`Assoc row.fields)}]
        else []) (pairs instance.display.Masc.Lane_addon_presentation.actions verdicts))
  | Some _,Some _,None | Some _,None,(Some _ | None) | None,(Some _ | None),(Some _ | None) -> []

(* In an instance's details j/k choose a row, so [a] offers that row's actions
   to the instance that produced it. Elsewhere [a] acts on the selected
   instance as before. *)
let row_menu view = match view.screen,view.snapshot,selected_row view with
  | Detail _,Some snapshot,Some row ->
      Option.bind (row_owner snapshot.instances row) (fun owner ->
        match row_action_entries owner row with
        | [] -> None
        | entries -> Some (owner,row,entries))
  | (Overview | Detail _),_,_ -> None

let open_actions ~request_id view =
  match row_menu view with
  | Some (owner,row,entries) ->
      let* tool_name,schema,_ = advertised_action owner in
      Ok (with_menu view owner {
        target_id=owner.id;target_incarnation=owner.incarnation;target_title=owner.title;request_id;
        tool_name;schema;choices=[];form=None;cursor=0;
        row=Some (Row_list {row_id=row.id;row_title=row.title;entries})})
  | None ->
      let* instance = match action_target view with
        | Some instance -> Ok instance
        | None -> Error "Selected installation or event has no available worker; select an instance explicitly" in
      instance_menu ~request_id view instance

let move_action view delta =
  {view with scroll=0;action_menu=Option.map (fun menu ->
    let count = match menu.row with
      | Some (Row_list {entries;_}) -> List.length entries + 1
      | Some (Row_form _) | None -> List.length menu.choices in
    {menu with cursor=max 0 (min (count - 1) (menu.cursor+delta))}) view.action_menu}

let unfilled_text : Masc.Lane_addon_row_action.unfilled -> string = function
  | Not_offered refusal -> (match refusal with
      | Schema_shape_unsupported -> "the action schema has a shape row actions cannot use"
      | No_branch_accepts -> "no alternative of the action schema takes it"
      | Several_branches_accept branches ->
          "alternatives " ^ String.concat ", " (List.map (fun branch -> string_of_int (branch+1)) branches)
          ^ " all take it"
      | Member_not_in_branch member -> "the action has no member " ^ member
      | Fixed_value_rejected member -> "the action refuses the package value of " ^ member)
  | Row_value_absent {member;path} -> "this row has no " ^ String.concat "." path ^ " for " ^ member
  | Row_value_wrong_shape {member;path} -> "this row's " ^ String.concat "." path ^ " cannot give " ^ member
  | Row_value_rejected {member;detail} -> member ^ ": " ^ detail

(* Sending reads the row again. A row that left the snapshot, or now gives
   other values, does not send what the operator reviewed. *)
let row_still_gives snapshot (instance : instance) ~tool_name ~tool_schema ~row_id ~index ~locked =
  match List.find_opt (fun (row : Row.row) -> String.equal row.id row_id) snapshot.output.rows with
  | None -> Error "The row is gone. Open its action again."
  | Some row ->
      let verdict = Option.bind instance.row_actions (fun verdicts -> List.nth_opt verdicts index) in
      (match List.nth_opt instance.display.Masc.Lane_addon_presentation.actions index,verdict with
       | Some action,Some verdict ->
           (match Masc.Lane_addon_row_action.fill ~tool_name ~tool_schema verdict action (`Assoc row.fields) with
            | Ok filled when filled.Masc.Lane_addon_row_action.locked=locked -> Ok ()
            | Ok _ | Error _ -> Error "The row changed. Open its action again.")
       | Some _,None | None,(Some _ | None) -> Error "The row changed. Open its action again.")

let submit_action view =
  let* menu = match view.action_menu with
    | Some menu -> Ok menu | None -> Error "Choose an action first." in
  let changed = "The selected Plugin changed. Refresh and choose its action again." in
  let* snapshot = Option.to_result ~none:changed view.snapshot in
  let* instance = match List.find_opt (fun instance -> String.equal instance.id menu.target_id
      && String.equal instance.incarnation menu.target_incarnation
      && instance.action_tool=Some menu.tool_name
      && instance.action_schema=Some menu.schema) snapshot.instances with
    | Some instance -> Ok instance
    | None -> Error changed in
  let* () = if can_observe instance then Ok ()
    else Error "The selected worker is no longer available for actions." in
  let* () = match menu.row with
    | None -> Ok ()
    | Some (Row_list _) -> Error "Choose one of the row's actions first."
    | Some (Row_form {row_id;index;locked;_}) ->
        row_still_gives snapshot instance ~tool_name:menu.tool_name ~tool_schema:menu.schema
          ~row_id ~index ~locked in
  let* action = match menu.form with
    | Some form -> Masc_tui_schema_form.value form
    | None -> (match List.nth_opt menu.choices menu.cursor with
      | Some action -> Ok action | None -> Error "No selected action.") in
  let* action = Action.canonical action in
  let* _ = Action.validate ~schema:menu.schema ~name:menu.tool_name
      (Action.arguments ~instance_id:instance.id ~request_id:menu.request_id ~action) in
  Ok {instance_id=instance.id;incarnation=instance.incarnation;request_id=menu.request_id;action}

let paste_action ~text view =
  match view.action_menu with
  | Some ({form=Some form;_} as menu) ->
      {view with action_menu=Some {menu with form=Some (Masc_tui_schema_form.insert_text ~text form)};scroll=0}
  | _ -> view

let edit_action ~key view =
  let* menu = match view.action_menu with Some menu -> Ok menu | None -> Error "No action form" in
  let* form = match menu.form with Some form -> Ok form | None -> Error "No action form" in
  let* event = Masc_tui_schema_form.handle ~key form in
  match event with
  | Masc_tui_schema_form.Cancel -> Ok ({view with action_menu=None;error=None;scroll=0},None)
  | Updated form -> Ok ({view with action_menu=Some {menu with form=Some form};error=None;scroll=0},None)
  | Submit _ -> let* request = submit_action view in Ok (view,Some request)

(* Enter on a menu without a form. In a row's list it opens the chosen row
   action, or the instance's other actions from the last line; an unfillable
   action says why and stays. A preset action is sent. *)
let enter_action view =
  match view.action_menu with
  | Some ({row=Some (Row_list {row_id;entries;_});_} as menu) ->
      (match List.nth_opt entries menu.cursor with
       | Some {filled=Ok filled;index;label} ->
           let* action_schema =
             let* properties = field "properties" menu.schema in
             field "action" properties in
           let locked = filled.Masc.Lane_addon_row_action.locked in
           let* form = Masc_tui_schema_form.create_for_row ~schema:action_schema
               ~branch:filled.Masc.Lane_addon_row_action.branch ~locked in
           Ok ({view with action_menu=Some {menu with cursor=0;form=Some form;
               row=Some (Row_form {row_id;index;label;locked})};scroll=0;error=None},None)
       | Some {filled=Error unfilled;label;_} ->
           Ok ({view with error=Some (Input_failure (label ^ " is unavailable: "
               ^ String.concat "; " (List.map unfilled_text unfilled)))},None)
       | None ->
           let target = Option.bind view.snapshot (fun snapshot ->
             List.find_opt (fun (instance : instance) -> String.equal instance.id menu.target_id
               && String.equal instance.incarnation menu.target_incarnation) snapshot.instances) in
           (match target with
            | Some instance ->
                let* view = instance_menu ~request_id:menu.request_id view instance in Ok (view,None)
            | None -> Error "The selected Plugin changed. Refresh and choose its action again."))
  | Some {row=Some (Row_form _) | None;_} | None ->
      let* request = submit_action view in Ok (view,Some request)

let open_records view =
  let* session = match selected_document view with
    | Some session -> Ok session | None -> Error "Open a TOML draft with n or E first" in
  let* overlay = Masc_tui_lane_records.open_ ~title:session.file_name ~text:session.text in
  Ok {view with records=Some overlay;scroll=0;error=None}

let edit_records ~key view =
  let* overlay = match view.records with
    | Some overlay -> Ok overlay | None -> Error "No records overlay" in
  let* event = Masc_tui_lane_records.handle ~key overlay in
  match event with
  | Masc_tui_lane_records.Cancel -> Ok ({view with records=None;error=None;scroll=0})
  | Updated next ->
      let scroll =
        if Masc_tui_lane_records.text_entry_open overlay
           && Masc_tui_lane_records.text_entry_open next
           && Masc_tui_lane_records.message overlay = Masc_tui_lane_records.message next
        then view.scroll else 0 in
      Ok ({view with records=Some next;error=None;scroll})
  | Apply (next, text) ->
      let* session = match selected_document view with
        | Some session -> Ok session | None -> Error "The open document changed; Esc closes the records overlay." in
      let* () =
        if Masc_tui_lane_records.title overlay = session.file_name
           && Masc_tui_lane_records.text overlay = session.text then Ok ()
        else Error "The open document changed; Esc closes the records overlay without applying this edit." in
      Ok (put_document {view with records=Some next;error=None;scroll=0} {session with text})

let paste_records ~text view =
  {view with records=Option.map (Masc_tui_lane_records.insert_text ~text) view.records}

(* A result value laid out as an outline instead of one line of JSON: an
   object field is a key, a list item is a bullet, a string is its text with
   no quoting, and a nested value sits one indent deeper. The outline says
   nothing about what a package means by its fields. *)
type value_row = { depth : int; key : string option; bullet : bool; text : string }

type value_shape =
  | Leaf of string
  | Fields of (string * Yojson.Safe.t) list
  | Items of Yojson.Safe.t list

(* An absent value reads as a dash and an empty collection as "none"; the
   exact JSON stays under 4 Records and D. *)
let value_shape = function
  | `String text -> Leaf text
  | `Null -> Leaf "—"
  | `Bool value -> Leaf (Bool.to_string value)
  | (`Int _ | `Intlit _ | `Float _) as number -> Leaf (Yojson.Safe.to_string number)
  | `Assoc [] | `List [] -> Leaf "none"
  | `Assoc fields -> Fields fields
  | `List items -> Items items

(* A written line break starts a row of its own under the same key. *)
let leaf_rows ~depth ~key text =
  match Masc_tui_text_block.lines text with
  | [] -> [{ depth; key; bullet = false; text = "" }]
  | first :: rest ->
      { depth; key; bullet = false; text = first }
      :: List.map (fun text -> { depth; key = None; bullet = false; text }) rest

(* A small object of single-line leaves reads on one row ("n 0 · d 3"),
   which is how a count, a pair or a tag fits beside its key. *)
let inline_fields fields =
  let rec collect acc = function
    | [] -> Some (List.rev acc)
    | (key, value) :: rest ->
        (match value_shape value with
         | Leaf text when not (String.contains text '\n') -> collect ((key ^ " " ^ text) :: acc) rest
         | Leaf _ | Fields _ | Items _ -> None) in
  Option.map (String.concat " · ") (collect [] fields)

let rec value_rows ~depth value =
  match value_shape value with
  | Leaf text -> leaf_rows ~depth ~key:None text
  | Fields fields -> List.concat_map (fun (key, value) -> field_rows ~depth key value) fields
  | Items items -> List.concat_map (item_rows ~depth) items
and field_rows ~depth key value =
  let nested () = { depth; key = Some key; bullet = false; text = "" } :: value_rows ~depth:(depth + 1) value in
  match value_shape value with
  | Leaf text -> leaf_rows ~depth ~key:(Some key) text
  | Fields fields ->
      (match inline_fields fields with
       | Some text -> [{ depth; key = Some key; bullet = false; text }]
       | None -> nested ())
  | Items _ -> nested ()
(* An item's first row takes the bullet at the list's depth, so the rest of
   the item lines up under the bullet's text. *)
and item_rows ~depth item =
  match value_rows ~depth:(depth + 1) item with
  | first :: rest -> { first with depth; bullet = true } :: rest
  | [] -> [{ depth; key = None; bullet = true; text = "" }]

(* What one declared reading shows for a row: its value, or why the row does
   not carry one. Readings are scoped to the exact Lane they name. *)
let result_readings (instance : instance) (row : Row.row) =
  let module P = Masc.Lane_addon_presentation in
  instance.display.readings
  |> List.filter (fun (reading : P.reading) ->
       String.equal row.lane_id (instance.id ^ "/" ^ reading.lane_id))
  |> List.map (fun (reading : P.reading) -> (reading, P.value reading (`Assoc row.fields)))

(* Cells an outline row indents per level, which a list bullet ("· ") also
   takes, so an item's continuation lines up under its text. *)
let value_indent_cells = 2

module Span = Masc_tui_span

(* Labels use the reader's foreground with bold weight: the raw Accent hue
   can be unreadable on a light palette. Keys, bullets and stamps stay dim;
   values keep their plain style. *)
let muted_style () = Span.fg Masc_tui_theme.Sgr.dim
let bold_style () = Span.weight Masc_tui_theme.Sgr.bold
let label_style () = bold_style ()

(* Wrap [text] after a styled lead so continuation pieces start under the
   text, not under the lead. [split] cuts the text to a width. By default it
   cuts at the cell, which keeps the exact spaces of a value, and prose passes
   a cut at spaces. *)
let led_rows ?(split = fun ~width text -> document_rows ~width text) ~width ~lead ~text_style text =
  let lead_cells = Span.width lead in
  let pieces = split ~width:(max 1 (width - lead_cells)) text in
  let hang = Span.text Span.plain (String.make lead_cells ' ') in
  List.mapi (fun index piece ->
    Span.concat [ (if index = 0 then lead else hang); Span.text text_style piece ])
    (match pieces with [] -> [ "" ] | pieces -> pieces)

(* A page that lists facts. A heading names a group and takes the label
   weight. Fields are label and value pairs: the fields of one indent share a
   label column across the page, so their values start under each other, and
   a long value hangs under itself. Text is a sentence and keeps its own
   indent. A label column wider than half the width leaves the values a
   sliver, so every label then takes its own row and its value hangs two
   cells under it, fewer where a two-cell character would not fit beside the
   hang. *)
type fact_row =
  | Fact_heading of string
  | Fact_fields of { indent : int; fields : (string * string) list }
  | Fact_text of string

let fact_spans ~width rows =
  let label_cells indent = 1 + List.fold_left (fun widest -> function
    | Fact_fields { indent = at; fields } when at = indent ->
        List.fold_left (fun widest (label, _) ->
          max widest (Masc_tui_message_layout.display_width label)) widest fields
    | Fact_fields _ | Fact_heading _ | Fact_text _ -> widest) 0 rows in
  let beside = List.for_all (function
    | Fact_fields { indent; _ } -> 2 * (indent + label_cells indent) <= width
    | Fact_heading _ | Fact_text _ -> true) rows in
  let spaces cells = Span.text Span.plain (String.make (max 0 (min cells (width - 2))) ' ') in
  let spans = function
    | Fact_heading text -> led_rows ~width ~lead:Span.empty ~text_style:(label_style ()) text
    | Fact_text text -> led_rows ~width ~lead:Span.empty ~text_style:Span.plain text
    | Fact_fields { indent; fields } when beside ->
        List.concat_map (fun (label, value) ->
          let lead = Span.concat
            [ Span.text Span.plain (String.make indent ' ')
            ; Span.pad_to (label_cells indent) Span.plain (Span.text (label_style ()) label) ] in
          led_rows ~width ~lead ~text_style:Span.plain value) fields
    | Fact_fields { indent; fields } ->
        List.concat_map (fun (label, value) ->
          led_rows ~width ~lead:(spaces indent) ~text_style:(label_style ()) label
          @ led_rows ~width ~lead:(spaces (indent + 2)) ~text_style:Span.plain value) fields in
  List.concat_map (fun row ->
    List.map (fun span -> Span.render (Span.truncate width span)) (spans row)) rows

let value_row_spans ~width (row : value_row) =
  let indent = String.make (row.depth * value_indent_cells) ' ' in
  let lead = Span.concat
    [ Span.text Span.plain indent
    ; (if row.bullet then Span.text (muted_style ()) "· " else Span.empty)
    ; (match row.key with
       | Some key -> Span.text (muted_style ()) (Masc.Tui_terminal_text.sanitize_terminal_text key ^ "  ")
       | None -> Span.empty) ] in
  led_rows ~width ~lead ~text_style:Span.plain row.text

let reading_refusal_text : Masc.Lane_addon_presentation.reading_refusal -> string = function
  | Field_absent -> "field unavailable"
  | Field_wrong_shape -> "field path does not address an object"
  | Format_mismatch -> "field does not match declared display format"

let reading_spans ~width ((reading : Masc.Lane_addon_presentation.reading), value) =
  let unit = Option.fold ~none:"" ~some:(fun unit -> " " ^ unit) reading.unit in
  let label = Span.text (label_style ()) (Masc.Tui_terminal_text.sanitize_terminal_text reading.label) in
  let beside text = led_rows ~width ~lead:(Span.concat [ label; Span.text Span.plain "  " ])
      ~text_style:Span.plain (text ^ unit) in
  match value with
  | Error refusal ->
      led_rows ~width ~lead:(Span.concat [ label; Span.text Span.plain "  " ])
        ~text_style:(muted_style ()) ("unavailable · " ^ reading_refusal_text refusal)
  | Ok value ->
      let outline () =
        Span.concat [ label; Span.text (muted_style ()) unit ]
        :: List.concat_map (value_row_spans ~width) (value_rows ~depth:1 value) in
      (match value_shape value with
       | Leaf text when not (String.contains text '\n') -> beside text
       | Fields fields ->
           (match inline_fields fields with Some text -> beside text | None -> outline ())
       | Leaf _ | Items _ -> outline ())

let installation_identity (instance : instance) = instance.installation_id

let installation_name (instance : instance) =
  match installation_identity instance with
  | Some id -> id
  | None -> instance.id

module Standing = Masc_tui_lane_standing

(* What the overview says about a declaration with no current worker. The
   words and the mark come from this one reading, so they cannot disagree. *)
type declaration_reading = Configuration_issue | Needs_attention | Configured_off | No_current_worker | Pending
let declaration_reading (declaration : declaration) =
  if Option.is_none declaration.desired then Configuration_issue
  else if declaration.issues<>[] then Needs_attention
  else if declaration.enabled=Some false then Configured_off
  else if Option.is_some declaration.applied then No_current_worker else Pending
let declaration_reading_word = function
  | Configuration_issue -> "configuration issue"
  | Needs_attention -> "needs attention"
  | Configured_off -> "configured off"
  | No_current_worker -> "no current worker"
  | Pending -> "pending"
(* The mark follows the application line drawn under the entry
   ([declaration_application]), so the two cannot disagree. A declaration with
   an issue needs attention before any application reading. *)
let application_standing : Application.tracking -> Standing.t = function
  | Application.Observed (Application.Failed _) -> Standing.Failing
  | Application.Observed (Application.Unknown _) | Application.Unavailable _ -> Standing.Unobserved
  | Application.Observed (Application.Starting | Application.Cleaning) -> Standing.Changing
  | Application.Observed (Application.Applied _) -> Standing.Ready
  | Application.Observed Application.Inactive -> Standing.Off
  | Application.(Awaiting_declaration | Different_source | Different_inputs) -> Standing.Waiting
let declaration_entry_standing view (declaration : declaration) =
  match declaration_reading declaration with
  | Configuration_issue | Needs_attention -> Standing.Failing
  | Configured_off | No_current_worker | Pending ->
      (match declaration.application with
       | None -> Standing.Unobserved
       | Some observation -> application_standing (track_application view observation.target))
let off_requested (snapshot : snapshot) (item : instance) = match snapshot.configuration with
  | Some config -> List.exists (fun (d : declaration) ->
      d.enabled = Some false && d.instance_id = Some item.id
      && Some d.source_path = item.source_path) config.declarations
  | None -> false
(* An attached worker this server does not hold live cannot be observed or
   run from here ([can_observe]), so it does not read as ready. *)
let instance_standing ~off_requested (item : instance) = match item.phase, item.runtime_presence with
  | Row.Failed _, _ -> Standing.Failing
  | Row.Detaching, _ -> Standing.Changing
  | Row.Detached, _ -> Standing.Off
  | (Row.Attached | Row.Observing), Live_entry -> if off_requested then Standing.Changing else Standing.Ready
  | (Row.Attached | Row.Observing), (Retained_binding | Presence_unknown) -> Standing.Unobserved
(* Overview rows are wrapped and sanitized at the end, and the sanitizer
   prints an SGR byte as text. An entry's first row is drawn here instead:
   the mark gets its colour, and [led_rows] wraps and sanitizes the entry text
   after it. *)
type overview_row = Overview_text of string | Overview_drawn of string list
let entry_lead ~width ~marker standing text =
  Overview_drawn (led_rows ~width
    ~lead:(Span.concat [ Span.text Span.plain marker;
      Span.text (Span.fg (Standing.colour standing)) (Standing.mark standing);
      Span.text Span.plain " " ])
    ~text_style:Span.plain text |> List.map Span.render)

let instance_heading _snapshot (item : instance) =
  match installation_identity item with
  | None -> item.title
  | Some name -> name ^ " · " ^ item.title

let empty_result_lines view (item : instance) =
  match item.phase with
  | Row.Failed detail -> ["Plugin failed: " ^ detail; instance_controls view item]
  | Row.Attached | Row.Observing | Row.Detaching | Row.Detached ->
      if item.observation_seq=0 then ["No completed observation received yet."]
      else if item.rows_count=0 then
        ["Last completed observation contains no result rows.";
         "Check input coverage and 2 Links for declared inputs."]
      else ["No result rows in this received view."; "r:refresh · D:raw details"]

let snapshot_coverage_lines coverage =
  if coverage=[] then [] else
    [""; "Received snapshot coverage · all Plugins"]
    @ List.map (fun (source : Row.coverage) ->
        source.source_id ^ " · " ^ (if source.complete then "complete" else "PARTIAL")
        ^ " · cursor " ^ Option.value ~default:"unknown" source.cursor
        ^ Option.fold ~none:"" ~some:(fun detail -> " · " ^ detail) source.detail) coverage

let overview_lines ~width view =
  let wrap = document_rows ~width in
  let texts = List.map (fun line -> Overview_text line) in
  let content = match view.snapshot with
    | None -> [Overview_text (unread_body_text ~failed_note:"Read failed · r:retry" view)]
    | Some snapshot ->
        let active, failed = List.fold_left (fun (active, failed) (item : instance) ->
          match item.phase with
          | Row.Attached | Row.Observing -> active + 1, failed
          | Row.Failed _ -> active, failed + 1
          | Row.Detaching | Row.Detached -> active, failed)
          (0, 0) snapshot.instances in
        let count = List.length (List.filter (fun item -> not (retained item)) snapshot.instances) in
        let retained_count = List.length (List.filter retained snapshot.instances) in
        let configuration_summary = match snapshot.configuration with
          | None -> "TOML unknown"
          | Some config ->
              let declared = List.fold_left (fun total (declaration : declaration) ->
                if Option.is_some declaration.desired then total + 1 else total)
                0 config.declarations in
              let issues = List.fold_left (fun total (declaration : declaration) ->
                total + List.length declaration.issues) 0 config.declarations in
              Printf.sprintf "%d declared%s%s" declared
                (if issues=0 then "" else Printf.sprintf " · %d config issues" issues)
                (if config.complete then "" else " · inventory partial") in
        let heading = Printf.sprintf "Plugins · %s · %d active · %d failed workers%s"
          configuration_summary active failed
          (if Option.is_some view.snapshot_read_error then " · STALE" else "") in
        let entries = selectable_overview_entries view snapshot in
        (* Keep the selected entry first: wrapped history/count context already
           spends rows before the list in a narrow terminal. *)
        let window = max 0 view.instance_cursor in
        let items = List.mapi (fun index item -> index,item) entries
          |> List.filter (fun (index,_) -> index >= window && index < window + 9) in
        let empty = match view.overview_mode, snapshot.configuration with
          | Retained_runs, _ when entries=[] -> ["No retained runs in this snapshot. h:current installations"]
          | Retained_runs, _ -> []
          | Current_installations, Some {complete=true;declarations=[];_} when count=0 ->
              ["No Plugins installed. i:install a package  n:new TOML"]
          | Current_installations, Some {complete=false;_} when entries=[] -> ["Installation inventory incomplete · r:refresh"]
          | Current_installations, None when entries=[] -> ["TOML installation status unknown · r:refresh"]
          | Current_installations, (Some _ | None) -> [] in
        texts ([heading;
         (match view.overview_mode with
          | Current_installations -> Printf.sprintf "Retained history · %d instances · h:open" retained_count
          | Retained_runs -> Printf.sprintf "Retained history · %d instances · h:current installations" retained_count);
         ""] @ empty)
        @ List.concat_map (fun (index,item) ->
            let marker = if index=view.instance_cursor then "> " else "  " in
            let role_header = match view.overview_mode with
              | Retained_runs -> []
              | Current_installations ->
                  let here = current_category snapshot item in
                  let previous = if index=0 then None else List.nth_opt entries (index-1) in
                  if index<>window && Option.fold ~none:false ~some:(fun p -> current_category snapshot p=here) previous
                  then [] else texts ["── " ^ category_heading here ^ " ──"] in
            role_header @
            match item with
            | `Declaration (_, declaration) ->
                let name = Option.value ~default:"unresolved installation" declaration.installation_id in
                let reading = declaration_reading declaration in
                let edit = Option.bind snapshot.configuration (fun config ->
                  if Document.editable_source_path ~directory:config.directory declaration.source_path
                  then Some "  E:edit" else None) |> Option.value ~default:"" in
                entry_lead ~width ~marker (declaration_entry_standing view declaration)
                  (name ^ " · " ^ declaration_reading_word reading ^ " · " ^ Filename.basename declaration.source_path)
                :: texts ["    " ^ declaration_application view declaration;
                          "    Enter:installation" ^ edit]
            | `Instance item ->
                let group_header = match view.overview_mode with
                  | Current_installations -> []
                  | Retained_runs ->
                      let previous = if index=0 then None else List.nth_opt entries (index-1) in
                      let same_group = match previous with
                        | Some (`Instance previous) -> history_group previous=history_group item
                        | Some (`Declaration _) | None -> false in
                      if same_group && index<>window then [] else
                        let name = match item.source_path with
                          | Some path -> path | None -> "undeclared" in
                        [name ^ " · add-on " ^ item.addon_id ^ " · run " ^ item.run_id] in
                let count_text = if item.observation_seq=0 then "awaiting first observation"
                  else Printf.sprintf "%d records" item.rows_count in
                let off_requested = off_requested snapshot item in
                let activity = if off_requested then "off requested · " else "" in
                let lead = entry_lead ~width ~marker (instance_standing ~off_requested item)
                  (instance_heading snapshot item ^ " · " ^
                   activity ^
                   (match item.phase with
                     | Row.Failed _ -> "failed"
                     | Row.Attached | Observing | Detaching | Detached -> phase_label item.phase) ^
                   " · " ^ count_text) in
                let controls = "    Enter:open  " ^ instance_controls view item in
                let detail = match item.phase with
                  | Row.Failed detail ->
                      Masc_tui_message_layout.wrap_words ~max_cells:(max 1 (width - 4))
                        ("D:full · " ^ detail)
                      |> List.map (fun line -> "    " ^ line)
                  | Row.Attached | Row.Observing | Row.Detaching | Row.Detached -> [] in
                texts group_header @ [lead]
                @ texts ((match view.overview_mode, snapshot.configuration with
                   | Current_installations, Some config ->
                       List.filter_map (fun (d : declaration) ->
                         if Some d.source_path=item.source_path && d.installation_id=item.installation_id
                         then Some ("    " ^ declaration_application view d) else None) config.declarations
                   | Current_installations, None | Retained_runs, _ -> [])
                @ (match view.overview_mode with Current_installations -> []
                   | Retained_runs -> ["    Instance " ^ item.id])
                @ (match view.overview_mode, current_category snapshot (`Instance item), item.ui_category with
                   | Retained_runs, _, _ | _, Unverified, _ -> []
                   | Current_installations, Classified now, Some started when now=started -> []
                   | Current_installations, Unclassified, None -> []
                   | Current_installations, ((Classified _ | Unclassified) as now), started ->
                       let word = function Some c -> category_label c | None -> "unclassified" in
                       [Printf.sprintf "    role: worker started as %s · declaration now %s" (word started)
                          (match now with Classified c -> category_label c | Unclassified | Unverified -> "unclassified")])
                @ (if index=view.instance_cursor then
                     Option.to_list (Option.map (fun text -> "    " ^ text) item.display.description)
                   else [])
                @ [controls] @ detail)) items
  in
  List.concat_map (function Overview_text line -> wrap line | Overview_drawn rows -> rows)
    (texts (diagnostic_lines view) @ content
     @ texts ([""; overview_hints view] @ action_lines view))

(* One line of the Plugins help. [Help_keys] names the keys of a screen or a
   task under a label, and [Help_note] explains the line above it. *)
type help_row =
  | Help_title of string
  | Help_about of string
  | Help_keys of { group : string; keys : string }
  | Help_note of string

let help_rows = [
  Help_title "Plugins keys · Esc:close";
  Help_about "Install Plugins and switch them on/off. Lanes are their work and observation paths.";
  Help_keys { group = "List"; keys = "j/k select · Enter open · h history/current · i install · n new TOML" };
  Help_keys { group = "Detail"; keys = "1 Results · 2 Links · 3 Installation · 4 Records · Tab next" };
  Help_keys { group = "Both"; keys = "?:help · Esc back · q back · r refresh · J/K scroll" };
  Help_keys { group = "Actions"; keys = "o observe/retry · d remove TOML/worker · a advertised actions" };
  Help_note "TOML-managed removal deletes the matching declaration from disk and cleans up its owned worker.";
  Help_note "Manual attachments remove only the worker and its owned resources.";
  Help_note "Declarations now owned by another instance are preserved; observations and evidence remain.";
  Help_keys { group = "Actions"; keys = "t check last request · D raw details · f flow" };
  Help_keys { group = "Installation"; keys = "Space on/off draft · E edit · s save · l reload · u/U revision" };
  Help_note "Saving off keeps the TOML and evidence; r reads the actual worker cleanup state.";
  Help_keys { group = "Links"; keys = "S subscriptions · Left/Right lane" };
  Help_keys { group = "Records"; keys = "Space mark row · e export marked rows" };
  Help_keys { group = "Navigation"; keys = ": command palette · Esc returns to Plugins" };
  Help_keys { group = "Advanced"; keys = "A opens Plugin commands · Enter submits (including act or detach ID)" };
]

(* Labels share one column, as wide as the longest label and a two-cell gap,
   so the keys and the notes start under each other. A column wider than half
   the width leaves the keys a sliver, so the label then takes its own row and
   the keys and the notes hang two cells under it. *)
let help_lines ~width =
  let label_cells = 2 + List.fold_left (fun widest -> function
    | Help_keys { group; _ } -> max widest (Masc_tui_message_layout.display_width group)
    | Help_title _ | Help_about _ | Help_note _ -> widest) 0 help_rows in
  let beside = 2 * label_cells <= width in
  let hang_cells = if beside then label_cells else max 0 (min 2 (width - 1)) in
  let hang = Span.text Span.plain (String.make hang_cells ' ') in
  let split ~width text = Masc_tui_message_layout.wrap_words ~max_cells:width text in
  let rows = function
    | Help_title text -> led_rows ~split ~width ~lead:Span.empty ~text_style:(label_style ()) text
    | Help_about text -> led_rows ~split ~width ~lead:Span.empty ~text_style:Span.plain text
    | Help_keys { group; keys } when beside ->
        let lead = Span.pad_to label_cells Span.plain (Span.text (label_style ()) group) in
        led_rows ~split ~width ~lead ~text_style:Span.plain keys
    | Help_keys { group; keys } ->
        led_rows ~split ~width ~lead:Span.empty ~text_style:(label_style ()) group
        @ led_rows ~split ~width ~lead:hang ~text_style:Span.plain keys
    | Help_note text -> led_rows ~split ~width ~lead:hang ~text_style:Span.plain text in
  List.concat_map (fun row ->
    List.map (fun span -> Span.render (Span.truncate width span)) (rows row)) help_rows

type read_target =
  | Read_screen
  | Read_detail of string * string
  | Read_installation_results of string

type read_scope_error =
  | Detail_owner_unavailable
  | Slice_run_required
  | Slice_run_blank
  | Slice_run_ambiguous
  | Slice_run_mismatch of { expected : string; requested : string }
  | Slice_target_mismatch

let request_read_target ?target view request =
  let target = match target with
    | Some target -> target
    | None -> match request with
      | Inspect | Slice _ ->
          (match view.screen with
           | Overview -> Read_screen
           | Detail (id, incarnation) -> Read_detail (id, incarnation))
      | Attach _ | Observe _ | Detach _ | Evidence _ | Act _ | Action_status _
      | Subscriptions _ -> Read_screen in
  match request, view.screen with
  | Slice _, Overview ->
      (match target with
       | Read_screen -> Ok target
       | Read_detail _ | Read_installation_results _ -> Error Slice_target_mismatch)
  | Slice query, Detail (id, incarnation) ->
      let* owner = match view.snapshot with
        | None -> Error Detail_owner_unavailable
        | Some snapshot ->
            (match List.filter (fun (item : instance) ->
               item.id=id && item.incarnation=incarnation) snapshot.instances with
             | [owner] -> Ok owner
             | [] | _ :: _ :: _ -> Error Detail_owner_unavailable) in
      let* run = match List.filter_map (fun (key, value) ->
          if key="run_id" then Some value else None) query with
        | [] -> Error Slice_run_required
        | [run] when String.trim run="" -> Error Slice_run_blank
        | [run] -> Ok run
        | _ :: _ :: _ -> Error Slice_run_ambiguous in
      if run<>owner.run_id then Error (Slice_run_mismatch {expected=owner.run_id;requested=run})
      else (match target with
        | Read_detail (target_id, target_incarnation)
            when target_id=id && target_incarnation=incarnation -> Ok target
        | Read_screen | Read_detail _ | Read_installation_results _ -> Error Slice_target_mismatch)
  | (Inspect | Attach _ | Observe _ | Detach _ | Evidence _ | Act _ | Action_status _
    | Subscriptions _), (Overview | Detail _) -> Ok target

let refuse_read_scope view refusal =
  let detail = match refusal with
    | Detail_owner_unavailable -> "The original detail owner is unavailable."
    | Slice_run_required -> "A detail Slice requires its original run_id."
    | Slice_run_blank -> "A detail Slice cannot use a blank run_id."
    | Slice_run_ambiguous -> "A detail Slice requires exactly one run_id."
    | Slice_run_mismatch {expected;requested} ->
        Printf.sprintf "Slice run %s differs from the detail's original run %s." requested expected
    | Slice_target_mismatch -> "The Slice target differs from its original detail." in
  {view with error=Some (Input_failure (detail
    ^ " Return to the list with Esc to query another run or all runs; existing results are retained."))}

let read_still_wanted view ~showing target = match target with
  | Read_screen -> true
  | Read_detail (id, incarnation) -> view.screen = Detail (id, incarnation)
  | Read_installation_results _ -> showing && view.screen = Overview

let reconcile_read_snapshot view ~target ~diagnostic snapshot =
  let detail_read_error = match target, diagnostic with
    | Read_detail (id, incarnation), Some (Detail_read_failure detail) ->
        Some (id, incarnation, detail)
    | Read_detail _, None | Read_installation_results _, None -> None
    | (Read_screen | Read_detail _ | Read_installation_results _),
      (Some (Request_failure _ | Input_failure _ | Detail_read_failure _))
    | Read_screen, None -> view.detail_read_error in
  let detail_read_error = Option.bind detail_read_error (fun ((id, incarnation, _) as failure) ->
    match view.screen with
    | Detail (owner, epoch) when id=owner && incarnation=epoch -> Some failure
    | Overview | Detail _ -> None) in
  let same_binding (left : instance) (right : instance) =
    left.id=right.id && left.incarnation=right.incarnation
    && left.run_id=right.run_id && left.addon_id=right.addon_id
    && left.revision=right.revision && left.installation_id=right.installation_id
    && left.source_path=right.source_path
    && left.configuration_revision=right.configuration_revision
    && Yojson.Safe.equal left.binding right.binding in
  let detail_read_error = Option.bind detail_read_error (fun ((id, incarnation, _) as failure) ->
    let find instances = List.find_opt (fun (item : instance) ->
      item.id=id && item.incarnation=incarnation) instances in
    match find snapshot.instances, Option.bind view.snapshot (fun previous -> find previous.instances) with
    | Some after, Some before when same_binding before after -> Some failure
    | Some _, None -> Some failure
    | (Some _ | None), (Some _ | None) -> None) in
  let snapshot = match detail_read_error, view.snapshot with
    | Some (id, incarnation, _), Some previous
        when view.screen=Detail (id, incarnation) ->
        let find instances = List.find_opt (fun (item : instance) ->
          item.id=id && item.incarnation=incarnation) instances in
        let previous_rows = match find previous.instances, find snapshot.instances with
          | Some before, Some after when same_binding before after ->
              List.filter (fun (row : Row.row) ->
                let owned = match row_owner previous.instances row with
                  | Some owner -> owner.id=id && owner.incarnation=incarnation
                  | None -> false in
                owned && not (List.exists (fun (fresh : Row.row) -> fresh.id=row.id)
                  snapshot.output.rows)) previous.output.rows
          | (Some _ | None), (Some _ | None) -> [] in
        {snapshot with output={snapshot.output with rows=snapshot.output.rows @ previous_rows};
          complete=None}
    | (Some _ | None), (Some _ | None) -> snapshot in
  let view = reconcile_snapshot view snapshot in
  {view with detail_read_error}

let installation_results view ~installation_id =
  let live = Option.bind view.snapshot (fun snapshot ->
    List.find_opt (fun (item : instance) -> item.installation_id = Some installation_id && live_entry item)
      snapshot.instances) in
  match live with
  | Some item ->
      select_initial_result { (set_presentation view Summary) with screen=Detail (item.id, item.incarnation); focus=Timeline;
        row_cursor = -1; scroll=0; selected=[]; document_key=None; error=None}
  | None ->
      {view with error=Some (Input_failure (installation_id
        ^ " has no running worker; its Results appear while it runs"))}

let host_wait_text = function
  | Host_wait_operator -> "waiting for the operator's answer"
  | Host_wait_source detail -> "source unavailable: " ^ detail
  | Host_wait_exact reason ->
      let module E = Masc.Lane_addon_exact in
      (match reason with
       | E.Lane_unavailable E.Lane_unconfigured -> "its lane has no table in runtime.toml"
       | E.Lane_unavailable E.Lane_off -> "its lane is off"
       | E.Lane_unavailable E.No_admitted_slots -> "its lane has no admitted slot"
       | E.Lane_unavailable (E.Lane_registry_unavailable { detail }) -> "lane registry unavailable: " ^ detail
       | E.Lane_unavailable (E.Every_slot_held { until }) ->
           "no slot can be called before " ^ Masc_domain.iso8601_of_unix_seconds until
       | E.Provider_refused (E.Provider_unavailable { detail }) -> "provider unavailable: " ^ detail
       | E.Provider_refused (E.Provider_auth_refused { detail }) -> "provider refused authentication: " ^ detail
       | E.Provider_refused (E.Provider_configuration_refused { detail }) ->
           "provider refused the configuration: " ^ detail
       | E.Attempt_in_progress -> "an attempt is running")
let host_issue_text = function
  | Host_listing_failed detail -> "the listing failed: " ^ detail
  | Host_listing_refused detail -> "the listing was refused: " ^ detail
  | Host_relisted_delivered_request request_id -> "listed " ^ request_id ^ " again after its result"
  | Host_result_delivery_failed { request_id; detail } -> "delivering " ^ request_id ^ " failed: " ^ detail
  | Host_exact_record_failed { request_id; detail } -> "recording " ^ request_id ^ " failed: " ^ detail
  | Host_ask_record_failed { request_id; detail } -> "recording question " ^ request_id ^ " failed: " ^ detail
  | Host_no_exact_runner -> "this host has no exact-output runner"
  | Host_no_web_search_runner -> "this host has no web-search runner"
let host_request_lines item = match item.host_requests with
  | None | Some (Ok { hr_cycles = 0; hr_waiting = []; hr_issue = None }) -> []
  | Some (Error detail) -> [Fact_text ""; Fact_text ("Host requests: unreadable · " ^ detail)]
  | Some (Ok { hr_cycles; hr_waiting; hr_issue }) ->
      Fact_text "" :: Fact_heading (Printf.sprintf "Host requests · last cycle (%d total)" hr_cycles)
      :: List.map (fun line -> Fact_text line)
        ((match hr_waiting, hr_issue with
          | [], Some _ -> ["  waiting status incomplete"]
          | [], None -> ["  nothing reported waiting"]
          | waiting, _ -> List.map (fun (request_id, wait) -> "  " ^ request_id ^ ": " ^ host_wait_text wait) waiting)
         @ (if hr_waiting <> [] && Option.is_some hr_issue then ["  waiting status incomplete"] else [])
         @ Option.fold ~none:[] ~some:(fun issue -> ["  issue: " ^ host_issue_text issue]) hr_issue)

let connection_workers (snapshot : snapshot) (item : instance) =
  match item.installation_id with
  | None ->
      {installation_workers=List.filter (fun (worker : instance) ->
         worker.id=item.id && worker.incarnation=item.incarnation) snapshot.instances;
       other_path_owners=[]}
  | Some id ->
      let installation_workers = List.filter (fun (worker : instance) ->
        worker.installation_id=Some id) snapshot.instances in
      let other_path_owners = match item.source_path with
        | None -> []
        | Some path -> List.filter (fun (worker : instance) ->
            match worker.installation_id, worker.source_path with
            | Some owner, Some candidate -> owner<>id && candidate=path
            | None, None | None, Some _ | Some _, None -> false) snapshot.instances in
      {installation_workers;other_path_owners}

let connection_worker_lines (snapshot : snapshot) (item : instance) =
  let workers = connection_workers snapshot item in
  let lines (worker : instance) =
    [Fact_text ("  " ^ worker.id ^ " · " ^ (match worker.runtime_presence with
       | Live_entry -> "live" | Retained_binding -> "retained" | Presence_unknown -> "presence unknown")
       ^ " · " ^ phase_label worker.phase);
     Fact_fields { indent = 4; fields =
       ["installation", Option.value ~default:"manual attachment" worker.installation_id;
        "incarnation", worker.incarnation;
        "TOML", Option.value ~default:"manual attachment" worker.source_path;
        "installed revision", Option.value ~default:worker.revision worker.configuration_revision] };
     Fact_text (Printf.sprintf "    completed observation sequence %d · retained rows %d"
       worker.observation_seq worker.rows_count)]
    @ (if worker.observation_seq=0 then [Fact_text "    no completed observation received"] else []) in
  [Fact_text ""; Fact_heading "Workers with this installation ID · each incarnation keeps its own results"]
  @ List.concat_map lines workers.installation_workers
  @ (match workers.other_path_owners with
     | [] -> []
     | owners -> [Fact_text ""; Fact_heading "Other installation IDs at this TOML path · separate owners, not the selected installation"]
         @ List.concat_map lines owners)

(* The Results list takes a third of the row, never less than
   [results_list_min_cells], once the terminal is at least
   [results_two_pane_min_cells] wide; a narrower terminal stacks the result
   above the list. *)
let results_list_min_cells = 34
let results_list_share = 3
let results_two_pane_min_cells = 90
let results_gutter = " │ "
(* A window marks a cut above and below its focus, so it needs a row for each
   mark and one for the focus. *)
let window_min_rows = 3

let lane_name (item : instance) lane_id =
  let prefix = item.id ^ "/" in
  if String.starts_with ~prefix lane_id
  then String.sub lane_id (String.length prefix) (String.length lane_id - String.length prefix)
  else lane_id

(* One heading per Lane, then its results. [rows] arrives grouped by Lane
   ([ordered_result_rows]). Answers the rows and the position of the selected
   result, which the window keeps in view. *)
let result_list_spans (item : instance) ~(selected : Row.row option) rows =
  let rec same_lane lane = function
    | (row : Row.row) :: rest when String.equal row.lane_id lane ->
        let same, others = same_lane lane rest in (row :: same, others)
    | rows -> ([], rows) in
  let is_selected (row : Row.row) =
    Option.fold ~none:false ~some:(fun (chosen : Row.row) -> String.equal chosen.id row.id) selected in
  let entry (row : Row.row) =
    let title = Masc.Tui_terminal_text.sanitize_terminal_text row.title in
    if is_selected row then Span.text (bold_style ()) ("> " ^ title)
    else Span.text Span.plain ("  " ^ title) in
  let rec groups = function
    | [] -> []
    | (row : Row.row) :: _ as rows ->
        let same, others = same_lane row.lane_id rows in
        let heading = Span.text (label_style ())
            (Printf.sprintf "%s (%d)"
               (Masc.Tui_terminal_text.sanitize_terminal_text (lane_name item row.lane_id))
               (List.length same)) in
        ((heading, false) :: List.map (fun row -> (entry row, is_selected row)) same) @ groups others in
  let entries = groups rows in
  let focus = Option.value ~default:0 (List.find_index snd entries) in
  (List.map fst entries, focus)

(* Which list rows to show around [focus] as (first, shown): the whole list
   when it fits in [rows], otherwise a window of [rows] that keeps [focus]
   near its middle. *)
let result_window ~rows ~focus ~count =
  if count <= rows || rows < window_min_rows then (0, count)
  else (max 0 (min (count - rows) (focus - rows / 2)), rows)

let window_spans ~rows ~focus spans =
  let count = List.length spans in
  let first, shown = result_window ~rows ~focus ~count in
  let above = first and below = count - (first + shown) in
  let more hidden arrow = Span.text (muted_style ()) (Printf.sprintf "%s %d more" arrow hidden) in
  List.filteri (fun index _ -> index >= first && index < first + shown) spans
  |> List.mapi (fun index span ->
       if index = 0 && above > 0 then more (above + 1) "↑"
       else if index = shown - 1 && below > 0 then more (below + 1) "↓"
       else span)

let selected_result_spans ~width (item : instance) (selected : Row.row option) =
  match selected with
  | None -> [ Span.text (muted_style ()) "Choose a result with j/k." ]
  | Some row ->
      let values = match result_readings item row with
        (* A package that declares no readings shows the row's fields. *)
        | [] -> List.concat_map (value_row_spans ~width) (value_rows ~depth:0 (`Assoc row.fields))
        | readings -> List.concat_map (reading_spans ~width) readings in
      led_rows ~width ~lead:Span.empty ~text_style:(bold_style ()) row.title
      @ led_rows ~width ~lead:Span.empty ~text_style:(muted_style ())
          (lane_name item row.lane_id ^ " · " ^ utc_stamp row.observed_at ^ " UTC")
      @ (Span.empty :: values)

let side_by_side ~list_width ~detail_width list detail =
  let list = Array.of_list list and detail = Array.of_list detail in
  let at items index = if index < Array.length items then items.(index) else Span.empty in
  List.init (max (Array.length list) (Array.length detail)) (fun index ->
    Span.render (Span.concat
      [ Span.pad_to list_width Span.plain (Span.truncate list_width (at list index))
      ; Span.text (muted_style ()) results_gutter
      ; Span.truncate detail_width (at detail index) ]))

(* The Results tab: the list beside the selected result, or the result above
   the list when the terminal is too narrow for both. [height] is the rows
   left under the tab strip; the list is windowed to it around the selected
   result. *)
let results_lines ~height ~width (item : instance) ~selected rows =
  let list, focus = result_list_spans item ~selected rows in
  if width >= results_two_pane_min_cells then
    let list_width = max results_list_min_cells (width / results_list_share) in
    let detail_width = width - list_width - Span.width (Span.text Span.plain results_gutter) in
    let detail = selected_result_spans ~width:detail_width item selected in
    side_by_side ~list_width ~detail_width
      (window_spans ~rows:(max height (List.length detail)) ~focus list) detail
  else
    (selected_result_spans ~width item selected @ (Span.empty :: window_spans ~rows:height ~focus list))
    |> List.map (fun span -> Span.render (Span.truncate width span))

let tab_strip ~width view =
  let tab focus label =
    if view.focus = focus then Span.text (label_style ()) ("[" ^ label ^ "]")
    else Span.text (muted_style ()) label in
  [ tab Timeline "1 Results"; tab Connections "2 Links";
    tab Configurations "3 Installation"; tab Rows "4 Records" ]
  |> List.mapi (fun index span -> if index = 0 then [ span ] else [ Span.text Span.plain "  "; span ])
  |> List.concat |> Span.concat |> Span.truncate width |> Span.render

let detail_lines ~height ~width view =
  let wrap = document_rows ~width in
  match selected_instance view, view.snapshot with
  | None, _ -> ["The selected Plugin changed. Esc returns to the list."]
  | Some item, Some snapshot ->
      let header = instance_heading snapshot item ^ " · " ^ phase_label item.phase in
      (* The footer drops its last items first, and the worker controls sit
         there, so [a] is named here too whenever it opens this worker's form. *)
      let actions =
        if can_observe item && Option.is_some item.action_schema then "  a:actions" else "" in
      let head = List.concat_map wrap ["?:help  Esc:back  Tab:section  j/k:move" ^ actions ^ "  D:raw"; header]
        @ [tab_strip ~width view; ""]
        @ List.concat_map wrap (diagnostic_lines view) in
      let record_rows = List.map snd (ordered_rows view snapshot) in
      let rows = List.map snd (ordered_result_rows view snapshot) in
      let selected = selected_row view in
      let body = match view.focus with
      | Timeline | Instances ->
          let selected = Option.bind selected (fun selected ->
            List.find_opt (fun (row : Row.row) -> row.id = selected.id) rows) in
          if rows=[] then List.concat_map wrap (Option.to_list item.display.description
            @ (if record_rows=[] then empty_result_lines view item
               else ["No declared result rows in this received view.";
                     "Supporting records remain available in 4 Records."])
            @ snapshot_coverage_lines snapshot.output.coverage)
          else
            let intro = List.concat_map wrap (Option.to_list item.display.description) in
            let height = max 1 (height - List.length head - List.length intro) in
            intro
            @ results_lines ~height ~width item ~selected rows
            @ List.concat_map wrap ([""; "Activity timeline"]
                @ timeline_lines ~width ~instances:[item] ?selected rows
                @ snapshot_coverage_lines snapshot.output.coverage)
      | Connections -> []
      | Configurations -> fact_spans ~width (
          [Fact_fields { indent = 0; fields =
             ["Source:", Option.value ~default:"not supplied" item.source_path;
              "Revision:", item.revision;
              "Instance:", item.id;
              "Incarnation:", item.incarnation] }]
          @ (match snapshot.configuration with
             | None -> [Fact_text "Installation inventory unavailable"]
             | Some config ->
                 List.concat_map (fun (declaration : declaration) ->
                   if Some declaration.source_path = item.source_path
                   then [Fact_fields { indent = 0; fields =
                           ["Current declaration:", (match declaration.enabled with
                              | Some true -> "configured on"
                              | Some false -> "configured off"
                              | None -> "desired activity unknown");
                            "Desired:", Option.value ~default:"unknown" declaration.desired;
                            "Applied:", Option.value ~default:"unknown" declaration.applied] };
                         Fact_text (declaration_application view declaration);
                         Fact_fields { indent = 0; fields = List.map (fun issue -> "Issue:", issue) declaration.issues }]
                   else []) config.declarations)
          @ host_request_lines item
          @ connection_worker_lines snapshot item)
      | Rows ->
          if record_rows=[] then List.concat_map wrap (empty_result_lines view item)
          else List.concat_map (fun (row : Row.row) ->
            technical_text [(if Option.fold ~none:false ~some:(fun (selected : Row.row) -> selected.id = row.id)
                 selected then "> " else "  ")
             ^ (if List.mem row.id view.selected then "[selected] " else "") ^ row.title;
             "Row " ^ row.id]
            @ [Technical_json {value=`Assoc row.fields;indent=0}]
            @ technical_text (List.map evidence_text row.evidence)
            |> List.concat_map (technical_rows ~width)) record_rows in
      head @ body
  | Some _, None -> ["Reading Plugins…"]

let rec action_fields prefix = function
  | `Assoc fields -> List.concat_map (fun (key,value) ->
      action_fields (if prefix="" then key else prefix ^ "." ^ key) value) fields
  | value -> [prefix ^ ": " ^ Yojson.Safe.to_string value]

type flow_node = {
  worker : instance;
  upstream : string list;
  problems : string list;
}

type flow_input = { source_id : string; installation_id : string; output_id : string option }
type flow_resolution =
  | Producer_available of instance
  | Producer_missing
  | Producer_ambiguous
  | Output_missing of string

let flow_inputs binding =
  let module S = Masc.Lane_addon_sources in
  let* sources = S.parse binding in
  Ok (List.filter_map (function
    | S.Lane_output {id;installation_id;output_id} -> Some {source_id=id;installation_id;output_id}
    | S.Snapshot_file _ | S.Msx_capture _ | S.Dos_capture _ | S.Browser_document _
    | S.Fusion_run _ -> None) sources)

let flow_external_inputs binding =
  let module S = Masc.Lane_addon_sources in
  let* sources = S.parse binding in
  Ok (List.filter_map (function
    | S.Lane_output _ -> None
    | S.Snapshot_file {id;path} -> Some (id ^ " · snapshot " ^ path)
    | S.Fusion_run {id;run_id} -> Some (id ^ " · Fusion run " ^ run_id)
    | S.Msx_capture {id} -> Some (id ^ " · MSX capture")
    | S.Dos_capture {id} -> Some (id ^ " · DOS capture")
    | S.Browser_document {id;selection;tab_id;target_id;environment;request_id} ->
        Some (Printf.sprintf "%s · Browser %s · tab %d · target %s · %s · request %s"
          id (S.browser_selection_lane selection) tab_id target_id environment request_id)) sources)

let flow_worker_state (worker : instance) =
  let result = if worker.observation_seq=0 then "no completed observation received"
    else Printf.sprintf "last completed: %d record%s" worker.rows_count
      (if worker.rows_count=1 then "" else "s") in
  phase_label worker.phase ^ " · " ^ result

let configured_producers ~identity workers id =
  List.filter (fun producer -> live_entry producer && identity producer=Some id) workers

let resolve_flow_input ~identity ~run_id workers input =
  match configured_producers ~identity workers input.installation_id with
  | [] -> Producer_missing
  | _ :: _ :: _ -> Producer_ambiguous
  | [producer] when not (String.equal producer.run_id run_id) -> Producer_missing
  | [producer] ->
      match input.output_id with
      | None -> Producer_available producer
      | Some port -> if List.mem_assoc port producer.outputs then Producer_available producer
          else Output_missing port

let declared_layers ~identity workers =
  let nodes = List.map (fun worker ->
    if not (live_entry worker) then
      {worker;upstream=[];problems=["No live runtime entry; stored binding cannot supply output"]}
    else match flow_inputs worker.binding with
    | Error detail -> {worker;upstream=[];problems=["Invalid source binding: " ^ detail]}
    | Ok dependencies ->
        let upstream, problems = List.fold_left (fun (upstream,problems) input ->
          match resolve_flow_input ~identity ~run_id:worker.run_id workers input with
          | Producer_available producer -> producer.id :: upstream, problems
          | Producer_missing -> upstream, ("Producer unresolved in this run: " ^ input.installation_id) :: problems
          | Producer_ambiguous -> upstream, ("Producer identity is ambiguous: " ^ input.installation_id) :: problems
          | Output_missing port -> upstream, ("Producer output unavailable: " ^ input.installation_id ^ "/" ^ port) :: problems)
          ([],[]) dependencies in
        {worker;upstream;problems}) workers in
  let rec place placed layers remaining =
    let ready, waiting = List.partition (fun node ->
      node.problems=[] && List.for_all (fun id -> List.mem id placed) node.upstream) remaining in
    match ready with
    | [] -> List.rev layers, waiting
    | ready -> place (List.map (fun node -> node.worker.id) ready @ placed)
        (ready :: layers) waiting in
  place [] [] nodes

(* The flow of one Plugin, for the Links tab and the full flow: a heading takes
   the label style and a field shares the label column of [fact_spans]. The
   lines under a heading stay plain text. *)
let flow_rows ?(embedded=false) view =
  let text line = Fact_text line in
  (match selected_instance view with
   | None -> [Fact_text "No selected Plugin action target"]
   | Some instance ->
       [Fact_fields { indent = 0; fields = ["Action target:", instance.title ^ " · " ^ instance.id] }])
  @ [Fact_heading "Declared Add-on layers · last received snapshot";
     Fact_text "Same layer: independent dependencies. Downward: declared upstream -> consumer.";
     Fact_text "Layer placement describes wiring; execution and delivery need their own receipts."]
  @ (match view.error with
     | None -> []
     | Some ((Detail_read_failure _ | Request_failure _ | Input_failure _) as diagnostic) ->
         [Fact_text (diagnostic_text diagnostic)])
  @ (match view.snapshot_read_error, view.snapshot with
     | Some detail, Some _ ->
         [Fact_fields { indent = 0; fields = ["Read:", detail ^ " · previous graph retained"] }]
     | Some detail, None -> [Fact_fields { indent = 0; fields = ["Read:", detail] }]
     | None, (Some _ | None) -> [])
  @ List.map text (Option.to_list (detail_read_note view))
  @ (match view.snapshot with
     | None -> [Fact_text "Connections unavailable: no snapshot read yet"]
     | Some snapshot ->
         let declarations = Option.fold ~none:[] ~some:(fun c -> c.declarations) snapshot.configuration in
         let name = installation_name in
         let identity = installation_identity in
         let historical = match selected_instance view with
           | Some instance when retained instance -> true
           | Some _ | None -> view.overview_mode=Retained_runs in
         let workers = if historical then
             (match detail_instance view snapshot with
              | Some instance -> [instance]
              | None -> List.filter retained snapshot.instances)
           else List.filter (fun instance -> not (retained instance)) snapshot.instances in
         let complete = Option.fold ~none:false ~some:(fun (c : configuration) -> c.complete) snapshot.configuration in
         let notices = (if complete then [] else ["Installation inventory incomplete; dependency identities may be unresolved"])
           @ List.concat_map (fun (d : declaration) -> List.map (fun issue -> d.source_path ^ ": " ^ issue) d.issues) declarations in
         let external_inputs = List.concat_map (fun worker ->
           match flow_external_inputs worker.binding with
           | Error detail -> ["  " ^ name worker ^ ": invalid source binding · " ^ detail]
           | Ok sources -> List.map (fun source ->
               "  " ^ source ^ " -> " ^ name worker
               ^ (if historical then " · stored binding" else "")) sources) workers in
         let source_lines = [Fact_text ""; Fact_heading "Bound external inputs · declared sources"]
           @ List.map text (if external_inputs=[] then ["  No external source bindings in this view"]
              else external_inputs)
           @ [Fact_text ""; Fact_heading "Add-on layers · worker state and latest completed result summary"] in
         let layers, unresolved = if historical then [], [] else declared_layers ~identity workers in
         let layer_lines = if historical then
             [Fact_text "Stored bindings · producer incarnations are not reconstructed as current layers"]
           else List.concat (List.mapi (fun index nodes ->
             [Fact_text (if index=0 then "" else "    ↓"); Fact_heading ("Layer " ^ string_of_int index)]
             @ List.map text (
               ["  " ^ String.concat "  |  " (List.map (fun node -> "[" ^ name node.worker ^ "]") nodes)]
               @ List.map (fun node -> "    " ^ name node.worker ^ ": " ^ flow_worker_state node.worker) nodes)) layers)
             @ List.concat_map (fun node ->
                 Fact_heading ("Layer unavailable: " ^ name node.worker)
                 :: List.map text (match node.problems with
                    | [] -> ["  Cyclic or unresolved upstream dependency"]
                    | problems -> List.map (fun detail -> "  " ^ detail) problems)) unresolved in
         List.map text notices @ source_lines @ layer_lines
         @ (if workers=[] then [Fact_text "No current workers to place. Review installation issues or install a Plugin."] else [])
         @ [Fact_text ""; Fact_heading "Declared inputs and outputs"]
         @ List.map text (List.concat_map (fun instance ->
           let target = name instance in
           [(if Some instance.id = Option.map (fun i -> i.id) (selected_instance view) then "> " else "  ") ^ target ^ " · " ^ instance.title ^ " · " ^ phase_label instance.phase]
           @ (match flow_inputs instance.binding with
              | Error detail -> ["  Invalid source binding: " ^ detail]
              | Ok [] -> ["  No upstream Add-on dependency (D shows external/owned source binding)"]
              | Ok upstream -> List.concat_map (fun input ->
                  ["  " ^ input.installation_id ^ " -> " ^ target ^
                    (if historical then " · stored binding; producer incarnation unknown"
                    else match resolve_flow_input ~identity ~run_id:instance.run_id workers input with
                      | Producer_available _ -> ""
                      | Producer_ambiguous -> " · producer identity ambiguous across live workers"
                      | Output_missing port -> " · producer output unavailable: " ^ port
                      | Producer_missing -> if complete then " · producer absent in this run"
                          else " · producer unresolved; inventory incomplete")]
                  @ (match input.output_id with
                    | None -> []
                    | Some port -> ["    Input " ^ input.source_id ^ ": " ^ input.installation_id ^ "/" ^ port])) upstream)
           @ List.map (fun (port,selection) -> "  output " ^ port ^ " -> " ^ (match selection with Row.All_lanes -> "all supplied lanes" | Row.Selected_lanes lanes -> String.concat ", " lanes)) instance.outputs) workers))
  @ [Fact_text ""; Fact_heading "Result -> retained evidence -> explicit Keeper / Broadcast sharing -> agent use";
     Fact_text "Delivery acceptance and agent reading are separate recorded stages."]
  @ (match Option.map evidence_receipt_lines view.receipt with
     | Some (_ :: _ as receipt) -> Fact_heading "Last evidence sharing receipt · this session" :: List.map text receipt
     | Some [] | None -> [Fact_text "No evidence sharing receipt in this session."])
  @ [Fact_text
     (if embedded then "f:open full flow  D:technical details  J/K:scroll"
      else "f:back to observations  D:technical details  J/K:scroll")]

(* The Links tab: the selected Plugin's bound inputs and outputs, then its
   flow. Inputs and outputs are fields, so they share a label column with the
   fields of the flow. *)
let links_lines ~width view =
  let module S = Masc.Lane_addon_sources in
  let bound = match selected_instance view, view.snapshot with
    | Some item, Some _ ->
        (match S.parse item.binding with
         | Error detail -> [Fact_fields { indent = 0; fields = ["Input binding:", detail] }]
         | Ok [] -> [Fact_text "No bound inputs"]
         | Ok sources -> [Fact_fields { indent = 0; fields = List.map (function
             | S.Lane_output {installation_id;output_id;_} ->
                 "Input:", installation_id ^ "/" ^ Option.value ~default:"*" output_id
             | S.Snapshot_file {id;path} -> "Input:", id ^ " · " ^ path
             | S.Fusion_run {id;run_id} -> "Input:", id ^ " · Fusion " ^ run_id
             | S.Msx_capture {id} | S.Dos_capture {id}
             | S.Browser_document {id;_} -> "Input:", id) sources }])
        @ [Fact_fields { indent = 0; fields = List.map (fun (name,_) -> "Output:", name) item.outputs }]
    | Some _, None | None, (Some _ | None) -> [] in
  fact_spans ~width (bound @ (Fact_text "" :: flow_rows ~embedded:true view))

let lines ?(height=24) ?(failed_note = "") ~width view =
  match view.installer with
  | Some installer ->
      let render = document_rows ~width in
      let diagnostics = List.concat_map render (diagnostic_lines view) in
      diagnostics @ Masc_tui_lane_installer.lines ~height:(max 1 (height - List.length diagnostics)) ~render installer
  | None -> match view.evidence_prompt with
  | Some prompt ->
      (diagnostic_lines view @ evidence_lines prompt)
      |> List.concat_map (document_rows ~width)
  | None -> match view.subscription_panel,view.action_menu,view.records with
  | Some panel,_,_ ->
      (Masc_tui_message_layout.fit_width (if view.loading then "Refreshing…" else "Last received subscription state") (max 1 width)
       :: Masc_tui_lane_subscriptions.lines panel)
      |> List.concat_map (document_rows ~width)
  | None,Some menu,_ ->
      (match menu.row with
       | Some (Row_list {row_title;entries;_}) ->
           (* The title names the chosen row and the instance that produced
              it; an action the row cannot fill stays listed with why. *)
           [Printf.sprintf "Actions for %s · %s" row_title menu.target_title]
           @ diagnostic_lines view
           @ ["Up/Down:choose · Enter:open · Esc:cancel"]
           @ List.mapi (fun position (entry : row_entry) ->
               (if position=menu.cursor then "> " else "  ") ^ entry.label
               ^ (match entry.filled with
                  | Ok _ -> ""
                  | Error unfilled ->
                      " · unavailable: " ^ String.concat "; " (List.map unfilled_text unfilled))) entries
           @ [(if menu.cursor=List.length entries then "> " else "  ") ^ "Other action"]
       | Some (Row_form {label;_}) ->
           (* One sentence for what sending does: which instance receives
              which action. *)
           [Printf.sprintf "Sends \"%s\" to %s" label menu.target_title]
           @ diagnostic_lines view
           @ Option.fold ~none:[] ~some:(Masc_tui_schema_form.lines ~show_description:true) menu.form
       | None ->
           ["Run action on " ^ menu.target_title]
           @ diagnostic_lines view
           @ (match menu.form with
           | Some form -> Masc_tui_schema_form.lines ~show_description:true form
           | None -> [
            Printf.sprintf "Action %d/%d · Up/Down:choose · Enter:run once · Esc:cancel"
              (menu.cursor+1) (List.length menu.choices);
            "J/K:scroll action details"]
           @ (match List.nth_opt menu.choices menu.cursor with
              | Some action -> action_fields "" action
              | None -> ["No selected action"])))
      |> List.concat_map (document_rows ~width)
  | _,_,Some overlay ->
      (diagnostic_lines view @ Masc_tui_lane_records.lines overlay)
      |> List.concat_map (document_rows ~width)
  | None,None,None ->
      if view.help_open then help_lines ~width
      else if view.presentation = Flow then fact_spans ~width (flow_rows view)
      else if view.presentation = Technical && view.screen=Overview && view.focus=Configurations
        && Option.is_none view.document_key && Option.is_none view.draft
      then installation_detail_lines ~width view
      else if view.presentation = Technical || Option.is_some view.document_key || Option.is_some view.draft
      then technical_lines ~height ~failed_note ~width view
      else
        let receipt_lines = match view.receipt with
          | None -> []
          | Some json -> (match evidence_receipt_lines json with
              | [] -> []
              | receipt -> ["Last evidence receipt"] @ receipt @ [""]) in
        let receipt_lines = List.concat_map (document_rows ~width) receipt_lines in
        (match view.screen with
        | Overview -> overview_lines ~width view @ receipt_lines
        | Detail _ -> receipt_lines @ detail_lines ~height:(height - List.length receipt_lines) ~width view
            @ (match view.focus with
               | Connections -> links_lines ~width view
               | Timeline | Configurations | Instances | Rows -> []))

(* A TOML declaration may exist while no worker can run. Keep the file count,
   live worker count, and failures separate on the Lanes surface. *)
type reading_freshness = Current | Stale of string
type installation_reading =
  | Not_read
  | Observed of {
      declared : int;
      active : int;
      failed_workers : int;
      configuration_issues : int;
      complete : bool;
      freshness : reading_freshness;
    }

let installation_reading view =
  match view.snapshot with
  | None -> Not_read
  | Some snapshot ->
    (match snapshot.configuration with
     | None -> Not_read
     | Some configuration ->
       let active, failed_workers =
         List.fold_left (fun (active, failed) (instance : instance) ->
           match instance.phase with
           | Row.Attached | Row.Observing -> active + 1, failed
           | Row.Failed _ -> active, failed + 1
           | Row.Detaching | Row.Detached -> active, failed)
           (0, 0) snapshot.instances in
       Observed {
         (* Decoder also appends issue-only paths here when a TOML file could
            not be parsed. Those are problems to show, not declarations. *)
         declared = List.fold_left (fun count (declaration : declaration) ->
           match declaration.origin with
           | Parsed_declaration -> count + 1
           | Issue_only -> count)
           0 configuration.declarations;
         active;
         failed_workers;
         configuration_issues = List.fold_left (fun count (declaration : declaration) ->
           count + List.length declaration.issues)
           0 configuration.declarations;
         complete = configuration.complete;
         freshness = (match view.snapshot_read_error with
           | None -> Current
           | Some detail -> Stale detail);
       })
