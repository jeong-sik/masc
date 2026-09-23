module Row = Masc.Lane_addon_types
module Document = Masc_tui_lane_declaration
module Action = Masc.Lane_addon_action
type instance = {
  id : string; run_id : string; addon_id : string; title : string;
  revision : string; phase : Row.phase; observation_seq : int; rows_count : int;
  source_path : string option; binding : Yojson.Safe.t; outputs : Row.output_ports;
  skills_directory : string option; incarnation : string; action_schema : Yojson.Safe.t option; binding_schema : Yojson.Safe.t option; display : Masc.Lane_addon_presentation.t;
}
type declaration = {
  source_path : string; installation_id : string option; desired : string option;
  applied : string option; instance_id : string option; issues : string list;
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
(* Marked rows leave the view as one frozen bundle under their owning worker.
   Handing the bundle's reference to a Keeper is a separate choice made here by
   name, so the operator neither types JSON nor delivers by accident. [choice] 0
   preserves only; [choice] n selects [List.nth keepers (n-1)]. Delivery is an
   optional message the Keeper may use, defer or ignore. *)
type evidence_prompt = {
  evidence : Yojson.Safe.t; owner_title : string; row_count : int;
  keepers : string list; choice : int;
}
type t = {
  installer : Masc_tui_lane_installer.t option;
  subscription_panel : Masc_tui_lane_subscriptions.t option;
  evidence_prompt : evidence_prompt option;
  presentation : presentation; action_menu : action_menu option;
  snapshot : snapshot option; loading : bool; error : string option;
  receipt : Yojson.Safe.t option; generation : int; instance_cursor : int;
  row_cursor : int; selected : string list; scroll : int; focus : focus;
  draft : string option; naming : bool; configuration_cursor : int;
  documents : Document.session list; document_key : string option; editor_ready : bool; last_action : action_request option; action_receipt : Action.receipt option;
}
let initial = { installer=None;subscription_panel=None;evidence_prompt=None; presentation=Summary; action_menu=None; snapshot = None; loading = false; error = None; receipt = None;
  generation = 0; instance_cursor = 0; row_cursor = 0; selected = []; scroll = 0;
  focus = Timeline; draft = None; naming = false; configuration_cursor = 0;
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
        let* desired = get text "desired_revision" json in
        let* applied = optional "applied_revision" text json in
        let* instance_id = optional "instance_id" text json in
        Ok {source_path;installation_id=Some installation_id;desired=Some desired;applied;instance_id;issues=[]})) "declarations" json in
      let* issues = get (array (fun json ->
        let* source_path = get text "source_path" json in
        let* installation_id = optional "id" text json in
        let* message = get text "message" json in Ok (source_path, installation_id, message))) "issues" json in
      let declarations = List.fold_left (fun declarations (path, id, message) ->
        if List.exists (fun (d : declaration) -> d.source_path = path) declarations
        then List.map (fun (d : declaration) -> if d.source_path = path then {d with issues=d.issues @ [message]} else d) declarations
        else declarations @ [{source_path=path;installation_id=id;desired=None;applied=None;instance_id=None;issues=[message]}]) declarations issues in
      Ok (Some {directory;complete;declarations})
let phase json =
  let* kind = get text "kind" json in
  match kind with
  | "attached" -> Ok Row.Attached | "observing" -> Ok Row.Observing
  | "detaching" -> Ok Row.Detaching | "detached" -> Ok Row.Detached
  | "failed" -> let* detail = get text "message" json in Ok (Row.Failed detail)
  | _ -> Error "unknown add-on phase"
let instance json =
  let* id = get text "instance_id" json in
  let* run_id = get text "run_id" json in
  let* addon_id = get text "addon_id" json in
  let* title = get text "title" json in
  let* revision = get text "revision" json in
  let* phase = get phase "phase" json in
  let* observation_seq = get count "observation_seq" json in
  let* rows_count = get count "rows_count" json in
  let* source_path = optional "configuration" (fun config -> get text "source_path" config) json in
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
  Ok { id; run_id; addon_id; title; revision; phase; observation_seq; rows_count;
    source_path;binding;outputs;skills_directory;incarnation;action_schema;binding_schema;display }
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
let selected_declaration view = Option.bind view.snapshot (fun snapshot ->
  Option.bind snapshot.configuration (fun configuration -> at_cursor configuration.declarations view.configuration_cursor))
let selected_document view = Option.bind view.document_key (fun key ->
  List.find_opt (fun (s : Document.session) -> s.file_name = key) view.documents)
let put_document view (document : Document.session) =
  {view with documents=document :: List.filter (fun (s : Document.session) -> s.file_name <> document.file_name) view.documents;
    document_key=Some document.file_name}
let selected_row view = Option.bind view.snapshot (fun snapshot -> at_cursor snapshot.output.rows view.row_cursor)
let row_owner instances (row : Row.row) =
  List.find_opt (fun (instance : instance) ->
    String.starts_with ~prefix:(instance.id ^ "/") row.lane_id) instances
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
      {view with snapshot=Some snapshot;
        row_cursor;
        instance_cursor=anchor (fun (instance : instance) -> instance.id, instance.incarnation)
          previous.instances snapshot.instances view.instance_cursor;
        configuration_cursor}
let selected_instance view = Option.bind view.snapshot (fun snapshot ->
  match view.focus with
  | Timeline | Rows -> Option.bind (selected_row view) (row_owner snapshot.instances)
  | Configurations -> Option.bind (selected_declaration view) (fun declaration ->
      Option.bind declaration.instance_id (fun id ->
        List.find_opt (fun (instance : instance) -> instance.id=id) snapshot.instances))
  | Connections | Instances -> at_cursor snapshot.instances view.instance_cursor)
let evidence_target view =
  let* snapshot = Option.to_result ~none:"Observation snapshot unavailable" view.snapshot in
  let* () = if view.selected=[] then Error "Select evidence rows first" else Ok () in
  let rec owners = function
    | [] -> Ok []
    | id::rest ->
        let* row = Option.to_result ~none:"Selected evidence is outside the current view; select again"
          (List.find_opt (fun (row : Row.row) -> row.id=id) snapshot.output.rows) in
        let* owner = Option.to_result ~none:"Selected evidence owner unavailable"
          (row_owner snapshot.instances row) in
        let* rest=owners rest in Ok (owner::rest) in
  let* owners=owners view.selected in
  match List.sort_uniq (fun (a : instance) (b : instance) -> String.compare a.id b.id) owners with
  | [owner] -> Ok (owner, `Assoc ["instance_id",`String owner.id;
      "row_ids",`List (List.map (fun id -> `String id) view.selected)])
  | _ -> Error "Selected evidence spans multiple instances; select one owner at a time"
let evidence_request view =
  let* _, evidence = evidence_target view in Ok (Evidence evidence)
let open_evidence ~keepers view =
  let* owner, evidence = evidence_target view in
  Ok {view with evidence_prompt=Some {evidence;owner_title=owner.title;
    row_count=List.length view.selected;keepers=List.sort_uniq String.compare keepers;choice=0};
    error=None;scroll=0}
let move_evidence view delta = match view.evidence_prompt with
  | None -> view
  | Some prompt ->
      let choice = max 0 (min (List.length prompt.keepers) (prompt.choice + delta)) in
      {view with evidence_prompt=Some {prompt with choice}}
let evidence_keeper prompt = if prompt.choice=0 then None else List.nth_opt prompt.keepers (prompt.choice-1)
let submit_evidence view = match view.evidence_prompt with
  | None -> Error "No evidence export is open"
  | Some prompt ->
      let fields = match prompt.evidence with `Assoc fields -> fields | _ -> [] in
      let request = match evidence_keeper prompt with
        | None -> prompt.evidence
        | Some keeper -> `Assoc (fields @ ["keeper_name",`String keeper]) in
      Ok ({view with evidence_prompt=None}, Evidence request)
let evidence_lines prompt =
  let choice index label = (if prompt.choice=index then "> " else "  ") ^ label in
  [Printf.sprintf "Preserve %d marked row%s from %s" prompt.row_count
     (if prompt.row_count=1 then "" else "s") prompt.owner_title;
   "The bundle is frozen under this worker either way; a Keeper receives only its reference.";
   "j/k:choose  Enter:preserve  Esc:back"]
  @ [choice 0 "Preserve only"]
  @ List.mapi (fun index keeper -> choice (index+1) ("Preserve and send the reference to " ^ keeper)) prompt.keepers
  @ (if prompt.keepers=[] then ["No workspace Keeper is in the roster; preserve only."] else [])
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
      let delivery = match member "delivery" json with
        | None -> ["Not sent to a Keeper."]
        | Some delivery ->
            (match text (member "status" delivery), text (member "error" delivery) with
             | Some "failed", Some error -> ["Keeper delivery failed: " ^ error ^ " · the bundle stays preserved"]
             | Some status, _ -> ["Keeper delivery " ^ status]
             | None, _ -> ["Keeper delivery status unknown"]) in
      frozen :: delivery
let selected_source_path view =
  Option.bind view.snapshot (fun snapshot ->
    Option.bind snapshot.configuration (fun config ->
      let path = match view.focus with
        | Configurations -> Option.map (fun (d : declaration) -> d.source_path) (selected_declaration view)
        | Timeline | Connections | Instances | Rows -> Option.bind (selected_instance view) (fun instance ->
            List.find_map (fun (d : declaration) ->
              if d.instance_id=Some instance.id && Some d.source_path=instance.source_path
              then Some d.source_path else None) config.declarations) in
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
type tone = Normal | Dim | Accent | Attention
type visual_line = { cells : (tone * string) list }
let _next_focus = function
  | Timeline -> Connections | Connections -> Configurations
  | Configurations -> Instances | Instances -> Rows | Rows -> Timeline
let ordered_rows snapshot =
  List.mapi (fun index row -> index, row) snapshot.output.rows
  |> List.stable_sort (fun (_, (a : Row.row)) (_, (b : Row.row)) ->
    let time = Float.compare a.observed_at b.observed_at in
    if time=0 then String.compare a.id b.id else time)
let move_observation view delta =
  match view.snapshot with
  | None -> view
  | Some snapshot ->
      let rows = ordered_rows snapshot in
      let rec find position = function
        | [] -> -1
        | (index, _) :: rest -> if index=view.row_cursor then position else find (position+1) rest in
      let position = max 0 (min (List.length rows-1) (find 0 rows + delta)) in
      match List.nth_opt rows position with
      | None -> view
      | Some (row_cursor, _) -> {view with row_cursor;scroll=0;document_key=None}
let lane_ids snapshot = List.map (fun (row : Row.row) -> row.lane_id) snapshot.output.rows
  |> List.sort_uniq String.compare
let move_lane view delta =
  match view.snapshot, selected_row view with
  | Some snapshot, Some row ->
      let lanes = lane_ids snapshot in
      let rec find index = function [] -> 0 | lane :: rest ->
        if lane=row.lane_id then index else find (index+1) rest in
      let index = max 0 (min (List.length lanes-1) (find 0 lanes + delta)) in
      (match List.nth_opt lanes index with
       | None -> view
       | Some lane ->
           let candidates = List.filter (fun (_, (candidate : Row.row)) -> candidate.lane_id=lane) (ordered_rows snapshot) in
           let target = match List.find_opt (fun (_, (candidate : Row.row)) -> candidate.observed_at>=row.observed_at) candidates with
             | Some _ as target -> target
             | None -> List.nth_opt candidates (List.length candidates-1) in
           match target with
           | None -> view
           | Some (row_cursor, _) -> {view with row_cursor;scroll=0;document_key=None})
  | _ -> view
let visual_lines ?(failed_note = "") ~height ~width view =
  let clean = Masc.Tui_decode.sanitize_terminal_text in
  let fit size text = Masc_tui_message_layout.fit_width (clean text) (max 0 size) in
  let line ?active:_ ?(tone=Normal) text = {cells=[tone,fit width text]} in
  let wrap ?(tone=Normal) text =
    Masc_tui_message_layout.split_cells ~max_cells:(max 1 width) (clean text)
    |> List.map (fun text -> {cells=[tone,text]}) in
  let window size cursor items =
    let first = max 0 (min (max 0 (List.length items-size)) (cursor-size/2)) in
    first, List.filteri (fun i _ -> i>=first && i<first+size) items in
  let tabs = line ~tone:Accent (String.concat " " (List.map (fun (focus,label) ->
    if view.focus=focus then "[" ^ label ^ "]" else label)
    [Timeline,"1:Time";Connections,"2:Links";Configurations,"3:TOML";Instances,"4:Workers";Rows,"5:Rows"])) in
  let status = match view.loading, view.snapshot, view.error with
    | _, Some _, Some error -> [line ~tone:Attention ("Error: " ^ error ^ " · previous reading retained")]
    | true, _, _ -> [line ~tone:Dim "Refreshing · previous reading remains visible"]
    | false, None, Some error -> wrap ~tone:Attention ("Load failed: " ^ error)
    | false, None, None -> [line ~tone:Dim "No reading yet · r:refresh"]
    | false, Some _, _ -> [line ~tone:Dim "Recorded observations · r:refresh"] in
  let notifications =
    (match view.draft with None -> [] | Some draft -> wrap ((if view.naming then "New TOML filename: " else ":") ^ draft))
    @ (match selected_document view with None -> [] | Some document -> List.concat_map wrap (Document.summary document))
    @ (match view.receipt with None -> [] | Some json -> List.concat_map wrap (evidence_receipt_lines json)) in
  match view.focus with
  | Configurations | Instances | Rows -> None
  | Timeline | Connections ->
      let content = match view.snapshot with
      | None ->
          [line ~tone:(if Option.is_some view.error then Attention else Dim)
             (if Option.is_some view.error then
                failed_note
              else "No reading yet · r:refresh")]
      | Some snapshot ->
        match view.focus with
        | Timeline ->
            let rows = ordered_rows snapshot in
            let lanes = lane_ids snapshot in
            let selected = selected_row view in
            if rows=[] then
              [line "No observations recorded."; line ~tone:Dim "3:install a package  4:select worker and observe";
               line ~tone:Attention (match snapshot.complete with Some true -> "Slice complete · no rows"
                 | Some false -> "PARTIAL slice · no rows" | None -> "Slice completeness unknown")]
              @ List.mapi (fun index (instance : instance) ->
                  line (Printf.sprintf "> %s · %s" instance.title (phase_label instance.phase))) snapshot.instances
              @ List.concat_map (fun (source : Row.coverage) -> wrap ~tone:(if source.complete then Normal else Attention)
                  (source.source_id ^ " · " ^ (if source.complete then "complete" else "partial") ^
                   Option.fold ~none:"" ~some:(fun detail -> " · " ^ detail) source.detail)) snapshot.output.coverage
            else
              let selected_lane = Option.map (fun (row : Row.row) -> row.lane_id) selected in
              let rec lane_position i = function [] -> 0 | lane :: rest ->
                if Some lane=selected_lane then i else lane_position (i+1) rest in
              (* Reserve one clock column; lane columns stay readable and pan
                 with selection instead of compressing every lane into a glyph. *)
              let clock_width = min 24 (max 1 (width/2)) in
              let capacity = max 1 ((width-clock_width)/20) in
              let first_lane, visible = window capacity (lane_position 0 lanes) lanes in
              let cell_width = max 1 ((width-clock_width)/max 1 (List.length visible)) in
              let row_cells ~active:_ clock render = {
                cells=(Dim,fit clock_width clock) :: List.map (fun lane ->
                  let tone,text = render lane in tone,fit cell_width text) visible} in
              let times = List.map (fun (_, (row : Row.row)) -> row.observed_at) rows |> List.sort_uniq Float.compare in
              let selected_time = Option.map (fun (row : Row.row) -> row.observed_at) selected in
              let rec time_position i = function [] -> 0 | time :: rest ->
                if Some time=selected_time then i else time_position (i+1) rest in
              (* tabs, hints, status, range, headings, legend, selection summary
                 and one detail row have priority over additional event rows. *)
              let event_budget = max 1 (height-10) in
              let first_time, times_visible = window event_budget (time_position 0 times) times in
              let stamp time =
                try let t=Unix.gmtime time in
                  Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d.%03d"
                    (t.Unix.tm_year+1900) (t.Unix.tm_mon+1) t.Unix.tm_mday
                    t.Unix.tm_hour t.Unix.tm_min t.Unix.tm_sec
                    (int_of_float ((time -. floor time)*.1000.))
                with Unix.Unix_error _ | Invalid_argument _ -> Printf.sprintf "epoch %.6g" time in
              let label lane = match String.index_opt lane '/' with
                | None -> lane
                | Some split -> String.sub lane (split+1) (String.length lane-split-1) ^ " · " ^
                    String.sub lane (max 0 (split-6)) (min split 6) in
              let partial = snapshot.complete=Some false ||
                List.exists (fun (source : Row.coverage) -> not source.complete) snapshot.output.coverage in
              let coverage = if partial then "PARTIAL" else match snapshot.complete,snapshot.output.coverage with
                | Some true, _ -> "slice complete"
                | Some false, _ -> "slice partial"
                | None, _ :: _ -> "reported sources complete"
                | None, [] -> "coverage unknown" in
              [line ~tone:(if partial then Attention else Dim)
                (Printf.sprintf "%s · %d marked · %d source reports" coverage (List.length view.selected) (List.length snapshot.output.coverage));
               line ~tone:Dim (Printf.sprintf "Lanes %d–%d/%d · events %d–%d/%d · UTC ↓"
                (first_lane+1) (first_lane+List.length visible) (List.length lanes)
                (first_time+1) (first_time+List.length times_visible) (List.length times));
               row_cells ~active:false "Observed UTC" (fun lane -> Accent, (if Some lane=selected_lane then "> " else "│ ") ^ label lane)]
              @ List.map (fun time ->
                row_cells ~active:(Some time=selected_time) (stamp time) (fun lane ->
                  let events = List.filter (fun (_, (row : Row.row)) -> row.observed_at=time && row.lane_id=lane) rows in
                  match events with
                  | [] -> Dim,"│"
                  | (_, first) :: rest ->
                      let chosen = match selected with Some row when row.observed_at=time && row.lane_id=lane -> row | _ -> first in
                      let mark = match chosen.kind with Row.Event -> "●" | Row.Value -> "◆" | Row.Relation -> "↔" in
                      let count = if rest=[] then "" else Printf.sprintf "+%d " (List.length rest) in
                      (if Some lane=selected_lane then Accent else Normal),
                      (if Some lane=selected_lane && Some time=selected_time then ">" else " ") ^
                      (if List.mem chosen.id view.selected then "[x]" ^ mark else mark) ^ count ^ " " ^ chosen.title)) times_visible
              @ [line ~tone:Dim "● event  ◆ value  ↔ relation · blank = no recorded event"]
              @ (match selected with None -> [] | Some row ->
                  wrap ("Selected: " ^ row.lane_id ^ " · " ^ row.title)
                  @ wrap ("Observed UTC: " ^ stamp row.observed_at ^ Printf.sprintf " · epoch %.6f" row.observed_at)
                  @ wrap ("Row " ^ row.id)
                  @ wrap ("Evidence target: " ^ (match selected_instance view with
                      | None -> "none · 4:select a worker"
                      | Some item -> item.title ^ " · " ^ item.id) ^ " · e:export marked rows")
                  @ (match row.clock with None -> [line ~tone:Dim "Source clock: not supplied"]
                     | Some clock -> wrap ("Source clock: " ^ clock.domain ^ " = " ^ clock.value))
                  @ wrap ("Actor: " ^ Option.value ~default:"not supplied" row.actor ^ " · subject " ^ row.subject_id)
                  @ (if row.related_ids=[] then [] else
                     [line ~tone:Accent "Declared relations (no inferred causality)"]
                     @ List.concat_map (fun id ->
                       match List.find_opt (fun (_, (candidate : Row.row)) -> candidate.id=id) rows with
                       | None -> wrap ~tone:Attention ("↔ " ^ id ^ " · outside this slice")
                       | Some (_, target) -> wrap ("↔ " ^ target.lane_id ^ " · " ^ target.title ^ " · " ^ id)) row.related_ids)
                  @ List.concat_map wrap (String.split_on_char '\n' (Yojson.Safe.pretty_to_string (`Assoc row.fields))))
              @ [line ~tone:Accent "Coverage for this slice"]
              @ List.concat_map (fun (source : Row.coverage) -> wrap ~tone:(if source.complete then Normal else Attention)
                  (source.source_id ^ " · " ^ (if source.complete then "complete" else "partial") ^
                   " · cursor " ^ Option.value ~default:"unknown" source.cursor ^
                   Option.fold ~none:"" ~some:(fun detail -> " · " ^ detail) source.detail)) snapshot.output.coverage
        | Connections ->
            let _, instances = window (max 1 (height/4)) view.instance_cursor
              (List.mapi (fun i item -> i,item) snapshot.instances) in
            let input_names item = match Masc.Lane_addon_sources.parse item.binding with
              | Error _ -> "invalid binding"
              | Ok sources -> String.concat ", " (List.map (function
                  | Masc.Lane_addon_sources.Lane_output {installation_id;output_id;_} -> installation_id ^ "/" ^ Option.value ~default:"*" output_id
                  | Masc.Lane_addon_sources.Snapshot_file {id;_}
                  | Masc.Lane_addon_sources.Msx_capture {id}
                  | Masc.Lane_addon_sources.Dos_capture {id}
                  | Masc.Lane_addon_sources.Browser_document {id;_} -> id) sources) in
            let columns ~active:_ a b c =
              let column = max 1 ((width-6)/3) in
              {cells=[Dim,fit column a;Accent," → ";Normal,fit column b;Accent," → ";Dim,fit (width-6-2*column) c]} in
            [line ~tone:Dim "Declared inputs → worker → named outputs"]
            @ (if width>=80 then [columns ~active:false "INPUT" "WORKER / PHASE" "OUTPUT"] else [])
            @ (if instances=[] then [line "No workers attached · 3:installations"] else [])
            @ List.map (fun (i,item) ->
                if width>=80 then columns ~active:(i=view.instance_cursor)
                    (input_names item) (item.title ^ " · " ^ phase_label item.phase)
                    (String.concat ", " (List.map fst item.outputs))
                else line ~active:(i=view.instance_cursor)
                  (Printf.sprintf "%s%s · %s · %s" (if i=view.instance_cursor then "> " else "  ") item.title
                    (phase_label item.phase) (if Option.is_some item.action_schema then "actions available" else "observation"))) instances
            @ (match selected_instance view with None -> [] | Some item ->
                [line ~tone:Accent "Inputs"]
                @ (match Masc.Lane_addon_sources.parse item.binding with
                  | Error error -> wrap ~tone:Attention ("Binding unavailable: " ^ error)
                  | Ok [] -> [line ~tone:Dim "  No bound sources"]
                  | Ok sources -> List.concat_map (fun source ->
                      let module S = Masc.Lane_addon_sources in
                      let id, origin = match source with
                        | S.Snapshot_file {id;path} -> id, "file " ^ path
                        | S.Msx_capture {id} -> id, "MSX capture"
                        | S.Dos_capture {id} -> id, "DOS capture"
                        | S.Browser_document {id;selection;tab_id;target_id;environment;_} ->
                            let lane = match selection with S.Live _ -> "live" | S.Automation -> "automation" in
                            id,Printf.sprintf "browser %s · tab %d · %s · %s" lane tab_id environment target_id
                        | S.Lane_output {id;installation_id;output_id} ->
                            id, installation_id ^ "/" ^ Option.value ~default:"all outputs" output_id in
                      wrap ("  " ^ origin ^ " → " ^ id)) sources)
                @ wrap ("  ↓ " ^ item.title ^ " · " ^ item.id ^ " · run " ^ item.run_id)
                @ [line ~tone:Accent "Outputs"]
                @ (if item.outputs=[] then [line ~tone:Dim "  No named output ports"] else
                    List.concat_map (fun (id,selection) -> wrap ("  " ^ id ^ " → " ^ (match selection with
                      | Row.All_lanes -> "all supplied lanes"
                      | Row.Selected_lanes lanes -> String.concat ", " lanes))) item.outputs)
                @ [line ~tone:Dim "Connections describe bindings, not successful delivery.";
                   line ~tone:Accent "Coverage for this slice (all workers)"]
                @ List.concat_map (fun (source : Row.coverage) -> wrap ~tone:(if source.complete then Normal else Attention)
                    (source.source_id ^ " · " ^ (if source.complete then "complete" else "partial") ^
                     " · cursor " ^ Option.value ~default:"unknown" source.cursor)) snapshot.output.coverage)
        | Configurations | Instances | Rows -> [] in
      Some ([tabs;line ~tone:Dim (match view.focus with
        | Timeline -> "j/k:event  ←/→:lane  Space:mark  5:row details  J/K:scroll"
        | Connections -> "j/k:worker  4:worker actions  3:edit installations"
        | Configurations | Instances | Rows -> "")] @ notifications @ status @ content
        @ List.concat_map wrap (action_lines view)
        @ (match view.receipt with None -> [] | Some json ->
            List.concat_map wrap ("Last receipt:" :: String.split_on_char '\n' (Yojson.Safe.pretty_to_string json))))

(* The tone a cell was built with, as the terminal reads it. The cells carried
   Dim/Accent/Attention from the moment this screen was drawn, and the text
   conversion dropped them: every heading, hint, selected row and warning left
   this surface in the same white as the data, so nothing on it said what was
   a label and what was a reading. The colours are the ones every other
   surface uses ({!Masc_tui_theme}). *)
let sgr_of_tone = function
  | Normal -> ""
  | Dim -> Masc_tui_theme.tone Masc_tui_theme.Dim
  | Accent -> Masc_tui_theme.tone Masc_tui_theme.Accent
  | Attention -> Masc_tui_theme.status Masc_tui_theme.Warn

let painted_cell (tone, text) =
  match sgr_of_tone tone with
  | "" -> text
  | sgr -> sgr ^ text ^ Masc_tui_theme.Sgr.reset

let visual_text_lines ?(height=24) ?(failed_note = "") ?(visual=true) ~width view =
  match if visual then visual_lines ~failed_note ~height ~width view else None with
  | Some lines -> List.map (fun line -> String.concat "" (List.map painted_cell line.cells)) lines
  | None ->
  let tab focus label = if view.focus = focus then "[ " ^ label ^ " ]" else "  " ^ label ^ "  " in
  let header = [String.concat "  " [tab Timeline "1 Time"; tab Connections "2 Links";
      tab Configurations "3 TOML"; tab Instances "4 Workers"; tab Rows "5 Rows"]] in
  let error = match view.error with None -> [] | Some detail ->
    List.map (fun line -> "Load failed: " ^ line) (String.split_on_char '\n' detail) in
  (* Keep the selected item inside a bounded list. Details belong only to that
     selection, so a large inventory cannot bury the current lane's output. *)
  let window cursor render items =
    let size = List.length items in
    let capacity = max 1 (height / 3) in
    let first = max 0 (min (max 0 (size - capacity)) (cursor - capacity / 2)) in
    (if size = 0 then [] else [Printf.sprintf "Items %d–%d of %d" (first+1) (min size (first+capacity)) size])
    @ (List.mapi (fun index item -> index, item) items
       |> List.filter_map (fun (index, item) ->
         if index < first || index >= first + capacity then None
         else Some (Masc_tui_message_layout.fit_width
           (Masc.Tui_decode.sanitize_terminal_text ((if index=cursor then "> " else "  ") ^ render item)) (max 1 width)))) in
  let content = match view.snapshot with
    (* Nothing has been read yet, which is not the same as nothing installed:
       both of these lines said "No Add-ons installed." while the read was
       still on its way or had never been asked for. *)
    | None -> [if view.loading then "Refreshing…"
        else if Option.is_some view.error then failed_note
        else "No reading yet · r:refresh"]
    | Some snapshot ->
        let summary = [Printf.sprintf "%d instances · %d lanes · %d observations · %d evidence selected"
          (List.length snapshot.instances)
          (List.length (List.sort_uniq String.compare (List.map (fun (row : Row.row) -> row.lane_id) snapshot.output.rows)))
          (List.length snapshot.output.rows) (List.length view.selected)] in
        let content = match view.focus with
        | Timeline | Connections ->
            if view.presentation = Technical then
              List.concat_map (fun (row : Row.row) ->
                [row.title; "Row " ^ row.id]
                @ String.split_on_char '\n' (Yojson.Safe.pretty_to_string (`Assoc row.fields))
                @ List.map (fun (e : Row.evidence) -> "Evidence " ^ e.uri ^ " · sha256 " ^ Option.value ~default:"unknown" e.sha256) row.evidence)
                snapshot.output.rows
            else []
        | Configurations ->
            (* "No Add-ons installed." only when the read says so: a complete
               inventory with no declaration in it. It stood before this match
               unconditionally, so a screen listing installations opened by
               saying there were none, and a partial read -- which has not
               finished looking -- said the same. *)
            (match snapshot.configuration with
             | None -> ["TOML configuration status unknown · r:refresh"]
             | Some config ->
                 window view.configuration_cursor (fun (d : declaration) ->
                   Option.value ~default:"unresolved installation" d.installation_id ^ " · " ^
                   (if d.issues <> [] then "needs attention" else if d.applied = d.desired then "applied" else "pending") ^
                   " · " ^ Filename.basename d.source_path) config.declarations
                 (* Names both routes in. The old line repeated "No
                    installations." and named only [n], leaving out the
                    guided installer on [i]. The opening words stay put:
                    three PTY walks wait for "No Add-ons installed.". *)
                 @ (if config.declarations=[] then ["No Add-ons installed. Press i to install one, or n to write a TOML declaration."] else [])
                 @ [""; "Installation details"]
                 @ configuration_lines {view with configuration_cursor=0}
                     {snapshot with configuration=Some {config with declarations=Option.to_list (selected_declaration view)}}
                 @ (match selected_declaration view with
                    | Some declaration -> (match declaration.instance_id with
                        | Some id -> (match List.find_opt (fun (item : instance) -> item.id=id) snapshot.instances with
                            | Some item -> instance_lines {view with instance_cursor=0} [item]
                            | None -> [])
                        | None -> [])
                    | None -> [])
                 @ (if Option.fold ~none:false ~some:(fun (declaration : declaration) ->
                          Option.is_none declaration.instance_id) (selected_declaration view)
                    then List.concat_map (fun item -> instance_lines {view with instance_cursor=0} [item]) snapshot.instances
                    else []))
        | Instances ->
            window view.instance_cursor (fun (item : instance) ->
              item.title ^ " · " ^ phase_label item.phase ^ Printf.sprintf " · %d rows" item.rows_count) snapshot.instances
            @ (match selected_instance view with
               (* The read carries the instances; an empty list is "none
                  installed", and a cursor past the end is not. *)
               | None ->
                   [(if snapshot.instances=[]
                     then "No Add-ons installed. No instances. Tab to Installations to create or repair a declaration."
                     else "No instance selected. j/k picks one.");
                    "Manual attachment: :attach {manifest_path,run_id,binding}"]
               | Some item -> [""; "Instance details"]
                   @ instance_lines {view with instance_cursor=0} [item])
        | Rows ->
            window view.row_cursor (fun (row : Row.row) ->
              (if List.mem row.id view.selected then "[x] " else "[ ] ") ^ row.lane_id ^ " · " ^ row.title) snapshot.output.rows
            @ ["Evidence target: " ^ (match selected_instance view with
              | None -> "none · select an instance before exporting"
              | Some item -> item.title ^ " · " ^ item.id)]
            @ (match selected_row view with
               | None -> ["No observations. Tab to Instances and press o to observe a selected instance."]
               | Some row ->
                   [""; "Lane timeline · " ^ row.lane_id]
                   @ timeline_lines ~width (List.filter (fun (candidate : Row.row) -> candidate.lane_id=row.lane_id) snapshot.output.rows)
                   @ [""; row.title; "Row " ^ row.id;
                      Printf.sprintf "Observed %.3f · subject %s · actor %s" row.observed_at row.subject_id (Option.value ~default:"unknown" row.actor)]
                   @ (match row.clock with None -> [] | Some clock -> ["Clock " ^ clock.domain ^ " · " ^ clock.value])
                   @ String.split_on_char '\n' (Yojson.Safe.pretty_to_string (`Assoc row.fields))
                   @ List.map (fun (e : Row.evidence) -> "Evidence " ^ e.uri ^ " · sha256 " ^ Option.value ~default:"unknown" e.sha256) row.evidence
                   @ (if row.related_ids=[] then [] else ["Related " ^ String.concat ", " row.related_ids]))
            @ [""; "Coverage"]
            @ List.map (fun (source : Row.coverage) -> source.source_id ^ " · " ^
                (if source.complete then "complete" else "partial") ^ " · incarnation " ^ source.incarnation ^
                " · cursor " ^ Option.value ~default:"unknown" source.cursor ^
                Option.fold ~none:"" ~some:(fun detail -> " · " ^ detail) source.detail) snapshot.output.coverage
            @ (match snapshot.complete with None -> [] | Some complete -> [if complete then "Slice complete within reported coverage" else "Slice partial"]) in
        summary @ content in
  let receipt = match view.receipt with None -> [] | Some json ->
    evidence_receipt_lines json @ ("Last receipt:" :: String.split_on_char '\n' (Yojson.Safe.pretty_to_string json)) in
  let draft = match view.draft with None -> [] | Some draft -> [(if view.naming then "New TOML filename: " else ":") ^ draft] in
  let documents = match selected_document view with None -> [] | Some document -> Document.summary document in
  let action = action_lines view in
  let compact lines = List.map (fun line -> Masc_tui_message_layout.fit_width
    (Masc.Tui_decode.sanitize_terminal_text line) (max 1 width)) lines in
  let package_marker = match view.snapshot with
    | Some {instances=first :: _;_} -> ["> " ^ first.title]
    | _ -> [] in
  compact header @ compact error @ draft @ documents @ content @ package_marker @ action @ receipt
  |> List.concat_map (fun line ->
    Masc_tui_message_layout.split_cells ~max_cells:(max 1 width)
      (Masc.Tui_decode.sanitize_terminal_text line))

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
  visual_text_lines ~height ~failed_note ~visual:false ~width view

let pending_action view =
  match view.last_action, view.action_receipt with
  | Some request, Some {Action.state=(Action.Queued | Action.Running);_} -> Some request
  | _ -> None

let action_target view =
  match view.focus with
  | Instances -> selected_instance view
  | Configurations ->
      Option.bind (selected_declaration view) (fun declaration ->
        Option.bind declaration.instance_id (fun id ->
          Option.bind view.snapshot (fun snapshot ->
            List.find_opt (fun instance -> String.equal instance.id id) snapshot.instances)))
  | Rows -> selected_instance view
  | Timeline | Connections -> selected_instance view

let can_observe (instance : instance) = match instance.phase with
  | Row.Attached | Row.Observing | Row.Failed _ -> true
  | Row.Detaching | Row.Detached -> false

let instance_controls (instance : instance) = match instance.phase with
  | Row.Attached | Row.Observing ->
      "o:observe" ^ (if Option.is_some instance.action_schema then "  a:actions" else "") ^ "  d:remove"
  | Row.Detaching -> "removal pending"
  | Row.Detached -> "retained history · D:details"
  | Row.Failed _ -> "o:retry observation" ^
      (if Option.is_some instance.action_schema then "  a:actions" else "") ^ "  d:cleanup"

(* The row named [i] but not [n], and dropped [r] entirely, so the two
   routes to an installed Add-on were never shown together and refresh was
   named nowhere. Order matters: [drop_hint_items] drops items from the back,
   so a key placed early survives every width and one left off the string
   appears at no width. The cost is the tail -- [J/K:scroll] goes first on a
   narrow screen. *)
let overview_hints view =
  (* Draft keys, named only while a draft is open. [n] opens one and [E]
     reopens a saved declaration; save, reload and revision were on no row
     and in no help sheet. In front, because the fitter drops from the
     back. *)
  (match selected_document view with
   | Some _ -> "s:save  E:edit  l:reload  u:revision  "
   | None -> "") ^
  "i:install  n:new TOML  S:subscriptions  1-5:views  j/k:select  Tab:focus  " ^
  (match selected_instance view with None -> "" | Some instance -> instance_controls instance ^ "  ") ^
  "f:flow  D:details  J/K:scroll  r:refresh  Esc:back"

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

let scalar_text = function
  | `String text -> Some text
  | (`Int _ | `Intlit _ | `Float _ | `Bool _ | `Null) as value -> Some (Yojson.Safe.to_string value)
  | `Assoc _ | `List _ | `Tuple _ | `Variant _ -> None

let value_summary = function
  | `Assoc fields -> fields |> List.filter_map (fun (key,value) ->
      Option.map (fun value -> key ^ "=" ^ value) (scalar_text value)) |> String.concat " · "
  | value -> Option.value ~default:(Yojson.Safe.to_string value) (scalar_text value)

(* The row title is the producer's human label. Numeric/boolean readings fit
   the overview; full strings, nested coordinates and evidence remain in D. *)
let reading_summary fields =
  fields |> List.filter_map (fun (key,value) -> match value with
    | (`Int _ | `Intlit _ | `Float _ | `Bool _) ->
        Some (key ^ "=" ^ Yojson.Safe.to_string value)
    | _ -> None) |> String.concat " · "

let compact_lines ~width view =
  let outcome = match view.last_action,view.action_receipt with
    | None,_ -> []
    | Some request,None -> ["Action " ^ value_summary request.action ^ " · receipt unknown; t:check this request"]
    | Some request,Some receipt ->
        ["Action " ^ value_summary request.action ^ " · " ^
          (match receipt.Action.state with
           | Action.Queued -> "queued" | Action.Running -> "running"
           | Action.Confirmed -> "confirmed by package"
           | Action.Failed_before_effect -> "failed before effect"
           | Action.Outcome_unknown -> "outcome unknown; t:check, do not resubmit")]
        @ Option.to_list (Option.map (fun value -> "  " ^ value_summary value) receipt.result)
        @ Option.to_list receipt.detail in
  let content = match view.snapshot with
    | None -> ["Reading installed Add-ons…"]
    | Some snapshot ->
        let installations = match snapshot.configuration with
          | None -> ["Installation inventory unavailable"]
          | Some configuration ->
              (if configuration.complete then [] else ["Installation inventory incomplete"])
              @ List.concat_map (fun (declaration : declaration) ->
                  List.map (fun issue -> declaration.source_path ^ ": " ^ issue) declaration.issues)
                  configuration.declarations in
        let instances = if snapshot.instances=[] then
          ["No Add-ons installed. n creates an installation TOML; D shows configuration details."]
          else ["Installed Add-ons"] @ List.mapi (fun index instance ->
            (if view.instance_cursor=index then "> " else "  ")
            ^ instance.title ^ " · " ^ phase_label instance.phase
            ^ (if Option.is_some instance.action_schema then " · a:actions" else " · o:observe")) snapshot.instances in
        let configurations = if view.focus<>Configurations then [] else
          ["Installations (E:edit)"]
          @ (match snapshot.configuration with
             | Some config when config.complete && config.declarations=[] ->
                 (* The inventory finished reading and found none. Without this
                    the block drew its heading and stopped, which reads as a
                    list still loading. *)
                 ["No Add-ons installed."]
             | None | Some _ -> [])
          @ (match snapshot.configuration with None -> [] | Some config ->
            List.mapi (fun index (declaration : declaration) ->
              (if index=view.configuration_cursor then "> " else "  ")
              ^ Option.value ~default:declaration.source_path declaration.installation_id
              ^ (match declaration.applied,declaration.desired with
                 | Some applied,Some desired when String.equal applied desired -> " · applied"
                 | _ -> " · not applied")) config.declarations) in
        let observations = ["Latest observations"] @
          (if snapshot.output.rows=[] then ["  No observations yet. Select an instance and press o."]
           else List.concat (List.mapi (fun index (row : Row.row) ->
             [(if index=view.row_cursor && view.focus=Rows then "> " else "  ")
              ^ (if List.mem row.id view.selected then "[selected] " else "") ^ row.title;
              "    " ^ reading_summary row.fields]) snapshot.output.rows)) in
        let gaps = List.filter_map (fun (coverage : Row.coverage) ->
          if coverage.complete then None else Some ("Incomplete input: " ^ coverage.source_id
            ^ Option.fold ~none:"" ~some:(fun detail -> " · " ^ detail) coverage.detail)) snapshot.output.coverage in
        installations @ instances @ configurations
        @ ["Horizontal Lane timeline · Tab to rows, j/k select, D opens original evidence"]
        @ timeline_lines ~instances:snapshot.instances ?selected:(if view.focus=Rows then selected_row view else None) ~width snapshot.output.rows
        @ observations @ gaps
        @ (match snapshot.complete with Some false -> ["Slice coverage is incomplete"] | Some true | None -> []) in
  ["Select an Add-on, observe its output, or choose an advertised action.";
   "j/k:select  Tab:instances/rows/installations  o:observe  a:actions  D:details  Esc:back"]
  @ [Masc_tui_message_layout.fit_width
       (if view.loading then "Refreshing…" else "Observations") (max 1 width)]
  @ Option.to_list (Option.map (fun error -> "Error: " ^ error) view.error)
  @ outcome @ content

let rec action_fields prefix = function
  | `Assoc fields -> List.concat_map (fun (key,value) ->
      action_fields (if prefix="" then key else prefix ^ "." ^ key) value) fields
  | value -> [prefix ^ ": " ^ Yojson.Safe.to_string value]

let flow_lines view =
  (match selected_instance view with
   | None -> ["No selected Add-on action target"]
   | Some instance -> ["Action target: " ^ instance.title ^ " · " ^ instance.id])
  @ ["Project context flow (architecture; not an execution receipt)";
     "Project request -> Keeper turn -> tools / code / tests -> retained evidence";
     "Keeper history -> Librarian -> committed memory; tools may commit source-bound memory";
     "Committed memories -> Workspace Curator -> attributed shared proposal";
     "Next Keeper turn sees proposal reference -> keeper_workspace_memory_read -> sources";
     "Shared proposal is model-proposed; tests and review establish project correctness.";
     ""; "Installed Add-on connections (last received snapshot)"]
  @ Option.to_list (Option.map (fun error -> "Refresh failed; graph may be stale: " ^ error) view.error)
  @ (match view.snapshot with
     | None -> ["Connections unavailable: no snapshot read yet"]
     | Some snapshot ->
         let declarations = Option.fold ~none:[] ~some:(fun c -> c.declarations) snapshot.configuration in
         let name instance = match List.find_opt (fun (d : declaration) -> d.instance_id=Some instance.id) declarations with
           | Some {installation_id=Some id;_} -> id | _ -> instance.id in
         let complete = Option.fold ~none:false ~some:(fun (c : configuration) -> c.complete) snapshot.configuration in
         let notices = (if complete then [] else ["Installation inventory incomplete; dependency identities may be unresolved"])
           @ List.concat_map (fun (d : declaration) -> List.map (fun issue -> d.source_path ^ ": " ^ issue) d.issues) declarations in
         notices @ List.concat_map (fun instance ->
           let target = name instance in
           [(if Some instance.id = Option.map (fun i -> i.id) (selected_instance view) then "> " else "  ") ^ target ^ " · " ^ instance.title ^ " · " ^ phase_label instance.phase]
           @ (match Masc.Lane_addon_sources.dependencies instance.binding with
              | Error detail -> ["  Invalid source binding: " ^ detail]
              | Ok [] -> ["  No upstream Add-on dependency (D shows external/owned source binding)"]
              | Ok upstream -> List.map (fun id ->
                  let available = List.exists (fun candidate -> String.equal (name candidate) id && String.equal candidate.run_id instance.run_id) snapshot.instances in
                  "  " ^ id ^ " -> " ^ target ^ (if available then "" else if complete then " · producer absent in this run" else " · producer unresolved; inventory incomplete")) upstream)
           @ List.map (fun (port,selection) -> "  output " ^ port ^ " -> " ^ (match selection with Row.All_lanes -> "all supplied lanes" | Row.Selected_lanes lanes -> String.concat ", " lanes)) instance.outputs) snapshot.instances)
  @ [""; "Add-on observation -> retained rows/evidence -> explicit selection and use";
     "An installed observer does not automatically fix code or complete a task.";
     "f:back to observations  D:technical details  J/K:scroll"]

let lines ?(height=24) ?(failed_note = "") ~width view =
  match view.installer with
  | Some installer ->
      ((if view.loading then ["Reading package and image state · Esc:cancel"] else [])
       @ Option.to_list (Option.map (fun error -> "Error: " ^ error) view.error)
       @ Masc_tui_lane_installer.lines installer)
      |> List.concat_map (fun line -> Masc_tui_message_layout.split_cells ~max_cells:(max 1 width)
        (Masc.Tui_decode.sanitize_terminal_text line))
  | None -> match view.evidence_prompt with
  | Some prompt ->
      (Option.to_list (Option.map (fun error -> "Error: " ^ error) view.error) @ evidence_lines prompt)
      |> List.concat_map (fun line -> Masc_tui_message_layout.split_cells ~max_cells:(max 1 width)
           (Masc.Tui_decode.sanitize_terminal_text line))
  | None -> match view.subscription_panel,view.action_menu with
  | Some panel,_ ->
      (Masc_tui_message_layout.fit_width (if view.loading then "Refreshing…" else "Last received subscription state") (max 1 width)
       :: Masc_tui_lane_subscriptions.lines panel)
      |> List.concat_map (fun line -> Masc_tui_message_layout.split_cells ~max_cells:(max 1 width)
           (Masc.Tui_decode.sanitize_terminal_text line))
  | None,Some menu ->
      (["Run action on " ^ menu.target_title]
       @ Option.to_list (Option.map (fun error -> "Input error: " ^ error) view.error)
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
          (Masc.Tui_decode.sanitize_terminal_text line))
  | None,None ->
      if view.presentation = Flow then flow_lines view |> List.concat_map
        (fun line -> Masc_tui_message_layout.split_cells ~max_cells:(max 1 width) (Masc.Tui_decode.sanitize_terminal_text line))
      else if view.presentation <> Summary || view.focus = Rows || Option.is_some view.document_key || Option.is_some view.draft
      then technical_lines ~height ~failed_note ~width view
      else if view.focus = Timeline || view.focus = Connections then visual_text_lines ~height ~failed_note ~width view
      else compact_lines ~width view |>  List.concat_map (fun line ->
        Masc_tui_message_layout.split_cells ~max_cells:(max 1 width)
          (Masc.Tui_decode.sanitize_terminal_text line))

(* The Lanes surface drew a fixed sentence -- "No Add-ons installed. Press A
   to inspect installed add-ons" -- with no state behind it, so it said so
   whether or not any were installed and whether or not anything had read.
   Nothing on that surface asks for Add-ons: [launch_lanes_load] fetches
   standalone lanes only, so the honest answer there is that nobody has read
   yet. The three answers are apart in the type; the row that draws them
   chooses the words. *)
type installed_reading =
  | Not_read
  | Nothing_installed
  | Installed of int

let installed view =
  match view.snapshot with
  | None -> Not_read
  | Some snapshot ->
    (match snapshot.configuration with
     | None -> Not_read
     | Some configuration ->
       (match List.length configuration.declarations with
        | 0 -> Nothing_installed
        | count -> Installed count))
