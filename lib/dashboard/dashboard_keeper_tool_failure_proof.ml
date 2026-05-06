type failure_class = {
  category : string;
  count : int;
  sample : string option;
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

let by_tool ?window_hours ~n () =
  let table = Hashtbl.create 64 in
  read_records ?window_hours ~n ()
  |> List.iter (fun record ->
    if not (tool_success_of_record record) then
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
