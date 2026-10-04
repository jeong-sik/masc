type recent = { timestamp : float; input : int option; output : int option }
type stats = {
  id : string; samples : int; successes : int; errors : int;
  usage_samples : int; telemetry_samples : int;
  cached : (int * int * int) option; cost : float option; recent : recent list;
}
type specification = {
  id : string; catalog : int option; output : int option;
  model : int option; provider : int option; binding : int option;
}
type history = Loading | Unavailable
  | Decision_directory_unavailable | Decision_files_unreadable of int
  | Observed of {
  window : int; generated_at : float; stale : bool; refresh_failed : bool; unattributed : int;
  store_note : string; runtimes : stats list;
}
type t = { history : history; specifications : specification list }
let ( let* ) = Result.bind
let field name = function `Assoc fields -> List.assoc_opt name fields | _ -> None
let required name json = match field name json with
  | Some value -> Ok value | None -> Error ("runtime evidence missing " ^ name)
let text = function `String value when value <> "" -> Ok value | _ -> Error "runtime evidence has an invalid identity"
let nat = function `Int n when n >= 0 -> Ok n | _ -> Error "runtime evidence has an invalid count"
let number = function
  | `Float n when Float.is_finite n && n >= 0. -> Ok n
  | `Int n when n >= 0 -> Ok (float_of_int n)
  | _ -> Error "runtime evidence has an invalid measurement"
let optional parse = function `Null -> Ok None | value -> Result.map Option.some (parse value)
let member parse name json = let* value = required name json in parse value
let rec rows parse = function
  | [] -> Ok []
  | value :: rest -> let* value = parse value in let* rest = rows parse rest in Ok (value :: rest)
let list parse = function `List values -> rows parse values | _ -> Error "runtime evidence has an invalid list"
let unique ids = List.length ids = List.length (List.sort_uniq String.compare ids)
let recent json =
  let* timestamp = member number "ts_unix" json in
  let* outcome = member text "outcome" json in
  let* input = member (optional nat) "input_tokens" json in
  let* output = member (optional nat) "output_tokens" json in
  if outcome = "success" then Ok {timestamp; input; output}
  else Error "runtime recent success has an unrecognized outcome"
let cached = function
  | `Null -> Ok None
  | json ->
    let* input = member nat "input_tokens" json in
    let* read = member nat "cache_read_tokens" json in
    let* samples = member nat "sample_count" json in
    if input > 0 && read <= input && samples > 0 then Ok (Some (input, read, samples))
    else Error "runtime cache evidence has an invalid denominator"
let stats json =
  let* id = member text "runtime_id" json in
  let* samples = member nat "entry_count" json in
  let* successes = member nat "success_count" json in
  let* errors = member nat "error_count" json in
  let* usage_samples = member nat "usage_sample_count" json in
  let* telemetry_samples = member nat "telemetry_sample_count" json in
  let* cached = member cached "cached_input" json in
  let* cost = member (optional number) "total_cost_usd" json in
  let* recent = member (list recent) "recent_entries" json in
  if samples <> successes + errors || usage_samples > successes || telemetry_samples > successes
     || (match cached with Some (_, _, count) -> count > successes | None -> false)
     || List.length recent > successes then Error "runtime evidence counts disagree"
  else Ok {id; samples; successes; errors; usage_samples; telemetry_samples; cached; cost;
           recent = List.sort (fun a b -> Float.compare b.timestamp a.timestamp) recent}
let specification json =
  let* id = member text "runtime_id" json in
  let* catalog = member (optional nat) "catalog_context" json in
  let* output = member (optional nat) "catalog_max_output" json in
  let* model = member (optional nat) "model_context" json in
  let* provider = member (optional nat) "provider_context" json in
  let* binding = member (optional nat) "binding_context" json in
  Ok {id; catalog; output; model; provider; binding}
let history json =
  let* state = member text "state" json in
  let* cache = required "cache" json in
  let* refresh_failed = match field "last_error" cache with
    | None | Some `Null -> Ok false
    | Some (`String _) -> Ok true
    | Some _ -> Error "runtime evidence has an invalid refresh error" in
  match state with
  | "loading" -> Ok (if refresh_failed then Unavailable else Loading)
  | "unavailable" ->
    let* diagnostic = required "decision_read" json in
    let* cause = member text "cause" diagnostic in
    (match cause with
     | "directory_unavailable" -> Ok Decision_directory_unavailable
     | "files_unreadable" ->
       let* count = member nat "unreadable_files" diagnostic in
       if count > 0 then Ok (Decision_files_unreadable count)
       else Error "runtime history has an invalid unreadable file count"
     | _ -> Error "runtime history has an unrecognized decision read failure")
  | "ready" ->
    let* window = member nat "window_minutes" json in
    let* unattributed = member nat "unattributed_entries" json in
    let* runtimes = member (list stats) "runtimes" json in
    let* cache_state = member text "state" cache in
    let* generated_at = member number "observed_at" json in
    let* stale = match cache_state with
      | "fresh" -> Ok false | "stale_refreshing" -> Ok true
      | _ -> Error "runtime evidence has an unconfirmed cache state" in
    let* store = required "cost_read" json in
    let* store_state = member text "state" store in
    let* store_note = match store_state with
      | "unavailable" -> Ok "cost store unavailable; decision records only"
      | "available" ->
        let* malformed = member nat "malformed_rows" store in
        let* violations = member nat "schema_violation_rows" store in
        let* conflicts = member nat "identity_conflict_rows" store in
        Ok (Printf.sprintf "%d malformed, %d schema, %d conflicting cost rows excluded"
          malformed violations conflicts)
      | _ -> Error "runtime evidence has an unrecognized cost read state" in
    if unique (List.map (fun (row : stats) -> row.id) runtimes) then
      Ok (Observed {window; generated_at; stale; refresh_failed; unattributed; store_note; runtimes})
    else Error "runtime evidence repeats a runtime identity"
  | _ -> Error "runtime history state is unavailable"
let decode json =
  let* history = member history "history" json in
  let* specifications = member (list specification) "specifications" json in
  if unique (List.map (fun (row : specification) -> row.id) specifications)
  then Ok {history; specifications}
  else Error "runtime specifications repeat an identity"
let timestamp ts =
  let tm = Unix.localtime ts in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec
let count = function Some n -> string_of_int n | None -> "not reported"
let lines t ~runtime_id =
  let specifications = match List.find_opt (fun (row : specification) -> row.id = runtime_id) t.specifications with
    | None -> ["Original context", "unavailable; no specification reading for this runtime"]
    | Some row -> [
        "Specification", "current configuration; historical calls may use earlier settings";
        "Catalog context", count row.catalog;
        "Catalog max output", count row.output;
        "Declared context", Printf.sprintf "model %s / provider %s / binding %s tokens"
          (count row.model) (count row.provider) (count row.binding)] in
  let history = match t.history with
    | Loading -> ["Runtime history", "loading; refresh to read the completed snapshot"]
    | Unavailable -> ["Runtime history", "snapshot refresh failed; no history available"]
    | Decision_directory_unavailable ->
        ["Runtime history", "unavailable; decision log directory could not be read"]
    | Decision_files_unreadable count ->
        ["Runtime history", Printf.sprintf
          "incomplete; %d decision log files could not be read; runtime totals unavailable" count]
    | Observed observed ->
      ["History window", Printf.sprintf "last %d min, snapshot %s%s"
        observed.window (timestamp observed.generated_at)
        (if observed.refresh_failed then " (stale, refresh failed)"
         else if observed.stale then " (stale, refreshing)" else "");
       "Attribution", Printf.sprintf "executed runtime ID; %d records without an answerer excluded" observed.unattributed;
       "Store coverage", observed.store_note]
      @ (match List.find_opt (fun (row : stats) -> row.id = runtime_id) observed.runtimes with
        | None -> ["Runtime samples", "none attributed in this window";
                   "Last success", "not observed in this window"; "Cache hit", "not reported"]
        | Some row -> [
            "Runtime samples", Printf.sprintf "%d recorded / %d successful / %d errors"
              row.samples row.successes row.errors;
            "Sample coverage", Printf.sprintf "usage %d/%d successes; telemetry %d/%d successes"
              row.usage_samples row.successes row.telemetry_samples row.successes;
            "Last success", (match row.recent with first :: _ -> timestamp first.timestamp | [] -> "not observed in this window");
            "Cache hit", (match row.cached with
              | None -> "not reported; no valid input/cache pairs"
              | Some (input, read, samples) -> Printf.sprintf "%.1f%% input tokens (%d/%d); %d/%d successful samples"
                  (100. *. float_of_int read /. float_of_int input) read input samples row.successes);
            "Recorded cost", (match row.cost with None -> "not reported" | Some cost -> Printf.sprintf "$%.4f (recorded samples)" cost)]
          @ List.map (fun row -> "Recent success", Printf.sprintf "%s · input %s / output %s tokens"
              (timestamp row.timestamp) (count row.input) (count row.output)) row.recent) in
  specifications @ history
