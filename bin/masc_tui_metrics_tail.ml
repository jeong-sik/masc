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
  (* A row the file holds for someone else. It is not damage -- the metrics file
     is shared and this screen shows one keeper -- but it does consume the
     physical window, which is why it is counted at all: without it "200 rows
     read, 125 shown" has no explanation. Its own variant so the count of rows
     that could not be read stays separate from it; folded together, a single
     unreadable row hid inside seventy-five normal ones. *)
  | Other_keeper_row of {
      physical_index : int;
      actual_keeper : string;
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
  | Other_keeper_row { physical_index; actual_keeper } ->
      Printf.sprintf "physical row %d belongs to Keeper %S" physical_index
        actual_keeper

let error_to_string = function
  | Storage_error error ->
      "metrics storage read failed: " ^ Dated_jsonl.read_error_to_string error
  | Row_errors { physical_rows; errors } ->
      (* Two counts, because they ask for different things. Rows held for
         another keeper explain why a window of [physical_rows] showed fewer
         entries; rows that could not be read are damage. One number for both
         let a single unreadable row hide inside seventy-five normal ones. *)
      let others =
        List.length
          (List.filter
             (function
               | Other_keeper_row _ -> true
               | Malformed_json _ | Invalid_metrics_row _ -> false)
             errors)
      in
      let unreadable = List.length errors - others in
      let first_unreadable =
        List.find_opt
          (function
            | Malformed_json _ | Invalid_metrics_row _ -> true
            | Other_keeper_row _ -> false)
          errors
      in
      let parts =
        (if others = 0 then []
         else [ Printf.sprintf "%d for another Keeper" others ])
        @ (match first_unreadable, unreadable with
           | _, 0 -> []
           | None, _ -> [ Printf.sprintf "%d unreadable" unreadable ]
           | Some error, 1 ->
               [ Printf.sprintf "1 unreadable: %s" (row_error_to_string error) ]
           | Some error, _ ->
               [ Printf.sprintf "%d unreadable, first: %s" unreadable
                   (row_error_to_string error)
               ])
      in
      Printf.sprintf "metrics tail read %d physical %s \xc2\xb7 %s" physical_rows
        (if physical_rows = 1 then "row" else "rows")
        (match parts with
         | [] -> "all of them this Keeper's"
         | parts -> String.concat " \xc2\xb7 " parts)

(* What one physical row turned out to be. A row for another keeper is an
   outcome, not a failure: the [Error] channel is for rows that could not be
   read at all, and keeping the two apart here is what lets the notice count
   them apart. *)
type decoded_row =
  | Mine of Decode.log_entry
  | Another_keeper of string

let decode_for_keeper ~expected_keeper json : (decoded_row, string) result =
  match Decode.decode_log_entry json with
  | Error detail -> Error detail
  | Ok entry ->
      let actual_keeper =
        match json with
        | `Assoc fields ->
            (match List.assoc_opt "name" fields with
             | Some (`String name) -> Some name
             | Some _ | None -> None)
        | _ -> None
      in
      (match actual_keeper with
       | Some actual when String.equal actual expected_keeper -> Ok (Mine entry)
       | Some actual -> Ok (Another_keeper actual)
       | None -> Error "current Keeper metrics row lost its required name")

let resolve_with ~expected_keeper ~read_recent ~limit =
  match read_recent limit with
  | Error error -> { entries = []; error = Some (Storage_error error) }
  | Ok rows ->
      let indexed = List.mapi (fun index row -> index + 1, row) rows in
      let entries, errors =
        List.fold_right
          (fun (physical_index, row) (entries, errors) ->
            match row with
            | Dated_jsonl.Parsed json -> (
                match decode_for_keeper ~expected_keeper json with
                | Ok (Mine entry) -> entry :: entries, errors
                | Ok (Another_keeper actual_keeper) ->
                    ( entries,
                      Other_keeper_row { physical_index; actual_keeper }
                      :: errors )
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

let load ~store ~expected_keeper ~limit =
  resolve_with ~expected_keeper
    ~read_recent:(Dated_jsonl.read_recent_result store) ~limit

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

(* The arithmetic is the same for every scrolled list; what is particular to
   the log tail is [content_height] above, which knows this surface's chrome. *)
let maximum_scroll ~entry_count ~content_height =
  Masc_tui_scroll.maximum ~count:entry_count ~height:content_height

let normalize_scroll ~entry_count ~content_height scroll =
  Masc_tui_scroll.normalize ~count:entry_count ~height:content_height scroll

let scroll_up ~entry_count ~content_height scroll =
  Masc_tui_scroll.up ~count:entry_count ~height:content_height scroll

let scroll_down ~entry_count ~content_height scroll =
  Masc_tui_scroll.down ~count:entry_count ~height:content_height scroll

let page_up ~entry_count ~content_height scroll =
  Masc_tui_scroll.page_up ~count:entry_count ~height:content_height scroll

let page_down ~entry_count ~content_height scroll =
  Masc_tui_scroll.page_down ~count:entry_count ~height:content_height scroll

(* The stored order is chronological because the file is append-only and the
   decoder reads it that way. The reader wants the other end: opening a
   Keeper's log is nearly always about the turn that just happened, so
   [scroll = 0] shows the newest rows and scrolling walks backwards in time.

   Owning the window here rather than in the drawing has a second reason. The
   renderer indexed the list per row ([List.nth] inside the row loop), so a
   window of h rows over n entries cost n*h and every frame paid it again.
   This walks the list once. *)
let visible ~entries ~content_height ~scroll =
  let entry_count = List.length entries in
  let scroll = normalize_scroll ~entry_count ~content_height scroll in
  (* [scroll] counts rows back from the newest, so the window is the
     chronological slice [start, stop) read in reverse. *)
  let stop = entry_count - scroll in
  let start = max 0 (stop - content_height) in
  let rec take index acc = function
    | [] -> acc
    | entry :: rest ->
      if index >= stop then acc
      else if index >= start then take (index + 1) (entry :: acc) rest
      else take (index + 1) acc rest
  in
  take 0 [] entries

let empty_message = function
  | None -> "(no log entries found)"
  | Some (Storage_error _) -> "(log entries unavailable)"
  | Some (Row_errors _) -> "(no valid rows in newest physical window)"
