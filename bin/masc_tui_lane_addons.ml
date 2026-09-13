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
type focus = Configurations | Instances | Rows
type t = {
  snapshot : snapshot option; loading : bool; error : string option;
  receipt : Yojson.Safe.t option; generation : int; instance_cursor : int;
  row_cursor : int; selected : string list; scroll : int; focus : focus;
  draft : string option; naming : bool; configuration_cursor : int;
  documents : Document.session list; document_key : string option; editor_ready : bool; last_action : action_request option; action_receipt : Action.receipt option;
}
let initial = { snapshot = None; loading = false; error = None; receipt = None;
  generation = 0; instance_cursor = 0; row_cursor = 0; selected = []; scroll = 0;
  focus = Configurations; draft = None; naming = false; configuration_cursor = 0;
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
let lines ~width view =
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
