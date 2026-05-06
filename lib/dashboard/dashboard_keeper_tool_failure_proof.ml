type failure_class = {
  category : string;
  count : int;
  sample : string option;
}

type tool_keeper_stat = {
  name : string;
  calls : int;
  successes : int;
  success_pct : float;
  keepers : string list;
  successful_keepers : string list;
  failed_keepers : string list;
  sandbox_profiles : string list;
  network_modes : string list;
  task_ids : string list;
  goal_ids : string list;
  latest_ts : float option;
  latest_success_ts : float option;
  latest_failure_ts : float option;
}

type mutable_tool_keeper_stat = {
  calls : int ref;
  successes : int ref;
  keepers : (string, unit) Hashtbl.t;
  successful_keepers : (string, unit) Hashtbl.t;
  failed_keepers : (string, unit) Hashtbl.t;
  sandbox_profiles : (string, unit) Hashtbl.t;
  network_modes : (string, unit) Hashtbl.t;
  task_ids : (string, unit) Hashtbl.t;
  goal_ids : (string, unit) Hashtbl.t;
  latest_ts : float option ref;
  latest_success_ts : float option ref;
  latest_failure_ts : float option ref;
}

let bool_field_opt record field =
  match record with
  | `Assoc fields ->
    (match List.assoc_opt field fields with
     | Some (`Bool value) -> Some value
     | _ -> None)
  | _ -> None

let tool_success_of_record record =
  match bool_field_opt record "semantic_success" with
  | Some value -> value
  | None ->
    (match bool_field_opt record "success" with
     | Some value -> value
     | None -> false)

let float_field_opt record field =
  match record with
  | `Assoc fields ->
    (match List.assoc_opt field fields with
     | Some (`Float value) -> Some value
     | Some (`Int value) -> Some (Float.of_int value)
     | _ -> None)
  | _ -> None

let string_list_field record field =
  match record with
  | `Assoc fields ->
    (match List.assoc_opt field fields with
     | Some (`List values) ->
       values
       |> List.filter_map (function
         | `String value when String.trim value <> "" -> Some value
         | _ -> None)
     | _ -> [])
  | _ -> []

let output_text record =
  match record with
  | `Assoc fields ->
    (match List.assoc_opt "output" fields with
     | Some (`String text) -> text
     | Some (`Assoc [("_blob", `Assoc blob)]) ->
       (match List.assoc_opt "preview" blob with
        | Some (`String preview) -> preview
        | _ -> "")
     | Some json -> Yojson.Safe.to_string json
     | None -> "")
  | _ -> ""

let compact_text ?(limit = 240) text =
  let trimmed =
    text
    |> String.map (function '\n' | '\r' | '\t' -> ' ' | c -> c)
    |> String.trim
  in
  if String.length trimmed > limit then
    String.sub trimmed 0 limit ^ "..."
  else trimmed

let compact_category text =
  let key = compact_text ~limit:120 text in
  if key = "" then "unknown_error" else key

let compact_sample = compact_text ~limit:240

let read_records ?window_hours ~n () =
  match window_hours with
  | Some hours when hours > 0.0 ->
    Keeper_tool_call_log.read_window ~window_hours:hours ()
  | _ -> Keeper_tool_call_log.read_recent ~n ()

let known_keeper_table keeper_names =
  let table = Hashtbl.create (List.length keeper_names) in
  List.iter
    (fun keeper_name ->
       let keeper_name = String.trim keeper_name in
       if keeper_name <> "" then Hashtbl.replace table keeper_name ())
    keeper_names;
  table

let add_set table value =
  let value = String.trim value in
  if value <> "" then Hashtbl.replace table value ()

let sorted_set table =
  Hashtbl.fold (fun value () acc -> value :: acc) table []
  |> List.sort_uniq String.compare

let empty_mutable_stat () =
  {
    calls = ref 0;
    successes = ref 0;
    keepers = Hashtbl.create 8;
    successful_keepers = Hashtbl.create 8;
    failed_keepers = Hashtbl.create 8;
    sandbox_profiles = Hashtbl.create 4;
    network_modes = Hashtbl.create 4;
    task_ids = Hashtbl.create 8;
    goal_ids = Hashtbl.create 8;
    latest_ts = ref None;
    latest_success_ts = ref None;
    latest_failure_ts = ref None;
  }

let update_latest latest ts =
  match !latest with
  | Some previous when previous >= ts -> ()
  | _ -> latest := Some ts

let add_tool_stat table record =
  match
    Safe_ops.json_string_opt "tool" record,
    Safe_ops.json_string_opt "keeper" record
  with
  | Some tool, Some keeper when String.trim tool <> "" && String.trim keeper <> "" ->
    let stat =
      match Hashtbl.find_opt table tool with
      | Some stat -> stat
      | None ->
        let stat = empty_mutable_stat () in
        Hashtbl.replace table tool stat;
        stat
    in
    let ok = tool_success_of_record record in
    incr stat.calls;
    if ok then incr stat.successes;
    add_set stat.keepers keeper;
    if ok then add_set stat.successful_keepers keeper
    else add_set stat.failed_keepers keeper;
    Option.iter (add_set stat.sandbox_profiles)
      (Safe_ops.json_string_opt "sandbox_profile" record);
    Option.iter (add_set stat.network_modes)
      (Safe_ops.json_string_opt "network_mode" record);
    Option.iter (add_set stat.task_ids)
      (Safe_ops.json_string_opt "task_id" record);
    List.iter (add_set stat.goal_ids) (string_list_field record "goal_ids");
    let ts = float_field_opt record "ts" in
    Option.iter (update_latest stat.latest_ts) ts;
    if ok then Option.iter (update_latest stat.latest_success_ts) ts
    else Option.iter (update_latest stat.latest_failure_ts) ts
  | _ -> ()

let materialize_tool_stat name stat =
  let calls = !(stat.calls) in
  let successes = !(stat.successes) in
  let success_pct =
    if calls = 0 then 0.0
    else Float.of_int successes /. Float.of_int calls *. 100.0
  in
  {
    name;
    calls;
    successes;
    success_pct;
    keepers = sorted_set stat.keepers;
    successful_keepers = sorted_set stat.successful_keepers;
    failed_keepers = sorted_set stat.failed_keepers;
    sandbox_profiles = sorted_set stat.sandbox_profiles;
    network_modes = sorted_set stat.network_modes;
    task_ids = sorted_set stat.task_ids;
    goal_ids = sorted_set stat.goal_ids;
    latest_ts = !(stat.latest_ts);
    latest_success_ts = !(stat.latest_success_ts);
    latest_failure_ts = !(stat.latest_failure_ts);
  }

let keeper_stats_by_tool ?window_hours ~n ~keeper_names () =
  let known_keepers = known_keeper_table keeper_names in
  let table = Hashtbl.create 64 in
  read_records ?window_hours ~n ()
  |> List.iter (fun record ->
    match Safe_ops.json_string_opt "keeper" record with
    | Some keeper when Hashtbl.mem known_keepers keeper ->
      add_tool_stat table record
    | _ -> ());
  let out = Hashtbl.create (Hashtbl.length table) in
  Hashtbl.iter
    (fun name stat -> Hashtbl.replace out name (materialize_tool_stat name stat))
    table;
  out

let add_failure table tool category sample =
  let key = compact_category category in
  let by_category =
    match Hashtbl.find_opt table tool with
    | Some categories -> categories
    | None ->
      let categories = Hashtbl.create 8 in
      Hashtbl.replace table tool categories;
      categories
  in
  let count, saved_sample =
    match Hashtbl.find_opt by_category key with
    | Some values -> values
    | None ->
      let values = (ref 0, ref None) in
      Hashtbl.replace by_category key values;
      values
  in
  incr count;
  if !saved_sample = None && String.trim sample <> "" then
    saved_sample := Some sample

let keeper_record_filter keeper_names =
  let known_keepers = known_keeper_table keeper_names in
  fun record ->
    match Safe_ops.json_string_opt "keeper" record with
    | Some keeper when Hashtbl.mem known_keepers keeper -> true
    | _ -> false

let by_tool ?window_hours ?keeper_names ~n () =
  let include_record =
    match keeper_names with
    | Some names -> keeper_record_filter names
    | None -> fun _record -> true
  in
  let table = Hashtbl.create 64 in
  read_records ?window_hours ~n ()
  |> List.iter (fun record ->
    if include_record record && not (tool_success_of_record record) then
      match Safe_ops.json_string_opt "tool" record with
      | None -> ()
      | Some tool ->
        let output = output_text record in
        let category = Dashboard_http_tool_quality.classify_failure_output output in
        add_failure table tool category (compact_sample output));
  table

let classes_for table tool =
  match Hashtbl.find_opt table tool with
  | None -> []
  | Some categories ->
    Hashtbl.fold
      (fun category (count, sample) acc ->
         { category; count = !count; sample = !sample } :: acc)
      categories []
    |> List.sort (fun a b ->
      match Int.compare b.count a.count with
      | 0 -> String.compare a.category b.category
      | n -> n)

let class_json item =
  `Assoc [
    ("category", `String item.category);
    ("count", `Int item.count);
    ( "sample",
      match item.sample with
      | Some sample -> `String sample
      | None -> `Null );
  ]

let classes_json table tool =
  `List (classes_for table tool |> List.map class_json)

let string_list_json values =
  `List (List.map (fun value -> `String value) values)

let stat_json (stat : tool_keeper_stat) =
  let ts_fields key ts_opt =
    match ts_opt with
    | None -> [(key ^ "_ts", `Null); (key ^ "_at", `Null)]
    | Some ts ->
      [
        (key ^ "_ts", `Float ts);
        (key ^ "_at", `String (Masc_domain.iso8601_of_unix_seconds ts));
      ]
  in
  `Assoc
    ([
       ("name", `String stat.name);
       ("calls", `Int stat.calls);
       ("successes", `Int stat.successes);
       ("success_pct", `Float stat.success_pct);
       ("keepers", string_list_json stat.keepers);
       ("successful_keepers", string_list_json stat.successful_keepers);
       ("failed_keepers", string_list_json stat.failed_keepers);
       ("sandbox_profiles", string_list_json stat.sandbox_profiles);
       ("network_modes", string_list_json stat.network_modes);
       ("task_ids", string_list_json stat.task_ids);
       ("goal_ids", string_list_json stat.goal_ids);
     ]
     @ ts_fields "latest" stat.latest_ts
     @ ts_fields "latest_success" stat.latest_success_ts
     @ ts_fields "latest_failure" stat.latest_failure_ts)

let empty_stat_json tool =
  `Assoc [
    ("name", `String tool);
    ("calls", `Int 0);
    ("successes", `Int 0);
    ("success_pct", `Float 0.0);
    ("keepers", `List []);
    ("successful_keepers", `List []);
    ("failed_keepers", `List []);
    ("sandbox_profiles", `List []);
    ("network_modes", `List []);
    ("task_ids", `List []);
    ("goal_ids", `List []);
    ("latest_ts", `Null);
    ("latest_at", `Null);
    ("latest_success_ts", `Null);
    ("latest_success_at", `Null);
    ("latest_failure_ts", `Null);
    ("latest_failure_at", `Null);
  ]

let keeper_evidence_json
      (table : (string, tool_keeper_stat) Hashtbl.t)
      ~keeper_names
      ~required_tools
  =
  let observed_keepers =
    required_tools
    |> List.filter_map (Hashtbl.find_opt table)
    |> List.concat_map (fun (stat : tool_keeper_stat) -> stat.successful_keepers)
    |> List.sort_uniq String.compare
  in
  let missing_keepers =
    keeper_names
    |> List.filter (fun keeper_name ->
      not (List.exists (String.equal keeper_name) observed_keepers))
    |> List.sort_uniq String.compare
  in
  let per_tool =
    required_tools
    |> List.map (fun tool ->
      match Hashtbl.find_opt table tool with
      | Some stat -> stat_json stat
      | None -> empty_stat_json tool)
  in
  `Assoc [
    ("provenance_scope", `String "known_keeper_tool_call_log");
    ("keeper_count", `Int (List.length keeper_names));
    ("observed_keepers", string_list_json observed_keepers);
    ("missing_keepers", string_list_json missing_keepers);
    ("per_tool", `List per_tool);
  ]
