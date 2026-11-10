open Model_inference_metrics_entry
open Model_inference_metrics_reader

module String_map = Map.Make (String)

(* The rows of one file that still count, newest first, and how many rows of
   the file did not parse as JSON. A malformed row counts wherever its file is
   read, as the one-pass reader counts it. *)
type rows =
  { readings : row_reading list
  ; malformed_rows : int
  }

let no_rows = { readings = []; malformed_rows = 0 }

type decision_file =
  { cursor : Dated_jsonl.append_cursor
  ; rows : rows
  }

type t =
  { decisions : decision_file String_map.t
  ; costs : rows Dated_jsonl_kept_days.t
  }

let empty = { decisions = String_map.empty; costs = Dated_jsonl_kept_days.empty }

let take_row ~classify ~since_unix ~source rows = function
  | Dated_jsonl.Malformed_json { path; line_number; detail } ->
    Log.Model_inference_metrics.warn "%s malformed row: %s%s detail=%s" source path
      (match line_number with
       | Some line -> ":" ^ string_of_int line
       | None -> "")
      detail;
    { rows with malformed_rows = rows.malformed_rows + 1 }
  | Dated_jsonl.Parsed json ->
    (match classify ~since_unix json with
     | Row_ignored -> rows
     | Row_schema_violation { error; _ } as reading ->
       Log.Model_inference_metrics.warn "%s schema drop: reason=%s detail=%s" source
         (parse_error_label error) (parse_error_detail error);
       { rows with readings = reading :: rows.readings }
     | Row_entry _ as reading -> { rows with readings = reading :: rows.readings })

let prune ~since_unix rows =
  { rows with readings = List.filter (row_in_window ~since_unix) rows.readings }

(* [Cursor_invalidated] answers only a cursor that was passed, so the read
   from the start cannot be invalidated again. *)
let refresh_decision_file ~since_unix path previous =
  let f = take_row ~classify:decision_row_reading ~since_unix ~source:"decisions.jsonl" in
  let read cursor rows = Dated_jsonl.fold_file_appended_entries_result path ~cursor ~init:rows ~f in
  let from_start () =
    match read None no_rows with
    | Error _ as error -> error
    | Ok (Dated_jsonl.Appended (rows, cursor)) -> Ok { cursor; rows }
    | Ok Dated_jsonl.Cursor_invalidated ->
      Error
        (Dated_jsonl.Io_error
           { operation = Dated_jsonl.Read_file
           ; path
           ; detail = "a read from the start was refused as a moved cursor"
           })
  in
  match previous with
  | None -> from_start ()
  | Some file ->
    (match read (Some file.cursor) file.rows with
     | Error _ as error -> error
     | Ok (Dated_jsonl.Appended (rows, cursor)) -> Ok { cursor; rows }
     | Ok Dated_jsonl.Cursor_invalidated -> from_start ())

(* A file that does not read this time keeps what it said before; the reading
   counts it unreadable. A file no longer listed is dropped. *)
let refresh_decisions ~base_path ~since_unix kept =
  match decision_log_paths ~base_path with
  | Error () -> kept, Error Decision_directory_unavailable
  | Ok paths ->
    let decisions, unreadable =
      List.fold_left
        (fun (decisions, unreadable) path ->
          let previous = String_map.find_opt path kept in
          match refresh_decision_file ~since_unix path previous with
          | Ok file ->
            String_map.add path { file with rows = prune ~since_unix file.rows } decisions, unreadable
          | Error error ->
            Log.Model_inference_metrics.error "decisions.jsonl read failed: path=%s detail=%s" path
              (Dated_jsonl.read_error_to_string error);
            ( (match previous with
               | Some file -> String_map.add path file decisions
               | None -> decisions)
            , unreadable + 1 ))
        (String_map.empty, 0)
        paths
    in
    decisions, if unreadable > 0 then Error (Decision_files_unreadable unreadable) else Ok ()

let counted ~since_unix rows =
  let readings = List.filter (row_in_window ~since_unix) rows.readings in
  let entries =
    List.filter_map
      (function
        | Row_entry entry -> Some entry
        | Row_schema_violation _ | Row_ignored -> None)
      readings
  in
  let violations =
    List.length
      (List.filter
         (function
           | Row_schema_violation _ -> true
           | Row_entry _ | Row_ignored -> false)
         readings)
  in
  entries, violations, rows.malformed_rows

let sum_counted ~since_unix all =
  List.fold_left
    (fun (entries, violations, malformed) rows ->
      let e, v, m = counted ~since_unix rows in
      List.rev_append e entries, violations + v, malformed + m)
    ([], 0, 0)
    all

type reading =
  { entries : raw_entry list
  ; cost_read : cost_read_result
  ; decision_read : (unit, decision_read_error) result
  }

let refresh ~base_path ~now ~window_minutes kept =
  let since_unix = now -. (Float.of_int window_minutes *. 60.0) in
  let decisions, files_read = refresh_decisions ~base_path ~since_unix kept.decisions in
  let decision_entries, decision_violations, decision_malformed =
    sum_counted ~since_unix (String_map.fold (fun _ file acc -> file.rows :: acc) decisions [])
  in
  let decision_read =
    match files_read with
    | Error _ as error -> error
    | Ok () when decision_malformed > 0 || decision_violations > 0 ->
      Error
        (Decision_rows_invalid
           { malformed_rows = decision_malformed; schema_violation_rows = decision_violations })
    | Ok () -> Ok ()
  in
  let costs_read =
    Dated_jsonl_kept_days.refresh
      (Cost_ledger.store_of_base_path ~base_path)
      ~days:(Dated_jsonl_kept_days.days_between ~since:since_unix ~until:now)
      ~init:no_rows
      ~f:(take_row ~classify:cost_row_reading ~since_unix ~source:"cost ledger")
      kept.costs
  in
  match costs_read with
  | Ok costs ->
    let cost_entries, cost_violations, cost_malformed =
      sum_counted ~since_unix (Dated_jsonl_kept_days.fold costs ~init:[] ~f:(fun acc _ rows -> rows :: acc))
    in
    let entries, identity_conflict_rows =
      merge_decision_and_cost_entries decision_entries cost_entries
    in
    if identity_conflict_rows > 0
    then
      Log.Model_inference_metrics.warn "cost ledger exact identity conflict: rows=%d action=excluded"
        identity_conflict_rows;
    ( { decisions; costs }
    , { entries
      ; cost_read =
          Ok
            { malformed_rows = cost_malformed
            ; schema_violation_rows = cost_violations
            ; identity_conflict_rows
            }
      ; decision_read
      } )
  | Error error ->
    Log.Model_inference_metrics.error "costs/dated read failed: %s"
      (Dated_jsonl.read_error_to_string error);
    ( { decisions; costs = kept.costs }
    , { entries = decision_entries; cost_read = Error error; decision_read } )

let next_change kept ~window_minutes ~after =
  let window_s = Float.of_int window_minutes *. 60.0 in
  let since_unix = after -. window_s in
  let leaves = function
    | Row_entry (entry : raw_entry) -> Some (Float.succ (entry.ts_unix +. window_s))
    | Row_schema_violation { ts_unix = Some ts; _ } -> Some (Float.succ (ts +. window_s))
    | Row_schema_violation { ts_unix = None; _ } | Row_ignored -> None
  in
  let row_instants rows = List.filter_map leaves rows.readings in
  (* A day file leaves the date range once the window's start passes its
     day, and its malformed rows and timeless violations stop counting. *)
  let instants =
    String_map.fold (fun _ file acc -> row_instants file.rows @ acc) kept.decisions []
    @ Dated_jsonl_kept_days.fold kept.costs ~init:[] ~f:(fun acc (day : Dated_jsonl_kept_days.day) rows ->
      let row_deadlines = row_instants rows @ acc in
      if rows.malformed_rows > 0 || List.exists (row_in_window ~since_unix) rows.readings then
        (day.starts_at +. Dated_jsonl_kept_days.seconds_per_day +. window_s) :: row_deadlines
      else row_deadlines)
  in
  List.fold_left
    (fun earliest instant ->
      if instant <= after
      then earliest
      else
        match earliest with
        | Some at when at <= instant -> earliest
        | Some _ | None -> Some instant)
    None
    instants
