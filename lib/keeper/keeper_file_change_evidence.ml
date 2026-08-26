type line_range = {
  start_line : int;
  end_line : int;
}

type edit_occurrence = {
  old_range : line_range;
  new_range : line_range option;
}

type t =
  | Edited of {
      occurrence_count : int;
      occurrences : edit_occurrence list option;
    }
  | Written of { new_range : line_range option }

let max_recorded_edit_occurrences = 512

let line_count text =
  if String.equal text "" then 0
  else
    let lines = ref 1 in
    String.iter (fun char -> if Char.equal char '\n' then incr lines) text;
    if Char.equal text.[String.length text - 1] '\n' then !lines - 1
    else !lines

let advance_line ~start_line text =
  let line = ref start_line in
  String.iter (fun char -> if Char.equal char '\n' then incr line) text;
  !line

let range_for_text ~start_line text =
  match line_count text with
  | 0 -> None
  | count -> Some { start_line; end_line = start_line + count - 1 }

let edit_occurrence ~old_start_line ~new_start_line ~old_string ~new_string =
  if old_start_line < 1 || new_start_line < 1 then
    invalid_arg "file change line starts must be 1-based";
  if String.equal old_string "" then
    invalid_arg "Edit evidence requires a non-empty old_string";
  let old_range =
    match range_for_text ~start_line:old_start_line old_string with
    | Some range -> range
    | None -> invalid_arg "Edit evidence requires a non-empty old_string"
  in
  { old_range;
    new_range = range_for_text ~start_line:new_start_line new_string;
  }

let edited occurrences =
  match occurrences with
  | [] -> invalid_arg "completed Edit evidence requires an occurrence"
  | _ :: _ ->
    let occurrence_count = List.length occurrences in
    if occurrence_count > max_recorded_edit_occurrences then
      invalid_arg "Edit evidence range list exceeds the durable record limit";
    Edited { occurrence_count; occurrences = Some occurrences }

let edited_ranges_omitted ~occurrence_count =
  if occurrence_count <= max_recorded_edit_occurrences then
    invalid_arg "omitted Edit ranges require an occurrence count above the limit";
  Edited { occurrence_count; occurrences = None }

let written content =
  Written { new_range = range_for_text ~start_line:1 content }

let line_range_to_yojson range =
  `Assoc
    [ "start_line", `Int range.start_line;
      "end_line", `Int range.end_line;
    ]

let optional_line_range_to_yojson = function
  | Some range -> line_range_to_yojson range
  | None -> `Null

let occurrence_to_yojson occurrence =
  `Assoc
    [ "old_range", line_range_to_yojson occurrence.old_range;
      "new_range", optional_line_range_to_yojson occurrence.new_range;
    ]

let to_yojson = function
  | Edited { occurrence_count; occurrences } ->
      `Assoc
        [ "kind", `String "edit";
          "occurrence_count", `Int occurrence_count;
          ( "occurrences"
          , match occurrences with
            | Some occurrences ->
              `List (List.map occurrence_to_yojson occurrences)
            | None -> `Null );
        ]
  | Written { new_range } ->
      `Assoc
        [ "kind", `String "write";
          "new_range", optional_line_range_to_yojson new_range;
        ]
