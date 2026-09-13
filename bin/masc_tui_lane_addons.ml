module Row = Masc.Lane_addon_types
module Document = Masc_tui_lane_declaration
module Action = Masc.Lane_addon_action
type instance = {
  id : string; run_id : string; addon_id : string; title : string;
  revision : string; phase : Row.phase; observation_seq : int; rows_count : int;
  source_path : string option; binding : Yojson.Safe.t; outputs : Row.output_ports;
  skills_directory : string option; incarnation : string; action_schema : Yojson.Safe.t option;
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
}
type focus = Configurations | Instances | Rows
type presentation = Summary | Technical | Flow
type t = {
  subscription_panel : Masc_tui_lane_subscriptions.t option;
  presentation : presentation; action_menu : action_menu option;
  snapshot : snapshot option; loading : bool; error : string option;
  receipt : Yojson.Safe.t option; generation : int; instance_cursor : int;
  row_cursor : int; selected : string list; scroll : int; focus : focus;
  draft : string option; naming : bool; configuration_cursor : int;
  documents : Document.session list; document_key : string option; editor_ready : bool; last_action : action_request option; action_receipt : Action.receipt option;
}
let initial = { subscription_panel=None; presentation=Summary; action_menu=None; snapshot = None; loading = false; error = None; receipt = None;
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
  Ok { id; run_id; addon_id; title; revision; phase; observation_seq; rows_count;
    source_path;binding;outputs;skills_directory;incarnation;action_schema }
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
let selected_declaration view = Option.bind view.snapshot (fun snapshot ->
  Option.bind snapshot.configuration (fun configuration -> List.nth_opt configuration.declarations view.configuration_cursor))
let selected_document view = Option.bind view.document_key (fun key ->
  List.find_opt (fun (s : Document.session) -> s.file_name = key) view.documents)
let put_document view (document : Document.session) =
  {view with documents=document :: List.filter (fun (s : Document.session) -> s.file_name <> document.file_name) view.documents;
    document_key=Some document.file_name}
let selected_instance view = Option.bind view.snapshot (fun snapshot -> List.nth_opt snapshot.instances view.instance_cursor)
let selected_source_path view =
  Option.bind view.snapshot (fun snapshot ->
    Option.bind snapshot.configuration (fun config ->
      let path = match view.focus with
        | Configurations -> Option.map (fun (d : declaration) -> d.source_path) (selected_declaration view)
        | Instances | Rows -> Option.bind (selected_instance view) (fun instance ->
            List.find_map (fun (d : declaration) ->
              if d.instance_id=Some instance.id && Some d.source_path=instance.source_path
              then Some d.source_path else None) config.declarations) in
      Option.bind path (fun path ->
        if Document.editable_source_path ~directory:config.directory path then Some path else None)))
let selected_row view = Option.bind view.snapshot (fun snapshot -> List.nth_opt snapshot.output.rows view.row_cursor)
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
let timeline_lines ~width rows =
  match rows with
  | [] -> []
  | first :: rest ->
      let first : Row.row = first in
      let since, until = List.fold_left (fun (a, b) (row : Row.row) ->
        min a row.observed_at, max b row.observed_at) (first.observed_at, first.observed_at) rest in
      let label_width = min 28 (max 8 (width / 3)) in
      let axis_width = max 2 (width - label_width - 3) in
      let lanes = List.map (fun (row : Row.row) -> row.lane_id) rows |> List.sort_uniq String.compare in
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
          label lane ^ " |" ^ Bytes.to_string axis ^ "|") lanes
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
let technical_lines ~width view =
  let header = ["Optional cross-lane observations; Keeper and existing machine owners continue independently.";
    " n:new TOML  E:edit selected TOML  r:inspect  Tab:installations/instances/rows  :advanced command";
    ("Focus: " ^ match view.focus with Configurations -> "TOML installations" | Instances -> "Instances" | Rows -> "Observation rows");
    (if view.loading then "Request pending; Esc returns to existing activity." else "Retained server observations")] in
  let error = match view.error with None -> [] | Some detail -> ["Error: " ^ detail] in
  let content = match view.snapshot with
    | None -> ["No response yet."]
    | Some snapshot ->
        configuration_lines view snapshot @
        timeline_lines ~width snapshot.output.rows @ ["Instances (Tab changes focus)"] @
        instance_lines view snapshot.instances @
        ["Coverage"] @ List.map (fun (source : Row.coverage) -> Printf.sprintf " %s · %s · cursor %s · %s%s"
          source.source_id source.incarnation (Option.value ~default:"unknown" source.cursor)
          (if source.complete then "complete" else "partial")
          (match source.detail with None -> "" | Some detail -> " · " ^ detail)) snapshot.output.coverage @
        (match snapshot.complete with None -> [] | Some complete -> [if complete then "Slice complete within reported coverage" else "Slice partial"]) @
        ["Cross-lane observations (space selects evidence)"] @
        List.concat (List.mapi (fun i (row : Row.row) ->
          [Printf.sprintf "%s [%s] %.3f · %s · %s · %s"
            (if view.row_cursor = i then ">" else " ") (if List.mem row.id view.selected then "x" else " ")
            row.observed_at row.lane_id row.id row.title;
           Printf.sprintf "   subject %s · actor %s%s" row.subject_id (Option.value ~default:"unknown" row.actor)
             (match row.clock with None -> "" | Some clock -> " · " ^ clock.domain ^ " " ^ clock.value);
           "   fields"] @
           List.map (fun line -> "     " ^ line)
             (String.split_on_char '\n' (Yojson.Safe.pretty_to_string (`Assoc row.fields))) @
           List.map (fun (e : Row.evidence) -> "   evidence " ^ e.uri ^ " · sha256 " ^ Option.value ~default:"unknown" e.sha256) row.evidence @
           (if row.related_ids = [] then [] else ["   related " ^ String.concat ", " row.related_ids])) snapshot.output.rows) in
  let receipt = match view.receipt with None -> [] | Some json ->
    "Last receipt:" :: String.split_on_char '\n' (Yojson.Safe.pretty_to_string json) in
  let draft = match view.draft with None -> [] | Some draft -> [(if view.naming then "New TOML filename: " else ":") ^ draft] in
  let documents = match selected_document view with None -> [] | Some document -> Document.summary document in
  let action = match view.last_action with
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
              @ (match receipt.result with None -> [] | Some result -> String.split_on_char '\n' (Yojson.Safe.pretty_to_string result))) in
  header @ error @ draft @ action @ documents @ content @ receipt
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
           | Some (`String "object"), Some (`Assoc properties), Some (`List required) ->
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
  | Rows -> None

let open_actions ~request_id view =
  let* instance = match action_target view with
    | Some instance -> Ok instance
    | None -> Error "Select an installed Add-on first (Tab:instances)." in
  let* schema = match instance.action_schema with
    | Some schema -> Ok schema
    | None -> Error "This Add-on provides observations only. Press o to observe." in
  let* () = Action.validate_schema schema in
  let* action_schema =
    let* properties = field "properties" schema in
    field "action" properties in
  let* choices = match finite_values action_schema with
    | Some (_::_ as choices) -> Ok choices
    | Some [] | None -> Error "This action needs parameters. D shows its schema; :act accepts an explicit action." in
  let choices = List.filter (fun action ->
    Result.is_ok (Action.validate ~schema ~name:"lane_act"
      (Action.arguments ~instance_id:instance.id ~request_id ~action))) choices in
  if choices=[] then Error "The advertised schema has no valid preset action. D shows details."
  else Ok {view with action_menu=Some {
    target_id=instance.id;target_incarnation=instance.incarnation;target_title=instance.title;request_id;
    schema;choices;cursor=0}; presentation=Summary;scroll=0;error=None}

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
  let* action = match List.nth_opt menu.choices menu.cursor with
    | Some action -> Ok action | None -> Error "No selected action." in
  let* action = Action.canonical action in
  let* _ = Action.validate ~schema:menu.schema ~name:"lane_act"
      (Action.arguments ~instance_id:instance.id ~request_id:menu.request_id ~action) in
  Ok {instance_id=instance.id;incarnation=instance.incarnation;request_id=menu.request_id;action}

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
            (if view.instance_cursor=index && view.focus=Instances then "> " else "  ")
            ^ instance.title ^ " · " ^ phase_label instance.phase
            ^ (if Option.is_some instance.action_schema then " · a:actions" else " · o:observe")) snapshot.instances in
        let configurations = if view.focus<>Configurations then [] else
          ["Installations (E:edit)"] @ (match snapshot.configuration with None -> [] | Some config ->
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
        installations @ instances @ configurations @ observations @ gaps
        @ (match snapshot.complete with Some false -> ["Slice coverage is incomplete"] | Some true | None -> []) in
  ["Select an Add-on, observe its output, or choose an advertised action.";
   "j/k:select  Tab:instances/rows/installations  o:observe  a:actions  S:subscriptions  f:flow  D:details  Esc:back"]
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
           | Some {installation_id=Some id;_} -> id
           | _ -> instance.id in
         let complete = Option.fold ~none:false ~some:(fun (c : configuration) -> c.complete) snapshot.configuration in
         let notices = (if complete then [] else ["Installation inventory incomplete; dependency identities may be unresolved"])
           @ List.concat_map (fun (d : declaration) -> List.map (fun issue -> d.source_path ^ ": " ^ issue) d.issues) declarations in
         notices @ (if snapshot.instances=[] then ["No Add-on instances in the received snapshot"]
         else List.concat_map (fun instance ->
           let target = name instance in
           [(if Option.exists (fun selected -> selected.id=instance.id) (selected_instance view)
             then "> " else "  ") ^ target ^ " · " ^ instance.title ^ " · " ^ phase_label instance.phase]
           @ (match Masc.Lane_addon_sources.dependencies instance.binding with
              | Error detail -> ["  Invalid source binding: " ^ detail]
              | Ok [] -> ["  No upstream Add-on dependency (D shows external/owned source binding)"]
              | Ok upstream -> List.map (fun id ->
                  let available = List.exists (fun candidate ->
                    String.equal (name candidate) id && String.equal candidate.run_id instance.run_id)
                    snapshot.instances in
                  "  " ^ id ^ " -> " ^ target ^ (if available then "" else if complete then " · producer absent in this run"
                    else " · producer unresolved; inventory incomplete")) upstream)
           @ List.map (fun (port,selection) ->
               "  output " ^ port ^ " -> " ^ (match selection with
                 | Row.All_lanes -> "all supplied lanes"
                 | Row.Selected_lanes lanes -> String.concat ", " lanes)) instance.outputs) snapshot.instances))
  @ [""; "Add-on observation -> retained rows/evidence -> explicit selection and use";
     "An installed observer does not automatically fix code or complete a task.";
     "f:back to observations  D:technical details  J/K:scroll"]

let lines ~width view =
  match view.subscription_panel,view.action_menu with
  | Some panel,_ ->
      (Masc_tui_message_layout.fit_width (if view.loading then "Refreshing…" else "Last received subscription state") (max 1 width)
       :: Masc_tui_lane_subscriptions.lines panel)
      |> List.concat_map (fun line -> Masc_tui_message_layout.split_cells ~max_cells:(max 1 width)
           (Masc.Tui_decode.sanitize_terminal_text line))
  | None,Some menu ->
      (["Run action on " ^ menu.target_title;
        Printf.sprintf "Action %d/%d · Up/Down:choose · Enter:run once · Esc:cancel"
          (menu.cursor+1) (List.length menu.choices);
        "J/K:scroll action details"]
       @ (match List.nth_opt menu.choices menu.cursor with
          | Some action -> action_fields "" action
          | None -> ["No selected action"]))
      |> List.concat_map (fun line ->
        Masc_tui_message_layout.split_cells ~max_cells:(max 1 width)
          (Masc.Tui_decode.sanitize_terminal_text line))
  | None,None ->
      if view.presentation=Technical || Option.is_some view.document_key || Option.is_some view.draft
      then technical_lines ~width view
      else (match view.presentation with Flow -> flow_lines view | Summary | Technical -> compact_lines ~width view)
        |> List.concat_map (fun line ->
        Masc_tui_message_layout.split_cells ~max_cells:(max 1 width)
          (Masc.Tui_decode.sanitize_terminal_text line))
