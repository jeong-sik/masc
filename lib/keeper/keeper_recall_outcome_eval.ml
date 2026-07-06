(** Offline, read-only join from recall-injection ledger rows to local execution
    receipt outcomes. *)

module String_map = Map.Make (String)
module String_set = Set.Make (String)

type recall_record =
  { keeper_id : string
  ; trace_id : string
  ; turn : int
  ; injected_fact_keys : string list
  ; injected_fact_key_count : int
  ; injected_episode_key_count : int
  ; failure_reason : string option
  ; ts : float option
  }

type receipt_record =
  { keeper_name : string
  ; trace_id : string
  ; outcome : string
  ; terminal_reason_code : string
  ; current_task_id : string option
  ; ended_at : string option
  ; ended_at_unix : float option
  }

type outcome_bucket =
  | Outcome_ok
  | Outcome_skipped
  | Outcome_error
  | Outcome_cancelled
  | Outcome_unknown
  | Outcome_missing_receipt

type trace_row =
  { trace_id : string
  ; keeper_id : string option
  ; recall_records : int
  ; fact_keys : string list
  ; injected_fact_keys : int
  ; recall_failure_records : int
  ; receipt : receipt_record option
  ; outcome_bucket : outcome_bucket
  }

type fact_key_summary =
  { fact_key : string
  ; injected_count : int
  ; recall_records : int
  ; recall_failure_records : int
  ; trace_count : int
  ; outcome_ok : int
  ; outcome_skipped : int
  ; outcome_error : int
  ; outcome_cancelled : int
  ; outcome_unknown : int
  ; outcome_missing_receipt : int
  }

type t =
  { masc_root : string
  ; recall_dir : string
  ; receipts_dir : string
  ; read_error_count : int
  ; malformed_jsonl_rows : int
  ; invalid_recall_rows : int
  ; invalid_receipt_rows : int
  ; load_errors : string list
  ; recall_records : int
  ; recall_traces : int
  ; traces_with_receipt : int
  ; traces_without_receipt : int
  ; injected_fact_keys : int
  ; recall_failure_records : int
  ; outcome_ok : int
  ; outcome_skipped : int
  ; outcome_error : int
  ; outcome_cancelled : int
  ; outcome_unknown : int
  ; fact_key_summaries : fact_key_summary list
  ; traces : trace_row list
  }

type load_stats =
  { read_error_count : int
  ; malformed_jsonl_rows : int
  ; invalid_rows : int
  ; errors : string list
  }

let empty_load_stats =
  { read_error_count = 0; malformed_jsonl_rows = 0; invalid_rows = 0; errors = [] }
;;

let merge_load_stats a b =
  { read_error_count = a.read_error_count + b.read_error_count
  ; malformed_jsonl_rows = a.malformed_jsonl_rows + b.malformed_jsonl_rows
  ; invalid_rows = a.invalid_rows + b.invalid_rows
  ; errors = a.errors @ b.errors
  }
;;

let jsonl_suffix = ".jsonl"

type directory_status =
  | Directory
  | Not_directory
  | Missing
  | Directory_access_error of string

let directory_status path =
  try
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR -> Directory
    | _ -> Not_directory
  with
  | Unix.Unix_error (Unix.ENOENT, _, _)
  | Unix.Unix_error (Unix.ENOTDIR, _, _) -> Missing
  | Unix.Unix_error (err, _, _) -> Directory_access_error (Unix.error_message err)
;;

let load_stats_error ~operation path message =
  { empty_load_stats with
    read_error_count = 1
  ; errors = [ Printf.sprintf "%s: %s failed: %s" path operation message ]
  }
;;

let sorted_readdir path =
  try Ok (Sys.readdir path |> Array.to_list |> List.sort String.compare) with
  | Sys_error msg -> Error msg
;;

let rec find_jsonl dir =
  match directory_status dir with
  | Missing | Not_directory -> [], empty_load_stats
  | Directory_access_error message -> [], load_stats_error ~operation:"lstat" dir message
  | Directory ->
    (match sorted_readdir dir with
     | Error message -> [], load_stats_error ~operation:"readdir" dir message
     | Ok names ->
       List.fold_left
         (fun (files, stats) name ->
            let path = Filename.concat dir name in
            match directory_status path with
            | Directory ->
              let child_files, child_stats = find_jsonl path in
              files @ child_files, merge_load_stats stats child_stats
            | Not_directory ->
              if Filename.check_suffix path jsonl_suffix
              then files @ [ path ], stats
              else files, stats
            | Missing -> files, stats
            | Directory_access_error message ->
              files, merge_load_stats stats (load_stats_error ~operation:"lstat" path message))
         ([], empty_load_stats)
         names)
;;

let find_receipt_jsonl keepers_dir =
  match directory_status keepers_dir with
  | Missing | Not_directory -> [], empty_load_stats
  | Directory_access_error message ->
    [], load_stats_error ~operation:"lstat" keepers_dir message
  | Directory ->
    (match sorted_readdir keepers_dir with
     | Error message -> [], load_stats_error ~operation:"readdir" keepers_dir message
     | Ok names ->
       List.fold_left
         (fun (files, stats) keeper_name ->
            let keeper_dir = Filename.concat keepers_dir keeper_name in
            match directory_status keeper_dir with
            | Directory ->
              let receipt_files, receipt_stats =
                find_jsonl
                  (Filename.concat
                     keeper_dir
                     Keeper_types_support.execution_receipts_dirname)
              in
              files @ receipt_files, merge_load_stats stats receipt_stats
            | Not_directory | Missing -> files, stats
            | Directory_access_error message ->
              files, merge_load_stats stats (load_stats_error ~operation:"lstat" keeper_dir message))
         ([], empty_load_stats)
         names)
;;

let read_lines path =
  try
    let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
         let rec loop acc =
           match input_line ic with
           | line -> loop (line :: acc)
           | exception End_of_file -> List.rev acc
         in
         Ok (loop []))
  with
  | Sys_error msg ->
    Error (Printf.sprintf "%s: %s" path msg)
;;

let parse_json_line ~path ~line_no line =
  match Yojson.Safe.from_string line with
  | json -> Ok json
  | exception Yojson.Json_error msg ->
    Error (Printf.sprintf "%s:%d: malformed JSONL row: %s" path line_no msg)
;;

let ( let* ) = Result.bind

let field_type_error field expected actual =
  Printf.sprintf
    "%s expected %s, got %s"
    field
    expected
    (Json_util.kind_name actual)
;;

let required_string_field json field =
  match Json_util.assoc_member_opt field json with
  | Some (`String value) when String.trim value <> "" -> Ok value
  | Some (`String _) -> Error (Printf.sprintf "%s expected non-empty string" field)
  | Some actual -> Error (field_type_error field "non-empty string" actual)
  | None -> Error (Printf.sprintf "%s is missing" field)
;;

let optional_string_field json field =
  match Json_util.assoc_member_opt field json with
  | None | Some `Null -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some actual -> Error (field_type_error field "string" actual)
;;

let optional_int_field json field =
  match Json_util.assoc_member_opt field json with
  | None | Some `Null -> Ok None
  | Some (`Int value) -> Ok (Some value)
  | Some (`Intlit raw) ->
    (match int_of_string_opt raw with
     | Some value -> Ok (Some value)
     | None -> Error (Printf.sprintf "%s expected int, got intlit:%s" field raw))
  | Some actual -> Error (field_type_error field "int" actual)
;;

let optional_float_field json field =
  match Json_util.assoc_member_opt field json with
  | None | Some `Null -> Ok None
  | Some (`Float value) -> Ok (Some value)
  | Some (`Int value) -> Ok (Some (Float.of_int value))
  | Some actual -> Error (field_type_error field "float" actual)
;;

let parse_recall_json = function
  | `Assoc _ as json ->
    let* ledger_record =
      match Keeper_recall_injection_ledger.record_of_json_result json with
      | Ok record -> Ok record
      | Error error ->
        Error
          (Printf.sprintf
             "recall ledger schema %s"
             (Keeper_recall_injection_ledger.decode_error_to_string error))
    in
    let* injected_fact_key_count =
      optional_int_field json "injected_fact_key_count"
    in
    let* injected_episode_key_count =
      optional_int_field json "injected_episode_key_count"
    in
    let* ts = optional_float_field json "ts" in
    Ok
      { keeper_id = ledger_record.keeper_id
      ; trace_id = ledger_record.trace_id
      ; turn = ledger_record.turn
      ; injected_fact_keys = ledger_record.injected_fact_keys
      ; injected_fact_key_count =
          Option.value
            injected_fact_key_count
            ~default:(List.length ledger_record.injected_fact_keys)
      ; injected_episode_key_count =
          Option.value
            injected_episode_key_count
            ~default:(List.length ledger_record.injected_episode_keys)
      ; failure_reason = ledger_record.failure_reason
      ; ts
      }
  | actual -> Error (field_type_error "recall_row" "object" actual)
;;

let parse_ended_at json =
  let* ended_at = optional_string_field json "ended_at" in
  match ended_at with
  | None -> Ok (None, None)
  | Some raw when String.trim raw = "" -> Ok (Some raw, None)
  | Some raw ->
    (match Masc_domain.parse_iso8601_opt raw with
     | Some ts -> Ok (Some raw, Some ts)
     | None -> Error "ended_at expected ISO-8601 timestamp")
;;

let parse_receipt_json = function
  | `Assoc _ as json ->
    let* schema = required_string_field json "schema" in
    if not (String.equal schema Keeper_types_support.execution_receipt_schema)
    then Error (Printf.sprintf "schema expected %s" Keeper_types_support.execution_receipt_schema)
    else (
      let* keeper_name = required_string_field json "keeper_name" in
      let* trace_id = required_string_field json "trace_id" in
      let* outcome = required_string_field json "outcome" in
      let* terminal_reason_code =
        required_string_field json "terminal_reason_code"
      in
      let* ended_at, ended_at_unix = parse_ended_at json in
      let* current_task_id = optional_string_field json "current_task_id" in
      Ok
        { keeper_name
        ; trace_id
        ; outcome
        ; terminal_reason_code
        ; current_task_id
        ; ended_at
        ; ended_at_unix
        })
  | actual -> Error (field_type_error "receipt_row" "object" actual)
;;

let load_records_from_files files parse =
  let load_line path line_no (records, stats) line =
    match parse_json_line ~path ~line_no line with
    | Error error ->
      ( records
      , { stats with
          malformed_jsonl_rows = stats.malformed_jsonl_rows + 1
        ; errors = stats.errors @ [ error ]
        } )
    | Ok json ->
      (match parse json with
       | Ok record -> record :: records, stats
       | Error error ->
         ( records
         , { stats with
             invalid_rows = stats.invalid_rows + 1
           ; errors =
               stats.errors
               @ [ Printf.sprintf
                     "%s:%d: invalid row schema: %s"
                     path
                     line_no
                     error
                 ]
           } ))
  in
  let load_file (records, stats) path =
    match read_lines path with
    | Error error ->
      ( records
      , { stats with
          read_error_count = stats.read_error_count + 1
        ; errors = stats.errors @ [ error ]
        } )
    | Ok lines ->
      let records, line_stats =
        lines
        |> List.mapi (fun idx line -> idx + 1, line)
        |> List.fold_left
             (fun acc (line_no, line) -> load_line path line_no acc line)
             (records, empty_load_stats)
      in
      records, merge_load_stats stats line_stats
  in
  let records, stats =
    files |> List.fold_left load_file ([], empty_load_stats)
  in
  List.rev records, stats
;;

let load_records dir parse =
  let files, scan_stats = find_jsonl dir in
  let records, load_stats = load_records_from_files files parse in
  records, merge_load_stats scan_stats load_stats
;;

let newer_receipt candidate existing =
  match candidate.ended_at_unix, existing.ended_at_unix with
  | Some a, Some b -> Float.compare a b > 0
  | Some _, None -> true
  | None, Some _ -> false
  | None, None -> String.compare candidate.keeper_name existing.keeper_name < 0
;;

let receipt_map (receipts : receipt_record list) : receipt_record String_map.t =
  List.fold_left
    (fun (acc : receipt_record String_map.t) (receipt : receipt_record) ->
       match String_map.find_opt receipt.trace_id acc with
       | None -> String_map.add receipt.trace_id receipt acc
       | Some existing when newer_receipt receipt existing ->
         String_map.add receipt.trace_id receipt acc
       | Some _ -> acc)
    String_map.empty
    receipts
;;

let recall_groups (records : recall_record list) : recall_record list String_map.t =
  List.fold_left
    (fun acc (record : recall_record) ->
       let existing =
         match String_map.find_opt record.trace_id acc with
         | Some records -> records
         | None -> []
       in
       String_map.add record.trace_id (record :: existing) acc)
    String_map.empty
    records
;;

let outcome_bucket_of_receipt = function
  | None -> Outcome_missing_receipt
  | Some receipt ->
    (match Keeper_execution_receipt.outcome_kind_of_string receipt.outcome with
     | Some `Ok -> Outcome_ok
     | Some `Skipped -> Outcome_skipped
     | Some `Error -> Outcome_error
     | Some `Cancelled -> Outcome_cancelled
     | None -> Outcome_unknown)
;;

let outcome_bucket_to_string = function
  | Outcome_ok -> "ok"
  | Outcome_skipped -> "skipped"
  | Outcome_error -> "error"
  | Outcome_cancelled -> "cancelled"
  | Outcome_unknown -> "unknown"
  | Outcome_missing_receipt -> "missing_receipt"
;;

let unique_sorted xs =
  xs
  |> List.fold_left
       (fun acc x -> if String.trim x = "" then acc else String_set.add x acc)
       String_set.empty
  |> String_set.elements
;;

let trace_row_of_group
      (receipts : receipt_record String_map.t)
      trace_id
      (records : recall_record list)
  =
  let compare_record (a : recall_record) (b : recall_record) =
    match a.ts, b.ts with
    | Some a_ts, Some b_ts ->
      let by_ts = Float.compare a_ts b_ts in
      if by_ts <> 0 then by_ts else Int.compare a.turn b.turn
    | Some _, None -> 1
    | None, Some _ -> -1
    | None, None ->
      let by_turn = Int.compare a.turn b.turn in
      if by_turn <> 0 then by_turn else String.compare a.keeper_id b.keeper_id
  in
  let records = List.sort compare_record records in
  let latest_record =
    match records with
    | [] -> None
    | first :: rest ->
      Some
        (List.fold_left
           (fun latest record ->
              if compare_record latest record <= 0 then record else latest)
           first
           rest)
  in
  let receipt = String_map.find_opt trace_id receipts in
  let outcome_bucket = outcome_bucket_of_receipt receipt in
  let fact_keys =
    records
    |> List.concat_map (fun (r : recall_record) -> r.injected_fact_keys)
    |> unique_sorted
  in
  { trace_id
  ; keeper_id =
      (match latest_record with
       | Some record -> Some record.keeper_id
       | None -> None)
  ; recall_records = List.length records
  ; fact_keys
  ; injected_fact_keys =
      List.fold_left (fun acc r -> acc + r.injected_fact_key_count) 0 records
  ; recall_failure_records =
      List.fold_left
        (fun acc r -> if Option.is_some r.failure_reason then acc + 1 else acc)
        0
        records
  ; receipt
  ; outcome_bucket
  }
;;

let empty_fact_key_summary fact_key =
  { fact_key
  ; injected_count = 0
  ; recall_records = 0
  ; recall_failure_records = 0
  ; trace_count = 0
  ; outcome_ok = 0
  ; outcome_skipped = 0
  ; outcome_error = 0
  ; outcome_cancelled = 0
  ; outcome_unknown = 0
  ; outcome_missing_receipt = 0
  }
;;

let update_fact_key_summary fact_key f acc =
  let current =
    Option.value
      (String_map.find_opt fact_key acc)
      ~default:(empty_fact_key_summary fact_key)
  in
  String_map.add fact_key (f current) acc
;;

let key_counts keys =
  List.fold_left
    (fun acc key ->
       let current =
         match String_map.find_opt key acc with
         | Some count -> count
         | None -> 0
       in
       String_map.add key (current + 1) acc)
    String_map.empty
    keys
;;

let add_record_to_fact_summaries acc (record : recall_record) =
  let counts = key_counts record.injected_fact_keys in
  String_map.fold
    (fun fact_key count acc ->
       update_fact_key_summary
         fact_key
         (fun row ->
            { row with
              injected_count = row.injected_count + count
            ; recall_records = row.recall_records + 1
            ; recall_failure_records =
                row.recall_failure_records
                + if Option.is_some record.failure_reason then 1 else 0
            })
         acc)
    counts
    acc
;;

let add_outcome_to_fact_summary bucket (row : fact_key_summary) =
  match bucket with
  | Outcome_ok -> { row with outcome_ok = row.outcome_ok + 1 }
  | Outcome_skipped -> { row with outcome_skipped = row.outcome_skipped + 1 }
  | Outcome_error -> { row with outcome_error = row.outcome_error + 1 }
  | Outcome_cancelled -> { row with outcome_cancelled = row.outcome_cancelled + 1 }
  | Outcome_unknown -> { row with outcome_unknown = row.outcome_unknown + 1 }
  | Outcome_missing_receipt ->
    { row with outcome_missing_receipt = row.outcome_missing_receipt + 1 }
;;

let add_trace_to_fact_summaries acc row =
  List.fold_left
    (fun acc fact_key ->
       update_fact_key_summary
         fact_key
         (fun summary ->
            summary
            |> add_outcome_to_fact_summary row.outcome_bucket
            |> fun summary -> { summary with trace_count = summary.trace_count + 1 })
         acc)
    acc
    row.fact_keys
;;

let compare_fact_key_summary a b =
  let by_trace = compare b.trace_count a.trace_count in
  if by_trace <> 0
  then by_trace
  else (
    let by_injected = compare b.injected_count a.injected_count in
    if by_injected <> 0 then by_injected else String.compare a.fact_key b.fact_key)
;;

let fact_key_summaries recall_records traces =
  let from_records =
    List.fold_left add_record_to_fact_summaries String_map.empty recall_records
  in
  List.fold_left add_trace_to_fact_summaries from_records traces
  |> String_map.bindings
  |> List.map snd
  |> List.sort compare_fact_key_summary
;;

let evaluate ~masc_root =
  let recall_dir = Keeper_recall_injection_ledger.base_dir ~masc_root in
  let receipts_dir = Filename.concat masc_root Common.keepers_runtime_dirname in
  let recall_records, recall_stats = load_records recall_dir parse_recall_json in
  let receipts, receipt_stats =
    let files, scan_stats = find_receipt_jsonl receipts_dir in
    let records, load_stats = load_records_from_files files parse_receipt_json in
    records, merge_load_stats scan_stats load_stats
  in
  let receipts_by_trace = receipt_map receipts in
  let traces =
    recall_groups recall_records
    |> String_map.bindings
    |> List.map (fun (trace_id, records) ->
      trace_row_of_group receipts_by_trace trace_id records)
    |> List.sort (fun a b -> String.compare a.trace_id b.trace_id)
  in
  let count_bucket bucket =
    List.fold_left
      (fun acc (row : trace_row) ->
         if row.outcome_bucket = bucket then acc + 1 else acc)
      0
      traces
  in
  let fact_key_summaries = fact_key_summaries recall_records traces in
  { masc_root
  ; recall_dir
  ; receipts_dir
  ; read_error_count = recall_stats.read_error_count + receipt_stats.read_error_count
  ; malformed_jsonl_rows =
      recall_stats.malformed_jsonl_rows + receipt_stats.malformed_jsonl_rows
  ; invalid_recall_rows = recall_stats.invalid_rows
  ; invalid_receipt_rows = receipt_stats.invalid_rows
  ; load_errors = recall_stats.errors @ receipt_stats.errors
  ; recall_records = List.length recall_records
  ; recall_traces = List.length traces
  ; traces_with_receipt =
      List.fold_left
        (fun acc (row : trace_row) ->
           if Option.is_some row.receipt then acc + 1 else acc)
        0
        traces
  ; traces_without_receipt = count_bucket Outcome_missing_receipt
  ; injected_fact_keys =
      List.fold_left
        (fun acc (row : trace_row) -> acc + row.injected_fact_keys)
        0
        traces
  ; recall_failure_records =
      List.fold_left
        (fun acc (row : trace_row) -> acc + row.recall_failure_records)
        0
        traces
  ; outcome_ok = count_bucket Outcome_ok
  ; outcome_skipped = count_bucket Outcome_skipped
  ; outcome_error = count_bucket Outcome_error
  ; outcome_cancelled = count_bucket Outcome_cancelled
  ; outcome_unknown = count_bucket Outcome_unknown
  ; fact_key_summaries
  ; traces
  }
;;

let string_opt_to_json = function
  | Some s -> `String s
  | None -> `Null
;;

let receipt_to_json receipt =
  `Assoc
    [ "keeper_name", `String receipt.keeper_name
    ; "trace_id", `String receipt.trace_id
    ; "outcome", `String receipt.outcome
    ; "terminal_reason_code", `String receipt.terminal_reason_code
    ; "current_task_id", string_opt_to_json receipt.current_task_id
    ; "ended_at", string_opt_to_json receipt.ended_at
    ; "ended_at_unix", (match receipt.ended_at_unix with Some ts -> `Float ts | None -> `Null)
    ]
;;

let trace_row_to_json row =
  `Assoc
    [ "trace_id", `String row.trace_id
    ; "keeper_id", string_opt_to_json row.keeper_id
    ; "recall_records", `Int row.recall_records
    ; "fact_keys", `List (List.map (fun key -> `String key) row.fact_keys)
    ; "injected_fact_keys", `Int row.injected_fact_keys
    ; "recall_failure_records", `Int row.recall_failure_records
    ; "outcome_bucket", `String (outcome_bucket_to_string row.outcome_bucket)
    ; ( "receipt"
      , match row.receipt with
        | Some receipt -> receipt_to_json receipt
        | None -> `Null )
    ]
;;

let fact_key_summary_to_json row =
  `Assoc
    [ "fact_key", `String row.fact_key
    ; "injected_count", `Int row.injected_count
    ; "recall_records", `Int row.recall_records
    ; "recall_failure_records", `Int row.recall_failure_records
    ; "trace_count", `Int row.trace_count
    ; ( "outcomes"
      , `Assoc
          [ "ok", `Int row.outcome_ok
          ; "skipped", `Int row.outcome_skipped
          ; "error", `Int row.outcome_error
          ; "cancelled", `Int row.outcome_cancelled
          ; "unknown", `Int row.outcome_unknown
          ; "missing_receipt", `Int row.outcome_missing_receipt
          ] )
    ]
;;

let take n xs = if n <= 0 then [] else List.take n xs

let to_json ?(trace_limit = 50) ?(fact_key_limit = 50) report =
  `Assoc
    [ "masc_root", `String report.masc_root
    ; "recall_dir", `String report.recall_dir
    ; "receipts_dir", `String report.receipts_dir
    ; ( "load_diagnostics"
      , `Assoc
          [ "read_error_count", `Int report.read_error_count
          ; "malformed_jsonl_rows", `Int report.malformed_jsonl_rows
          ; "invalid_recall_rows", `Int report.invalid_recall_rows
          ; "invalid_receipt_rows", `Int report.invalid_receipt_rows
          ; "errors", `List (List.map (fun error -> `String error) report.load_errors)
          ] )
    ; "recall_records", `Int report.recall_records
    ; "recall_traces", `Int report.recall_traces
    ; "traces_with_receipt", `Int report.traces_with_receipt
    ; "traces_without_receipt", `Int report.traces_without_receipt
    ; "injected_fact_keys", `Int report.injected_fact_keys
    ; "recall_failure_records", `Int report.recall_failure_records
    ; ( "outcomes"
      , `Assoc
          [ "ok", `Int report.outcome_ok
          ; "skipped", `Int report.outcome_skipped
          ; "error", `Int report.outcome_error
          ; "cancelled", `Int report.outcome_cancelled
          ; "unknown", `Int report.outcome_unknown
          ; "missing_receipt", `Int report.traces_without_receipt
          ] )
    ; ( "fact_key_summary_index"
      , `Assoc
          [ "indexed_by", `List [ `String "fact_key"; `String "trace_outcome" ]
          ; "total_fact_keys", `Int (List.length report.fact_key_summaries)
          ; "fact_key_limit", `Int fact_key_limit
          ; ( "rows"
            , `List
                (List.map
                   fact_key_summary_to_json
                   (take fact_key_limit report.fact_key_summaries)) )
          ] )
    ; "trace_limit", `Int trace_limit
    ; "traces", `List (List.map trace_row_to_json (take trace_limit report.traces))
    ]
;;

let render_trace row =
  let task =
    match row.receipt with
    | Some { current_task_id = Some task; _ } -> task
    | Some _ | None -> "-"
  in
  let terminal =
    match row.receipt with
    | Some receipt -> receipt.terminal_reason_code
    | None -> "-"
  in
  Printf.sprintf
    "%s\t%s\trecall=%d\tfacts=%d\tfailures=%d\ttask=%s\tterminal=%s\n"
    row.trace_id
    (outcome_bucket_to_string row.outcome_bucket)
    row.recall_records
    row.injected_fact_keys
    row.recall_failure_records
    task
    terminal
;;

let render_fact_key_summary row =
  Printf.sprintf
    "%s\ttraces=%d\tinjections=%d\tfailures=%d\tok=%d\tskipped=%d\terror=%d\tcancelled=%d\tunknown=%d\tmissing=%d\n"
    row.fact_key
    row.trace_count
    row.injected_count
    row.recall_failure_records
    row.outcome_ok
    row.outcome_skipped
    row.outcome_error
    row.outcome_cancelled
    row.outcome_unknown
    row.outcome_missing_receipt
;;

let render_text ?(trace_limit = 50) ?(fact_key_limit = 50) report =
  let traces = take trace_limit report.traces in
  let trace_lines =
    match traces with
    | [] -> "no recall traces found\n"
    | rows -> rows |> List.map render_trace |> String.concat ""
  in
  let fact_key_rows = take fact_key_limit report.fact_key_summaries in
  let fact_key_lines =
    match fact_key_rows with
    | [] -> "no injected fact keys found\n"
    | rows -> rows |> List.map render_fact_key_summary |> String.concat ""
  in
  Printf.sprintf
    "Memory OS recall outcome eval (local receipts only)\n\
     masc_root: %s\n\
     load_diagnostics: read_errors=%d malformed_jsonl_rows=%d invalid_recall_rows=%d invalid_receipt_rows=%d\n\
     recall_records: %d, recall_traces: %d\n\
     joined: with_receipt=%d without_receipt=%d\n\
     injected_fact_keys=%d recall_failure_records=%d\n\
     outcomes: ok=%d skipped=%d error=%d cancelled=%d unknown=%d missing_receipt=%d\n\
     fact_key_summary_index: total_fact_keys=%d fact_key_limit=%d\n\
     %s\
     trace_limit=%d\n\
     %s"
    report.masc_root
    report.read_error_count
    report.malformed_jsonl_rows
    report.invalid_recall_rows
    report.invalid_receipt_rows
    report.recall_records
    report.recall_traces
    report.traces_with_receipt
    report.traces_without_receipt
    report.injected_fact_keys
    report.recall_failure_records
    report.outcome_ok
    report.outcome_skipped
    report.outcome_error
    report.outcome_cancelled
    report.outcome_unknown
    report.traces_without_receipt
    (List.length report.fact_key_summaries)
    fact_key_limit
    fact_key_lines
    trace_limit
    trace_lines
;;

let write_summary_index ~path report =
  Fs_compat.mkdir_p (Filename.dirname path);
  let oc = open_out_bin path in
  let closed = ref false in
  let close_propagating () =
    try
      close_out oc;
      closed := true
    with exn ->
      close_out_noerr oc;
      closed := true;
      raise exn
  in
  Fun.protect
    ~finally:(fun () -> if not !closed then close_out_noerr oc)
    (fun () ->
       List.iter
         (fun row ->
            output_string oc (Yojson.Safe.to_string (fact_key_summary_to_json row));
            output_char oc '\n')
         report.fact_key_summaries;
       close_propagating ())
;;
