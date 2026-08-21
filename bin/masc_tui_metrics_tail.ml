module Decode = Masc.Tui_decode

type row_error =
  | Malformed_json of {
      path : string;
      line_number : int option;
      detail : string;
    }
  | Invalid_metrics_row of {
      physical_index : int;
      detail : string;
    }

type load_error =
  | Storage_error of Dated_jsonl.read_error
  | Row_errors of {
      physical_rows : int;
      errors : row_error list;
    }

type snapshot = {
  entries : Decode.log_entry list;
  error : load_error option;
}

let empty = { entries = []; error = None }

let row_error_to_string = function
  | Malformed_json { path; line_number; detail } ->
      let location =
        match line_number with
        | Some line -> Printf.sprintf "%s:%d" path line
        | None -> path
      in
      Printf.sprintf "malformed JSON at %s: %s" location detail
  | Invalid_metrics_row { physical_index; detail } ->
      Printf.sprintf "physical row %d is not current Keeper metrics: %s"
        physical_index detail

let error_to_string = function
  | Storage_error error ->
      "metrics storage read failed: " ^ Dated_jsonl.read_error_to_string error
  | Row_errors { physical_rows; errors } ->
      let rejected = List.length errors in
      let first =
        match errors with
        | first :: _ -> row_error_to_string first
        | [] -> "unknown row error"
      in
      let suffix =
        if rejected <= 1 then ""
        else Printf.sprintf " (+%d more)" (rejected - 1)
      in
      Printf.sprintf "metrics tail rejected %d/%d physical rows: %s%s" rejected
        physical_rows first suffix

let resolve_with ~read_recent ~limit =
  match read_recent limit with
  | Error error -> { entries = []; error = Some (Storage_error error) }
  | Ok rows ->
      let indexed = List.mapi (fun index row -> index + 1, row) rows in
      let entries, errors =
        List.fold_right
          (fun (physical_index, row) (entries, errors) ->
            match row with
            | Dated_jsonl.Parsed json -> (
                match Decode.decode_log_entry json with
                | Ok entry -> entry :: entries, errors
                | Error detail ->
                    ( entries,
                      Invalid_metrics_row { physical_index; detail } :: errors ))
            | Dated_jsonl.Malformed_json { path; line_number; detail } ->
                ( entries,
                  Malformed_json { path; line_number; detail } :: errors ))
          indexed ([], [])
      in
      let error =
        match errors with
        | [] -> None
        | _ -> Some (Row_errors { physical_rows = List.length rows; errors })
      in
      { entries; error }

let load ~store ~limit =
  resolve_with ~read_recent:(Dated_jsonl.read_recent_result store) ~limit

let for_selection ~load = function
  | Some keeper -> load keeper
  | None -> empty

let reconcile_selection ~current ~previous_keeper ~selected_keeper =
  match previous_keeper, selected_keeper with
  | Some previous, Some selected when String.equal previous selected -> current
  | Some _, Some _ | Some _, None | None, Some _ | None, None -> empty

let content_height ~terminal_rows ~error =
  let diagnostic_rows = if Option.is_some error then 2 else 0 in
  max 0 (terminal_rows - 8 - diagnostic_rows)

let maximum_scroll ~entry_count ~content_height =
  max 0 (entry_count - content_height)

let normalize_scroll ~entry_count ~content_height scroll =
  max 0 (min scroll (maximum_scroll ~entry_count ~content_height))

let scroll_up ~entry_count ~content_height scroll =
  max 0 (normalize_scroll ~entry_count ~content_height scroll - 1)

let scroll_down ~entry_count ~content_height scroll =
  min
    (maximum_scroll ~entry_count ~content_height)
    (normalize_scroll ~entry_count ~content_height scroll + 1)

let empty_message = function
  | None -> "(no log entries found)"
  | Some (Storage_error _) -> "(log entries unavailable)"
  | Some (Row_errors _) -> "(no valid rows in newest physical window)"
