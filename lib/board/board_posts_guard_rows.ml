type framing = Complete | Torn of { rows_end : int; end_offset : int }

let framing ~rows_end ~end_offset =
  if rows_end = end_offset then Complete else Torn { rows_end; end_offset }

let framing_to_yojson = function
  | Complete -> `Assoc [ "state", `String "complete" ]
  | Torn { rows_end; end_offset } -> `Assoc [
      "state", `String "torn_tail"; "rows_end", `Int rows_end; "end_offset", `Int end_offset ]

type rows = {
  physical_rows : int;
  first_row : string option;
}

let empty = { physical_rows = 0; first_row = None }

let add_row rows text = {
  physical_rows = rows.physical_rows + 1;
  first_row = (match rows.first_row with None -> Some text | Some _ -> rows.first_row);
}

let physical_rows rows = rows.physical_rows

type validation =
  | Valid_guard of Board_posts_guard_json.t
  | Torn_guard
  | Guard_row_count_rejected of int
  | Guard_row_rejected of Board_posts_guard_json.rejection

let validate ~framing rows = match framing with
  | Torn _ -> Torn_guard
  | Complete ->
    (match rows.physical_rows, rows.first_row with
     | 1, Some text ->
       (match Board_posts_guard_json.decode_row ~line:1 text with
        | Ok guard -> Valid_guard guard
        | Error error -> Guard_row_rejected error)
     | count, (None | Some _) -> Guard_row_count_rejected count)

let rejection_to_yojson = function
  | Board_posts_guard_json.Invalid_json { line; detail } -> `Assoc [
      "kind", `String "invalid_json"; "line", `Int line; "detail", `String detail ]
  | Field_set_rejected -> `Assoc [ "kind", `String "field_set_rejected" ]
  | Schema_not_string -> `Assoc [ "kind", `String "schema_not_string" ]
  | Unsupported_schema observed -> `Assoc [
      "kind", `String "unsupported_schema"; "observed", `String observed ]
  | Invalid_generation -> `Assoc [ "kind", `String "invalid_generation" ]

let validation_to_yojson = function
  | Valid_guard guard -> `Assoc [
      "state", `String "valid"; "generation", `String (Board_posts_guard_json.generation guard) ]
  | Torn_guard -> `Assoc [ "state", `String "torn_tail" ]
  | Guard_row_count_rejected count -> `Assoc [
      "state", `String "row_count_rejected"; "physical_rows", `Int count ]
  | Guard_row_rejected error -> `Assoc [
      "state", `String "row_rejected"; "error", rejection_to_yojson error ]
