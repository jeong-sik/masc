module Row = Masc.Lane_addon_types
type instance = {
  id : string; run_id : string; addon_id : string; title : string;
  revision : string; phase : Row.phase; observation_seq : int; rows_count : int;
}
type snapshot = { instances : instance list; output : Row.output; complete : bool option }
type request = Inspect | Attach of Yojson.Safe.t | Observe of string | Detach of string
  | Slice of (string * string) list | Evidence of Yojson.Safe.t
type focus = Instances | Rows
type t = {
  snapshot : snapshot option; loading : bool; error : string option;
  receipt : Yojson.Safe.t option; generation : int; instance_cursor : int;
  row_cursor : int; selected : string list; scroll : int; focus : focus;
  draft : string option;
}
let initial = { snapshot = None; loading = false; error = None; receipt = None;
  generation = 0; instance_cursor = 0; row_cursor = 0; selected = []; scroll = 0;
  focus = Instances; draft = None }
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
  Ok { id; run_id; addon_id; title; revision; phase; observation_seq; rows_count }
let output json =
  let* rows = field "rows" json in
  let* coverage = field "coverage" json in
  Row.output_of_json (`Assoc ["rows", rows; "coverage", coverage])
let decode json =
  let* instances = get (array instance) "instances" json in
  let* output = output json in Ok { instances; output; complete = None }
let decode_slice ~instances json =
  let* output = output json in
  let* complete = get (function `Bool value -> Ok value | _ -> Error "expected complete boolean") "complete" json in
  Ok { instances; output; complete = Some complete }
let json_object arg =
  try match Yojson.Safe.from_string arg with
    | `Assoc _ as json -> Ok json
    | _ -> Error "expected JSON object"
  with Yojson.Json_error detail -> Error detail
let parse_request input =
  let input = String.trim input in
  let command, arg = match String.index_opt input ' ' with
    | None -> input, ""
    | Some i -> String.sub input 0 i, String.trim (String.sub input (i + 1) (String.length input - i - 1)) in
  match command, arg with
  | ("" | "inspect"), "" -> Ok Inspect
  | "observe", id when id <> "" -> Ok (Observe id)
  | "detach", id when id <> "" -> Ok (Detach id)
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
  | _ -> Error "Use inspect, attach {manifest_path,run_id,binding}, observe ID, detach ID, slice {run_id,since,until,lane_id}, evidence {instance_id,row_ids,keeper_name?}"
let selected_instance view = Option.bind view.snapshot (fun snapshot -> List.nth_opt snapshot.instances view.instance_cursor)
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
let lines ?(width = 100) view =
  let header = ["Optional cross-lane observations; Keeper and existing machine owners continue independently.";
    " :command · inspect | attach JSON | observe ID | detach ID | slice JSON | evidence JSON";
    (if view.loading then "Request pending; Esc returns to existing activity." else "Retained server observations")] in
  let error = match view.error with None -> [] | Some detail -> ["Error: " ^ detail] in
  let content = match view.snapshot with
    | None -> ["No response yet."]
    | Some snapshot ->
        timeline_lines ~width snapshot.output.rows @ ["Instances (Tab changes focus)"] @
        List.mapi (fun i item -> Printf.sprintf "%s %s · %s · %s · run %s · rev %s · seq %d · rows %d"
          (if view.instance_cursor = i then ">" else " ") item.id item.title (phase_label item.phase)
          item.run_id item.revision item.observation_seq item.rows_count) snapshot.instances @
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
           "   fields " ^ Yojson.Safe.to_string (`Assoc row.fields)] @
           List.map (fun (e : Row.evidence) -> "   evidence " ^ e.uri ^ " · sha256 " ^ Option.value ~default:"unknown" e.sha256) row.evidence @
           (if row.related_ids = [] then [] else ["   related " ^ String.concat ", " row.related_ids])) snapshot.output.rows) in
  let receipt = match view.receipt with None -> [] | Some json -> ["Last receipt: " ^ Yojson.Safe.to_string json] in
  let draft = match view.draft with None -> [] | Some draft -> [":" ^ draft] in
  header @ error @ draft @ content @ receipt
