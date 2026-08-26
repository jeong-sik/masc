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

let required_int fields name =
  match List.assoc_opt name fields with
  | Some (`Int value) -> Ok value
  | Some value ->
    Error
      (Printf.sprintf "%s must be an integer, got %s" name
         (Json_util.kind_name value))
  | None -> Error (name ^ " is absent")

let line_range_of_yojson = function
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let* start_line = required_int fields "start_line" in
    let* end_line = required_int fields "end_line" in
    if start_line < 1
    then Error "start_line must be at least 1"
    else if end_line < start_line
    then Error "end_line must not precede start_line"
    else Ok { start_line; end_line }
  | value ->
    Error
      (Printf.sprintf "line range must be an object, got %s"
         (Json_util.kind_name value))

let optional_line_range_of_yojson = function
  | `Null -> Ok None
  | value -> Result.map Option.some (line_range_of_yojson value)

let occurrence_of_yojson = function
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let* old_range =
      match List.assoc_opt "old_range" fields with
      | Some value -> line_range_of_yojson value
      | None -> Error "old_range is absent"
    in
    let* new_range =
      match List.assoc_opt "new_range" fields with
      | Some value -> optional_line_range_of_yojson value
      | None -> Error "new_range is absent"
    in
    Ok { old_range; new_range }
  | value ->
    Error
      (Printf.sprintf "edit occurrence must be an object, got %s"
         (Json_util.kind_name value))

let decode_occurrences values =
  let rec loop decoded = function
    | [] -> Ok (List.rev decoded)
    | value :: rest ->
      (match occurrence_of_yojson value with
       | Ok occurrence -> loop (occurrence :: decoded) rest
       | Error _ as error -> error)
  in
  loop [] values

let list_has_exact_length expected values =
  let rec loop remaining = function
    | [] -> remaining = 0
    | _ :: _ when remaining = 0 -> false
    | _ :: rest -> loop (remaining - 1) rest
  in
  loop expected values

let of_yojson = function
  | `Assoc fields ->
    (match List.assoc_opt "kind" fields with
     | Some (`String "edit") ->
       let ( let* ) = Result.bind in
       let* occurrence_count = required_int fields "occurrence_count" in
       if occurrence_count < 1
       then Error "edit occurrence_count must be positive"
       else
         (match List.assoc_opt "occurrences" fields with
          | Some `Null ->
            if occurrence_count <= max_recorded_edit_occurrences
            then Error "edit ranges may be omitted only above the durable limit"
            else Ok (Edited { occurrence_count; occurrences = None })
          | Some (`List values) ->
            if occurrence_count > max_recorded_edit_occurrences
            then Error "edit occurrence list exceeds the durable limit"
            else if not (list_has_exact_length occurrence_count values)
            then Error "edit occurrence_count does not match occurrences"
            else
              let* occurrences = decode_occurrences values in
              Ok (Edited { occurrence_count; occurrences = Some occurrences })
          | Some value ->
            Error
              (Printf.sprintf "occurrences must be an array or null, got %s"
                 (Json_util.kind_name value))
          | None -> Error "occurrences is absent")
     | Some (`String "write") ->
       (match List.assoc_opt "new_range" fields with
        | Some value ->
          Result.bind (optional_line_range_of_yojson value) (fun new_range ->
            match new_range with
            | Some range when range.start_line <> 1 ->
              Error "write new_range must start at line one"
            | Some _ | None -> Ok (Written { new_range }))
        | None -> Error "new_range is absent")
     | Some (`String kind) -> Error (Printf.sprintf "unknown evidence kind %S" kind)
     | Some value ->
       Error
         (Printf.sprintf "kind must be a string, got %s" (Json_util.kind_name value))
     | None -> Error "kind is absent")
  | value ->
    Error
      (Printf.sprintf "file change evidence must be an object, got %s"
         (Json_util.kind_name value))
