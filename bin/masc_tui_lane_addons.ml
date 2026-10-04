module Row = Masc.Lane_addon_types
module Document = Masc_tui_lane_declaration
module Action = Masc.Lane_addon_action
type runtime_presence = Live_entry | Retained_binding | Presence_unknown
type instance = {
  id : string; run_id : string; addon_id : string; title : string;
  revision : string; phase : Row.phase; runtime_presence : runtime_presence;
  observation_seq : int; rows_count : int;
  installation_id : string option; source_path : string option; binding : Yojson.Safe.t; outputs : Row.output_ports;
  skills_directory : string option; incarnation : string; action_schema : Yojson.Safe.t option; binding_schema : Yojson.Safe.t option; display : Masc.Lane_addon_presentation.t;
}
type declaration_origin = Parsed_declaration | Issue_only
type declaration = {
  source_path : string; installation_id : string option; enabled : bool option; desired : string option;
  applied : string option; instance_id : string option; issues : string list;
  origin : declaration_origin;
}
type configuration = { directory : string; complete : bool; declarations : declaration list }
type snapshot = { instances : instance list; output : Row.output; complete : bool option;
  configuration : configuration option }
type action_request = { instance_id : string; incarnation : string; request_id : string; action : Yojson.Safe.t }
type request = Inspect | Attach of Yojson.Safe.t | Observe of string | Detach of string
  | Slice of (string * string) list | Evidence of Yojson.Safe.t
  | Act of action_request | Action_status of action_request
  | Subscriptions of Yojson.Safe.t
type action_menu = {
  target_id : string; target_incarnation : string; target_title : string; request_id : string;
  schema : Yojson.Safe.t; choices : Yojson.Safe.t list; cursor : int;
  form : Masc_tui_schema_form.t option;
}
type focus = Timeline | Connections | Configurations | Instances | Rows
type presentation = Summary | Technical | Flow
type screen = Overview | Detail of string * string
type overview_mode = Current_installations | Retained_runs
type overview_anchor = Worker_anchor of string * string | Declaration_anchor of string
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
  subscription_panel : Masc_tui_lane_subscriptions.t option;
  evidence_prompt : evidence_prompt option;
  pending_broadcasts : (Yojson.Safe.t * string) list;
  presentation : presentation; screen : screen; overview_mode : overview_mode; help_open : bool;
  current_selection : overview_selection; history_selection : overview_selection;
  action_menu : action_menu option;
  snapshot : snapshot option; loading : bool; error : diagnostic option;
  snapshot_read_error : string option;
  receipt : Yojson.Safe.t option; generation : int; instance_cursor : int;
  row_cursor : int; selected : string list; scroll : int; focus : focus;
  draft : string option; naming : bool; configuration_cursor : int;
  documents : Document.session list; document_key : string option; editor_ready : bool; last_action : action_request option; action_receipt : Action.receipt option;
}
let initial = { installer=None;subscription_panel=None;evidence_prompt=None; pending_broadcasts=[]; presentation=Summary; screen=Overview; overview_mode=Current_installations; help_open=false; current_selection=Unvisited; history_selection=Unvisited; action_menu=None; snapshot = None; loading = false; error = None; snapshot_read_error=None; receipt = None;
  generation = 0; instance_cursor = 0; row_cursor = 0; selected = []; scroll = 0;
  focus = Instances; draft = None; naming = false; configuration_cursor = 0;
  documents = []; document_key = None; editor_ready = false; last_action=None;action_receipt=None }
let ( let* ) = Result.bind
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
        let* source_path = get text "source_path" json in
        let* installation_id = get text "id" json in
        let* enabled = get boolean "enabled" json in
        let* desired = get text "desired_revision" json in
        let* applied = optional "applied_revision" text json in
        let* instance_id = optional "instance_id" text json in
        Ok {source_path;installation_id=Some installation_id;enabled=Some enabled;desired=Some desired;applied;instance_id;issues=[];origin=Parsed_declaration})) "declarations" json in
      let* issues = get (array (fun json ->
        let* source_path = get text "source_path" json in
        let* installation_id = optional "id" text json in
        let* message = get text "message" json in Ok (source_path, installation_id, message))) "issues" json in
      let declarations = List.fold_left (fun declarations (path, id, message) ->
        if List.exists (fun (d : declaration) -> d.source_path = path) declarations
        then List.map (fun (d : declaration) -> if d.source_path = path then {d with issues=d.issues @ [message]} else d) declarations
        else declarations @ [{source_path=path;installation_id=id;enabled=None;desired=None;applied=None;instance_id=None;issues=[message];origin=Issue_only}]) declarations issues in
      Ok (Some {directory;complete;declarations})
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
    Ok (installation_id, source_path)) json in
  let installation_id = Option.map fst owner in
  let source_path = Option.map snd owner in
  let* binding = field "binding" json in
  let* package = field "package" json in
  let* outputs = get output_ports "outputs" package in
  let* skills_directory = optional "skills_directory" text package in
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
  Ok { id; run_id; addon_id; title; revision; phase; runtime_presence; observation_seq; rows_count;
    installation_id;source_path;binding;outputs;skills_directory;incarnation;action_schema;binding_schema;display }
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
let row_owner instances (row : Row.row) =
  List.find_opt (fun (instance : instance) ->
    String.starts_with ~prefix:(instance.id ^ "/") row.lane_id) instances
let row_is_result (instance : instance) (row : Row.row) =
  match instance.display.readings with
  | [] -> true
  | readings -> List.exists (fun (reading : Masc.Lane_addon_presentation.reading) ->
      String.equal row.lane_id (instance.id ^ "/" ^ reading.lane_id)) readings
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
let overview_entries ?(mode=Current_installations) snapshot =
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
let overview_count ?(mode=Current_installations) snapshot = List.length (overview_entries ~mode snapshot)
let overview_anchor = function
  | `Instance (instance : instance) -> Worker_anchor (instance.id, instance.incarnation)
  | `Declaration (_, declaration) -> Declaration_anchor declaration.source_path
let toggle_history view = match view.screen with
  | Detail _ -> view
  | Overview ->
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
        focus=Instances;presentation=Summary;document_key=None}
let selected_document view = Option.bind view.document_key (fun key ->
  List.find_opt (fun (s : Document.session) -> s.file_name = key) view.documents)
let put_document view (document : Document.session) =
  {view with documents=document :: List.filter (fun (s : Document.session) -> s.file_name <> document.file_name) view.documents;
    document_key=Some document.file_name}
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
      let previous_entries = overview_entries ~mode:view.overview_mode previous in
      let entries = overview_entries ~mode:view.overview_mode snapshot in
      let instance_cursor =
        if previous_entries=[] && entries<>[] then 0
        else anchor (function
          | `Instance (instance : instance) -> `Instance (instance.id, instance.incarnation)
          | `Declaration (_, declaration) -> `Declaration declaration.source_path)
          previous_entries entries view.instance_cursor in
      {view with snapshot=Some snapshot; row_cursor; instance_cursor;
        configuration_cursor}
let selected_instance view = Option.bind view.snapshot (fun snapshot ->
  match view.screen with
  | Detail (id, incarnation) ->
      List.find_opt (fun (instance : instance) ->
        String.equal instance.id id && String.equal instance.incarnation incarnation) snapshot.instances
  | Overview ->
      (match view.focus with
       | Configurations when view.presentation=Technical -> Option.bind (selected_declaration view) (fun declaration ->
           Option.bind declaration.instance_id (fun id ->
             List.find_opt (fun (instance : instance) ->
               instance.id=id && (match view.overview_mode with
                 | Current_installations -> not (retained instance)
                 | Retained_runs -> true)) snapshot.instances))
       | Timeline | Rows | Configurations | Connections | Instances ->
           (match at_cursor (overview_entries ~mode:view.overview_mode snapshot) view.instance_cursor with
            | Some (`Instance item) -> Some item | Some (`Declaration _) | None -> None)))
let ordered_rows view snapshot =
  rows_in_screen view snapshot
  |> List.stable_sort (fun (_, (a : Row.row)) (_, (b : Row.row)) ->
    let time = Float.compare a.observed_at b.observed_at in
    if time=0 then String.compare a.id b.id else time)
(* Presentation readings identify user-facing results. Supporting context
   records stay available in Records and raw details without becoming result
   navigation targets. Packages without readings retain their generic view. *)
let ordered_result_rows view snapshot =
  let rows = ordered_rows view snapshot in
  match view.screen, detail_instance view snapshot with
  | Detail _, Some item ->
      List.filter (fun (_, row) -> row_is_result item row) rows
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
      match at_cursor (overview_entries ~mode:view.overview_mode snapshot) view.instance_cursor with
      | Some (`Declaration (index, _)) ->
          {view with focus=Configurations; configuration_cursor=index;
            presentation=Technical; scroll=0; selected=[]; document_key=None}
      | Some (`Instance item) ->
          select_initial_result {view with screen=Detail (item.id,item.incarnation); focus=Timeline;
            scroll=0; selected=[]; document_key=None}
      | None -> view
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
  | _ -> view
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
        | Configurations, _ -> Option.map (fun (d : declaration) -> d.source_path) (selected_declaration view)
        | Instances, Overview ->
            (match at_cursor (overview_entries ~mode:view.overview_mode snapshot) view.instance_cursor with
             | Some (`Declaration (_, declaration)) -> Some declaration.source_path
             | Some (`Instance _) | None -> instance_path)
        | (Timeline | Connections | Instances | Rows), _ -> instance_path in
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
                && (match instance.phase with Row.Attached | Row.Observing -> true | _ -> false)) instances with
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
let timeline_lines ?(instances=[]) ?selected ~width rows =
  match rows with
  | [] -> List.map (fun instance -> instance.title ^ " | " ^ phase_label instance.phase
      ^ " | no observations in this view") instances
  | first :: rest ->
      let first : Row.row = first in
      let since, until = List.fold_left (fun (a, b) (row : Row.row) ->
        min a row.observed_at, max b row.observed_at) (first.observed_at, first.observed_at) rest in
      let label_width = min 28 (max 8 (width / 3)) in
      let axis_width = max 2 (width - label_width - 4) in
      let lanes = (List.map (fun (row : Row.row) -> row.lane_id) rows
        @ List.concat_map (fun instance -> List.concat_map (fun (_,selection) ->
            match selection with Row.All_lanes -> []
            | Row.Selected_lanes lanes -> List.map (fun lane -> instance.id ^ "/" ^ lane) lanes) instance.outputs) instances)
        |> List.sort_uniq String.compare in
      let label lane =
        match String.index_opt lane '/' with
        | Some separator when separator > 0 ->
            let instance = String.sub lane (max 0 (separator - 8)) (min 8 separator) in
            let local = String.sub lane (separator + 1) (String.length lane - separator - 1) in
            let suffix = " · " ^ instance in
            let local_width = label_width - Masc_tui_message_layout.display_width suffix in
            if local_width > 0 then Masc_tui_message_layout.fit_width local local_width ^ suffix
            else Masc_tui_message_layout.fit_width local label_width
        | _ -> Masc_tui_message_layout.fit_width lane label_width in
      let position time = if since = until then axis_width / 2 else
        let span = until -. since in
        let fraction = if Float.is_finite span then (time -. since) /. span
          else (time /. 2. -. since /. 2.) /. (until /. 2. -. since /. 2.) in
        max 0 (min (axis_width - 1) (int_of_float (fraction *. float_of_int (axis_width - 1)))) in
      [Printf.sprintf "Wall time %.3f → %.3f · o event · v value · * relation" since until]
      @ List.map (fun lane ->
          let axis = Bytes.make axis_width '-' in
          List.iter (fun (row : Row.row) -> if row.lane_id = lane then
            Bytes.set axis (position row.observed_at) (match row.kind with Row.Event -> 'o' | Row.Value -> 'v' | Row.Relation -> '*')) rows;
          (match selected with Some (row : Row.row) when row.lane_id=lane -> ">" | _ -> " ")
          ^ label lane ^ " |" ^ Bytes.to_string axis ^ "|") lanes
      @ List.filter_map (fun instance ->
          if List.exists (fun (row : Row.row) ->
            String.starts_with ~prefix:(instance.id ^ "/") row.lane_id) rows then None
          else Some (instance.title ^ " | " ^ phase_label instance.phase ^ " | no observations in this view")) instances
let configuration_lines view snapshot = match snapshot.configuration with
  | None -> ["TOML configuration status unknown"]
  | Some config ->
      ["TOML installations · " ^ config.directory ^ (if config.complete then " · inventory complete" else " · inventory partial")]
      @ List.concat (List.mapi (fun index (declaration : declaration) ->
        [Printf.sprintf "%s %s · %s" (if view.configuration_cursor=index then ">" else " ")
           (Option.value ~default:"unresolved installation" declaration.installation_id) declaration.source_path;
         (match declaration.enabled, declaration.instance_id with
          | Some false, Some _ -> "   Off requested · worker cleanup not yet confirmed"
          | Some false, None -> "   Configured off · no current worker observed"
          | Some true, _ -> "   Configured on"
          | None, _ -> "   Desired activity unknown");
         "   desired " ^ Option.value ~default:"unknown" declaration.desired;
         "   applied " ^ Option.value ~default:"none" declaration.applied]
        @ (if Document.editable_source_path ~directory:config.directory declaration.source_path then []
           else ["   Configuration issue; no declaration file to edit"])
        @ List.map (fun message -> "   Error: " ^ message) declaration.issues) config.declarations)
let instance_lines view instances =
  List.concat (List.mapi (fun i item ->
    [Printf.sprintf "%s %s · %s · %s · run %s · rev %s · seq %d · rows %d"
       (if view.instance_cursor=i then ">" else " ") item.id item.title (phase_label item.phase)
       item.run_id item.revision item.observation_seq item.rows_count;
     "   TOML " ^ Option.value ~default:"manual attachment" item.source_path;
     "   binding"]
    @ List.map (fun line -> "     " ^ line) (String.split_on_char '\n' (Yojson.Safe.pretty_to_string item.binding))
    @ List.map (fun (id, selection) -> "   output " ^ id ^ " → " ^ (match selection with
      | Row.All_lanes -> "all supplied lanes" | Row.Selected_lanes lanes -> String.concat ", " lanes)) item.outputs
    @ (match item.skills_directory with None -> [] | Some directory -> ["   Skills " ^ directory])
    @ (match item.action_schema with None -> [] | Some schema ->
        ["   action schema · incarnation " ^ item.incarnation]
        @ List.map (fun line -> "     " ^ line) (String.split_on_char '\n' (Yojson.Safe.pretty_to_string schema)))) instances)
let action_lines view = match view.last_action with
    | None -> []
    | Some request -> ["Action request " ^ request.request_id ^ " · t:read status (never replays)";
        "  instance " ^ request.instance_id ^ " · incarnation " ^ request.incarnation]
        @ (match view.action_receipt with
          | None -> ["  receipt unknown; t queries this exact request"]
          | Some receipt -> ["  state " ^ (match receipt.Action.state with
              | Action.Queued -> "queued" | Action.Running -> "running" | Action.Confirmed -> "confirmed"
              | Action.Failed_before_effect -> "failed_before_effect" | Action.Outcome_unknown -> "outcome_unknown");
              "  requester " ^ receipt.requester ^ " · executor " ^ Option.value ~default:"unknown" receipt.executor]
              @ (match receipt.detail with None -> [] | Some detail -> ["  " ^ detail])
              @ (match receipt.result with None -> [] | Some result -> String.split_on_char '\n' (Yojson.Safe.pretty_to_string result)))
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
        |> List.sort_uniq String.compare in
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

let previous_read_note (view : t) =
  match view.snapshot_read_error, view.error with
  | Some detail, Some (Detail_read_failure _ | Request_failure _ | Input_failure _) ->
      Some ("Previous Add-ons read: " ^ detail)
  | (Some _ | None), None | None, Some _ -> None

let diagnostic_lines view =
  Option.to_list (Option.map diagnostic_text view.error)
  @ (match view.snapshot_read_error, view.error with
     | Some detail, None -> ["Read: " ^ detail]
     | Some _, Some _ -> Option.to_list (previous_read_note view)
     | None, (Some _ | None) -> [])

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
  match previous_read_note view with
  | None -> current
  | Some note -> current ^ " · " ^ note

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
  let wrap text =
    Masc_tui_message_layout.split_cells ~max_cells:(max 1 width)
      (Masc.Tui_terminal_text.sanitize_terminal_text text) in
  let raw_row (row : Row.row) =
    [row.title; "Row " ^ row.id; "Lane " ^ row.lane_id;
     "Observed " ^ utc_stamp row.observed_at ^ " UTC";
     "Subject " ^ row.subject_id]
    @ Option.to_list (Option.map (fun actor -> "Actor " ^ actor) row.actor)
    @ Option.to_list (Option.map (fun (clock : Row.clock) ->
        "Clock " ^ clock.domain ^ " · " ^ clock.value) row.clock)
    @ String.split_on_char '\n' (Yojson.Safe.pretty_to_string (`Assoc row.fields))
    @ List.map (fun (e : Row.evidence) ->
        "Evidence " ^ e.uri ^ " · sha256 " ^ Option.value ~default:"unknown" e.sha256)
        row.evidence
    @ (if row.related_ids=[] then []
       else ["Related " ^ String.concat ", " row.related_ids]) in
  let content = match view.snapshot with
    | None -> [unread_body_text ~failed_note view]
    | Some snapshot ->
        let selected = match view.screen with
          | Overview -> at_cursor (overview_entries ~mode:view.overview_mode snapshot) view.instance_cursor
          | Detail _ -> Option.map (fun item -> `Instance item)
              (detail_instance view snapshot) in
        let worker = match selected with
          | Some (`Instance item) -> instance_lines {view with instance_cursor=0} [item]
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
        ["Raw details";
         "Snapshot " ^ (match snapshot.complete with
           | Some true -> "complete" | Some false -> "partial" | None -> "unknown")]
        @ (if rows=[] then [] else "Records" :: List.concat_map raw_row rows)
        @ worker @ configuration
        @ (if snapshot.output.coverage=[] then [] else
             "Coverage" :: List.map (fun (source : Row.coverage) ->
               source.source_id ^ " · " ^ (if source.complete then "complete" else "partial")
               ^ " · incarnation " ^ source.incarnation
               ^ " · cursor " ^ Option.value ~default:"unknown" source.cursor
               ^ Option.fold ~none:"" ~some:(fun detail -> " · " ^ detail) source.detail)
               snapshot.output.coverage) in
  let receipt = match view.receipt with
    | None -> []
    | Some json ->
        evidence_receipt_lines json
        @ ("Last receipt:" :: String.split_on_char '\n' (Yojson.Safe.pretty_to_string json)) in
  let draft = match view.draft with
    | None -> []
    | Some text -> [(if view.naming then "New TOML filename: " else "Add-on command: ") ^ text] in
  let document = match selected_document view with
    | None -> [] | Some session -> Document.summary session in
  List.concat_map wrap
    (["?:help  Esc:back  J/K:scroll"] @ diagnostic_lines view @ content @ draft @ document
     @ action_lines view @ receipt)

let installation_detail_lines ~width view =
  let wrap line = Masc_tui_message_layout.split_cells ~max_cells:(max 1 width)
      (Masc.Tui_terminal_text.sanitize_terminal_text line) in
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
  | _ -> None

let action_target view = selected_instance view

let can_observe (instance : instance) = match instance.phase with
  | Row.Attached | Row.Observing | Row.Failed _ -> true
  | Row.Detaching | Row.Detached -> false

let instance_controls (instance : instance) =
  let removal = match instance.source_path with
    | Some _ -> "  d:remove TOML + worker"
    | None -> "  d:remove worker" in
  match instance.phase with
  | Row.Attached | Row.Observing ->
      "o:observe" ^ (if Option.is_some instance.action_schema then "  a:actions" else "") ^ removal
  | Row.Detaching -> "worker cleanup pending"
  | Row.Detached -> "retained history · D:details"
  | Row.Failed _ -> "o:retry observation" ^
      (if Option.is_some instance.action_schema then "  a:actions" else "") ^ removal

(* [drop_hint_items] drops whole items from the back. Keep the way out at
   the front so it remains easy to find even when the other hints give way. *)
let overview_hints view =
  if view.help_open then "Esc:close help"
  else if Option.is_some view.document_key then
    "?:help  Esc:back  Space:on/off draft  E:edit  s:save  l:reload  u/U:revision  Colon:palette  A:command"
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
      (match selected_instance view with None -> "" | Some instance -> instance_controls instance ^ "  ") ^
      "D:raw  J/K:scroll"
      ^ (if view.loading then "  Reading …" else "  r:refresh")

let open_actions ~request_id view =
  let* instance = match action_target view with
    | Some instance -> Ok instance
    | None -> Error "Selected installation or event has no available worker; select an instance explicitly" in
  let* () = if can_observe instance then Ok () else Error "This instance is unavailable for actions; D shows its state and retained evidence." in
  let* schema = match instance.action_schema with
    | Some schema -> Ok schema
    | None -> Error "This Add-on provides observations only. Press o to observe." in
  let* () = Action.validate_schema schema in
  let* action_schema =
    let* properties = field "properties" schema in
    field "action" properties in
  let* choices,form = match finite_values action_schema with
    | Some (_::_ as choices) -> Ok (choices,None)
    | Some [] | None ->
        let* form = Masc_tui_schema_form.create ~schema:action_schema ~initial:(`Assoc []) in
        Ok ([],Some form) in
  let choices = List.filter (fun action ->
    Result.is_ok (Action.validate ~schema ~name:"lane_act"
      (Action.arguments ~instance_id:instance.id ~request_id ~action))) choices in
  if choices=[] && Option.is_none form then Error "The advertised schema has no valid preset action. D shows details."
  else Ok {view with action_menu=Some {
    target_id=instance.id;target_incarnation=instance.incarnation;target_title=instance.title;request_id;
    schema;choices;form;cursor=0}; presentation=Summary;scroll=0;error=None}

let move_action view delta =
  {view with scroll=0;action_menu=Option.map (fun menu ->
    {menu with cursor=max 0 (min (List.length menu.choices - 1) (menu.cursor+delta))}) view.action_menu}

let submit_action view =
  let* menu = match view.action_menu with
    | Some menu -> Ok menu | None -> Error "Choose an action first." in
  let* instance = match Option.bind view.snapshot (fun snapshot ->
    List.find_opt (fun instance -> String.equal instance.id menu.target_id
      && String.equal instance.incarnation menu.target_incarnation
      && instance.action_schema=Some menu.schema) snapshot.instances) with
    | Some instance -> Ok instance
    | None -> Error "The selected Add-on changed. Refresh and choose its action again." in
  let* action = match menu.form with
    | Some form -> Masc_tui_schema_form.value form
    | None -> (match List.nth_opt menu.choices menu.cursor with
      | Some action -> Ok action | None -> Error "No selected action.") in
  let* action = Action.canonical action in
  let* _ = Action.validate ~schema:menu.schema ~name:"lane_act"
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

(* The row title is the producer's human label. Numeric/boolean readings fit
   the overview; full strings, nested coordinates and evidence remain in D. *)
let reading_summary fields =
  fields |> List.filter_map (fun (key,value) -> match value with
    | (`Int _ | `Intlit _ | `Float _ | `Bool _) ->
        Some (key ^ "=" ^ Yojson.Safe.to_string value)
    | _ -> None) |> String.concat " · "

let result_lines (instance : instance) (row : Row.row) =
  let module P = Masc.Lane_addon_presentation in
  let readings = List.filter (fun (reading : P.reading) ->
    String.equal row.lane_id (instance.id ^ "/" ^ reading.lane_id))
    instance.display.readings in
  match readings with
  | [] ->
      let summary = reading_summary row.fields in
      if summary="" then [] else ["  " ^ summary]
  | readings -> List.concat_map (fun (reading : P.reading) ->
      let rendered = match P.render reading (`Assoc row.fields) with
        | Ok text -> text
        | Error detail -> reading.label ^ ": unavailable · " ^ detail in
      Masc_tui_text_block.lines rendered
      |> List.map (fun line -> "  " ^ line)) readings

let installation_identity (instance : instance) = instance.installation_id

let installation_name (instance : instance) =
  match installation_identity instance with
  | Some id -> id
  | None -> instance.id

let instance_heading _snapshot (item : instance) =
  match installation_identity item with
  | None -> item.title
  | Some name -> name ^ " · " ^ item.title

let empty_result_lines (item : instance) =
  match item.phase with
  | Row.Failed detail -> ["Add-on failed: " ^ detail; instance_controls item]
  | Row.Attached | Row.Observing | Row.Detaching | Row.Detached ->
      if item.observation_seq=0 then ["No completed observation received yet."]
      else if item.rows_count=0 then
        ["Last completed observation contains no result rows.";
         "Check input coverage and 2 Links for declared inputs."]
      else ["No result rows in this received view."; "r:refresh · D:raw details"]

let snapshot_coverage_lines coverage =
  if coverage=[] then [] else
    [""; "Received snapshot coverage · all Add-ons"]
    @ List.map (fun (source : Row.coverage) ->
        source.source_id ^ " · " ^ (if source.complete then "complete" else "PARTIAL")
        ^ " · cursor " ^ Option.value ~default:"unknown" source.cursor
        ^ Option.fold ~none:"" ~some:(fun detail -> " · " ^ detail) source.detail) coverage

let overview_lines ~width view =
  let wrap text = Masc_tui_message_layout.split_cells ~max_cells:(max 1 width)
    (Masc.Tui_terminal_text.sanitize_terminal_text text) in
  let content = match view.snapshot with
    | None -> [unread_body_text ~failed_note:"Read failed · r:retry" view]
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
        let heading = Printf.sprintf "Lane Add-ons · %s · %d active · %d failed workers%s"
          configuration_summary active failed
          (if Option.is_some view.snapshot_read_error then " · STALE" else "") in
        let entries = overview_entries ~mode:view.overview_mode snapshot in
        (* Keep the selected entry first: wrapped history/count context already
           spends rows before the list in a narrow terminal. *)
        let window = max 0 view.instance_cursor in
        let items = List.mapi (fun index item -> index,item) entries
          |> List.filter (fun (index,_) -> index >= window && index < window + 9) in
        let empty = match view.overview_mode, snapshot.configuration with
          | Retained_runs, _ when entries=[] -> ["No retained runs in this snapshot. h:current installations"]
          | Retained_runs, _ -> []
          | Current_installations, Some {complete=true;declarations=[];_} when count=0 ->
              ["No Add-ons installed. i:install a package  n:new TOML"]
          | Current_installations, Some {complete=false;_} when entries=[] -> ["Installation inventory incomplete · r:refresh"]
          | Current_installations, None when entries=[] -> ["TOML installation status unknown · r:refresh"]
          | Current_installations, (Some _ | None) -> [] in
        [heading;
         (match view.overview_mode with
          | Current_installations -> Printf.sprintf "Retained history · %d instances · h:open" retained_count
          | Retained_runs -> Printf.sprintf "Retained history · %d instances · h:current installations" retained_count);
         ""] @ empty
        @ List.concat_map (fun (index,item) ->
            let marker = if index=view.instance_cursor then "> " else "  " in
            match item with
            | `Declaration (_, declaration) ->
                let name = Option.value ~default:"unresolved installation" declaration.installation_id in
                let status = if Option.is_none declaration.desired then "configuration issue"
                  else if declaration.issues<>[] then "needs attention"
                  else if declaration.enabled=Some false then "configured off"
                  else if Option.is_some declaration.applied then "no current worker" else "pending" in
                let edit = Option.bind snapshot.configuration (fun config ->
                  if Document.editable_source_path ~directory:config.directory declaration.source_path
                  then Some "  E:edit" else None) |> Option.value ~default:"" in
                [marker ^ name ^ " · " ^ status ^ " · " ^ Filename.basename declaration.source_path;
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
                let activity = match snapshot.configuration with
                  | Some config when List.exists (fun (d : declaration) ->
                      d.enabled = Some false && d.instance_id = Some item.id
                      && Some d.source_path = item.source_path) config.declarations ->
                      "off requested · "
                  | Some _ | None -> "" in
                let lead = marker ^ instance_heading snapshot item ^ " · " ^
                  activity ^
                  (match item.phase with Row.Failed _ -> "failed" | _ -> phase_label item.phase) ^
                  " · " ^ count_text in
                let controls = "    Enter:open  " ^ instance_controls item in
                let detail = match item.phase with
                  | Row.Failed detail ->
                      Masc_tui_message_layout.wrap_words ~max_cells:(max 1 (width - 4))
                        ("D:full · " ^ detail)
                      |> List.map (fun line -> "    " ^ line)
                  | _ -> [] in
                group_header @ [lead]
                @ (match view.overview_mode with Current_installations -> []
                   | Retained_runs -> ["    Instance " ^ item.id])
                @ (if index=view.instance_cursor then
                     Option.to_list (Option.map (fun text -> "    " ^ text) item.display.description)
                   else [])
                @ [controls] @ detail) items
  in
  List.concat_map wrap (diagnostic_lines view @ content
    @ [""; overview_hints view] @ action_lines view)

let help_lines = [
  "Lane Add-ons keys · Esc:close";
  "List: j/k select · Enter open · h history/current · i install · n new TOML";
  "Detail: 1 Results · 2 Links · 3 Installation · 4 Records · Tab next";
  "Both: ?:help · Esc back · q back · r refresh · J/K scroll";
  "Actions: o observe/retry · d remove TOML/worker · a advertised actions";
  "TOML-managed removal deletes the matching declaration from disk and cleans up its owned worker.";
  "Manual attachments remove only the worker and its owned resources.";
  "Declarations now owned by another instance are preserved; observations and evidence remain.";
  "Actions: t check last request · D raw details · f flow";
  "Installation: Space on/off draft · E edit · s save · l reload · u/U revision";
  "Saving off keeps the TOML and evidence; r reads the actual worker cleanup state.";
  "Links: S subscriptions · Left/Right lane";
  "Records: Space mark row · e export marked rows";
  "Navigation: : command palette · Esc returns to Lane Add-ons";
  "Advanced: A opens Add-on commands · Enter submits (including act or detach ID)";
]

let detail_lines ~width view =
  let wrap text = Masc_tui_message_layout.split_cells ~max_cells:(max 1 width)
    (Masc.Tui_terminal_text.sanitize_terminal_text text) in
  match selected_instance view, view.snapshot with
  | None, _ -> ["The selected Add-on changed. Esc returns to the list."]
  | Some item, Some snapshot ->
      let tab focus label = if view.focus=focus then "[" ^ label ^ "]" else label in
      let header = instance_heading snapshot item ^ " · " ^ phase_label item.phase in
      let tabs = String.concat "  " [
        tab Timeline "1 Results"; tab Connections "2 Links";
        tab Configurations "3 Installation"; tab Rows "4 Records"] in
      let record_rows = List.map snd (ordered_rows view snapshot) in
      let rows = List.map snd (ordered_result_rows view snapshot) in
      let selected = selected_row view in
      let body = match view.focus with
      | Timeline | Instances ->
          let selected = Option.bind selected (fun selected ->
            List.find_opt (fun (row : Row.row) -> row.id = selected.id) rows) in
          if rows=[] then Option.to_list item.display.description
            @ (if record_rows=[] then empty_result_lines item
               else ["No declared result rows in this received view.";
                     "Supporting records remain available in 4 Records."])
            @ snapshot_coverage_lines snapshot.output.coverage
          else Option.to_list item.display.description
            @ [""; "Results"]
            @ (match selected with
               | None -> ["Choose a result with j/k."; ""]
               | Some row ->
                   ["> " ^ row.title; "  Lane " ^ row.lane_id; "  " ^ utc_stamp row.observed_at ^ " UTC"]
                   @ result_lines item row @ [""])
            @ (let other_rows = List.filter (fun (row : Row.row) ->
                 match selected with
                 | None -> true
                 | Some selected -> not (String.equal selected.id row.id)) rows in
               if other_rows=[] then [] else
                 ["Other results · j/k to select"]
                 @ List.map (fun (row : Row.row) -> "  " ^ row.title) other_rows
                 @ [""])
            @ ["Activity timeline"]
            @ timeline_lines ~width ~instances:[item] ?selected rows
            @ snapshot_coverage_lines snapshot.output.coverage
      | Connections ->
          let sources = match Masc.Lane_addon_sources.parse item.binding with
            | Error detail -> ["Input binding: " ^ detail]
            | Ok [] -> ["No bound inputs"]
            | Ok sources -> List.map (fun source ->
                let module S = Masc.Lane_addon_sources in
                match source with
                | S.Lane_output {installation_id;output_id;_} ->
                    "Input: " ^ installation_id ^ "/" ^ Option.value ~default:"*" output_id
                | S.Snapshot_file {id;path} -> "Input: " ^ id ^ " · " ^ path
                | S.Fusion_run {id;run_id} -> "Input: " ^ id ^ " · Fusion " ^ run_id
                | S.Msx_capture {id} | S.Dos_capture {id}
                | S.Browser_document {id;_} -> "Input: " ^ id) sources in
          sources @ List.map (fun (name,_) -> "Output: " ^ name) item.outputs
      | Configurations ->
          ["Source: " ^ Option.value ~default:"not supplied" item.source_path;
           "Revision: " ^ item.revision;
           "Instance: " ^ item.id]
          @ (match snapshot.configuration with
             | None -> ["Installation inventory unavailable"]
             | Some config ->
                 List.concat_map (fun (declaration : declaration) ->
                   if Some declaration.source_path = item.source_path
                   then ["Current declaration: " ^ (match declaration.enabled with
                           | Some true -> "configured on"
                           | Some false -> "configured off"
                           | None -> "desired activity unknown");
                         "Desired: " ^ Option.value ~default:"unknown" declaration.desired;
                         "Applied: " ^ Option.value ~default:"unknown" declaration.applied]
                        @ List.map (fun issue -> "Issue: " ^ issue) declaration.issues
                   else []) config.declarations)
      | Rows ->
          if record_rows=[] then empty_result_lines item
          else List.concat_map (fun (row : Row.row) ->
            [(if Option.fold ~none:false ~some:(fun (selected : Row.row) -> selected.id = row.id)
                 selected then "> " else "  ")
             ^ (if List.mem row.id view.selected then "[selected] " else "") ^ row.title;
             "Row " ^ row.id;
             Yojson.Safe.pretty_to_string (`Assoc row.fields)]
            @ List.map (fun (e : Row.evidence) ->
              "Evidence " ^ e.uri ^ " · sha256 " ^
              Option.value ~default:"unknown" e.sha256) row.evidence) record_rows in
      List.concat_map wrap (["?:help  Esc:back  Tab:section  j/k:move  D:raw"; header; tabs; ""]
        @ diagnostic_lines view @ body)
  | Some _, None -> ["Reading Add-ons…"]

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

let flow_lines ?(embedded=false) view =
  (match selected_instance view with
   | None -> ["No selected Add-on action target"]
   | Some instance -> ["Action target: " ^ instance.title ^ " · " ^ instance.id])
  @ ["Declared Add-on layers · last received snapshot";
     "Same layer: independent dependencies. Downward: declared upstream -> consumer.";
     "Layer placement describes wiring; execution and delivery need their own receipts."]
  @ (match view.error with
     | None -> []
     | Some ((Detail_read_failure _ | Request_failure _ | Input_failure _) as diagnostic) ->
         [diagnostic_text diagnostic])
  @ (match view.snapshot_read_error, view.snapshot with
     | Some detail, Some _ -> ["Read: " ^ detail ^ " · previous graph retained"]
     | Some detail, None -> ["Read: " ^ detail]
     | None, (Some _ | None) -> [])
  @ (match view.snapshot with
     | None -> ["Connections unavailable: no snapshot read yet"]
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
         let source_lines = [""; "Bound external inputs · declared sources"]
           @ (if external_inputs=[] then ["  No external source bindings in this view"]
              else external_inputs)
           @ [""; "Add-on layers · worker state and latest completed result summary"] in
         let layers, unresolved = if historical then [], [] else declared_layers ~identity workers in
         let layer_lines = if historical then
             ["Stored bindings · producer incarnations are not reconstructed as current layers"]
           else List.concat (List.mapi (fun index nodes ->
             [(if index=0 then "" else "    ↓"); "Layer " ^ string_of_int index;
              "  " ^ String.concat "  |  " (List.map (fun node -> "[" ^ name node.worker ^ "]") nodes)]
             @ List.map (fun node -> "    " ^ name node.worker ^ ": " ^ flow_worker_state node.worker) nodes) layers)
             @ List.concat_map (fun node ->
                 ["Layer unavailable: " ^ name node.worker]
                 @ (match node.problems with
                    | [] -> ["  Cyclic or unresolved upstream dependency"]
                    | problems -> List.map (fun detail -> "  " ^ detail) problems)) unresolved in
         notices @ source_lines @ layer_lines
         @ (if workers=[] then ["No current workers to place. Review installation issues or install an Add-on."] else [])
         @ [""; "Declared inputs and outputs"]
         @ List.concat_map (fun instance ->
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
           @ List.map (fun (port,selection) -> "  output " ^ port ^ " -> " ^ (match selection with Row.All_lanes -> "all supplied lanes" | Row.Selected_lanes lanes -> String.concat ", " lanes)) instance.outputs) workers)
  @ [""; "Result -> retained evidence -> explicit Keeper / Broadcast sharing -> agent use";
     "Delivery acceptance and agent reading are separate recorded stages."]
  @ (match Option.map evidence_receipt_lines view.receipt with
     | Some (_ :: _ as receipt) -> ["Last evidence sharing receipt · this session"] @ receipt
     | Some [] | None -> ["No evidence sharing receipt in this session."])
  @ [
     (if embedded then "f:open full flow  D:technical details  J/K:scroll"
      else "f:back to observations  D:technical details  J/K:scroll")]

let lines ?(height=24) ?(failed_note = "") ~width view =
  match view.installer with
  | Some installer ->
      ((if view.loading then ["Reading package and image state · Esc:cancel"] else [])
       @ diagnostic_lines view
       @ Masc_tui_lane_installer.lines installer)
      |> List.concat_map (fun line -> Masc_tui_message_layout.split_cells ~max_cells:(max 1 width)
        (Masc.Tui_terminal_text.sanitize_terminal_text line))
  | None -> match view.evidence_prompt with
  | Some prompt ->
      (diagnostic_lines view @ evidence_lines prompt)
      |> List.concat_map (fun line -> Masc_tui_message_layout.split_cells ~max_cells:(max 1 width)
           (Masc.Tui_terminal_text.sanitize_terminal_text line))
  | None -> match view.subscription_panel,view.action_menu with
  | Some panel,_ ->
      (Masc_tui_message_layout.fit_width (if view.loading then "Refreshing…" else "Last received subscription state") (max 1 width)
       :: Masc_tui_lane_subscriptions.lines panel)
      |> List.concat_map (fun line -> Masc_tui_message_layout.split_cells ~max_cells:(max 1 width)
           (Masc.Tui_terminal_text.sanitize_terminal_text line))
  | None,Some menu ->
      (["Run action on " ^ menu.target_title]
       @ diagnostic_lines view
       @ (match menu.form with
       | Some form -> Masc_tui_schema_form.lines form
       | None -> [
        Printf.sprintf "Action %d/%d · Up/Down:choose · Enter:run once · Esc:cancel"
          (menu.cursor+1) (List.length menu.choices);
        "J/K:scroll action details"]
       @ (match List.nth_opt menu.choices menu.cursor with
          | Some action -> action_fields "" action
          | None -> ["No selected action"])))
      |> List.concat_map (fun line ->
        Masc_tui_message_layout.split_cells ~max_cells:(max 1 width)
          (Masc.Tui_terminal_text.sanitize_terminal_text line))
  | None,None ->
      if view.help_open then List.map (fun line ->
        Masc_tui_message_layout.fit_width line (max 1 width)) help_lines
      else if view.presentation = Flow then flow_lines view |> List.concat_map
        (fun line -> Masc_tui_message_layout.split_cells ~max_cells:(max 1 width) (Masc.Tui_terminal_text.sanitize_terminal_text line))
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
        let receipt_lines = List.concat_map (fun line ->
          Masc_tui_message_layout.split_cells ~max_cells:(max 1 width)
            (Masc.Tui_terminal_text.sanitize_terminal_text line)) receipt_lines in
        (match view.screen with
        | Overview -> overview_lines ~width view @ receipt_lines
        | Detail _ -> receipt_lines @ detail_lines ~width view
            @ (match view.focus with
               | Connections -> [""] @ (flow_lines ~embedded:true view |> List.concat_map (fun line ->
                   Masc_tui_message_layout.split_cells ~max_cells:(max 1 width)
                     (Masc.Tui_terminal_text.sanitize_terminal_text line)))
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
