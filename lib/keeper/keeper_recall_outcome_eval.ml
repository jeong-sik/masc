(** Offline, read-only join from recall-injection ledger rows to local execution
    receipt outcomes. *)

module String_map = Map.Make (String)

type recall_record =
  { keeper_id : string
  ; trace_id : string
  ; turn : int
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
  ; injected_fact_keys : int
  ; recall_failure_records : int
  ; receipt : receipt_record option
  ; outcome_bucket : outcome_bucket
  }

type t =
  { masc_root : string
  ; recall_dir : string
  ; receipts_dir : string
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
  ; traces : trace_row list
  }

let is_dir path = try Sys.is_directory path with Sys_error _ -> false

let rec find_jsonl dir =
  if Sys.file_exists dir && is_dir dir
  then
    Sys.readdir dir
    |> Array.to_list
    |> List.sort String.compare
    |> List.concat_map (fun name ->
      let path = Filename.concat dir name in
      if is_dir path
      then find_jsonl path
      else if Filename.check_suffix path ".jsonl"
      then [ path ]
      else [])
  else []
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
         loop [])
  with
  | Sys_error _ -> []
;;

let assoc_string fields key =
  match List.assoc_opt key fields with
  | Some (`String s) when String.trim s <> "" -> Some s
  | _ -> None
;;

let assoc_int fields key =
  match List.assoc_opt key fields with
  | Some (`Int i) -> Some i
  | Some (`Float f) -> Some (int_of_float f)
  | _ -> None
;;

let assoc_float fields key =
  match List.assoc_opt key fields with
  | Some (`Float f) -> Some f
  | Some (`Int i) -> Some (float_of_int i)
  | _ -> None
;;

let assoc_string_list fields key =
  match List.assoc_opt key fields with
  | Some (`List items) ->
    List.filter_map (function
      | `String s -> Some s
      | _ -> None)
      items
  | _ -> []
;;

let parse_json_line line =
  match Yojson.Safe.from_string line with
  | json -> Some json
  | exception Yojson.Json_error _ -> None
;;

let parse_recall_json = function
  | `Assoc fields ->
    (match assoc_string fields "keeper_id", assoc_string fields "trace_id" with
     | Some keeper_id, Some trace_id ->
       Some
         { keeper_id
         ; trace_id
         ; turn = Option.value (assoc_int fields "turn") ~default:0
         ; injected_fact_key_count =
             List.length (assoc_string_list fields "injected_fact_keys")
         ; injected_episode_key_count =
             List.length (assoc_string_list fields "injected_episode_keys")
         ; failure_reason = assoc_string fields "failure_reason"
         ; ts = assoc_float fields "ts"
         }
     | _ -> None)
  | _ -> None
;;

let parse_receipt_json = function
  | `Assoc fields ->
    (match assoc_string fields "trace_id" with
     | Some trace_id ->
       Some
         { keeper_name = Option.value (assoc_string fields "keeper_name") ~default:""
         ; trace_id
         ; outcome = Option.value (assoc_string fields "outcome") ~default:""
         ; terminal_reason_code =
             Option.value (assoc_string fields "terminal_reason_code") ~default:""
         ; current_task_id = assoc_string fields "current_task_id"
         ; ended_at = assoc_string fields "ended_at"
         }
     | None -> None)
  | _ -> None
;;

let load_records dir parse =
  find_jsonl dir
  |> List.concat_map read_lines
  |> List.filter_map parse_json_line
  |> List.filter_map parse
;;

let newer_receipt candidate existing =
  match candidate.ended_at, existing.ended_at with
  | Some a, Some b -> String.compare a b > 0
  | Some _, None -> true
  | None, Some _ -> false
  | None, None -> String.compare candidate.keeper_name existing.keeper_name < 0
;;

let receipt_map receipts =
  List.fold_left
    (fun acc receipt ->
       match String_map.find_opt receipt.trace_id acc with
       | None -> String_map.add receipt.trace_id receipt acc
       | Some existing when newer_receipt receipt existing ->
         String_map.add receipt.trace_id receipt acc
       | Some _ -> acc)
    String_map.empty
    receipts
;;

let recall_groups records =
  List.fold_left
    (fun acc record ->
       let existing = Option.value (String_map.find_opt record.trace_id acc) ~default:[] in
       String_map.add record.trace_id (record :: existing) acc)
    String_map.empty
    records
;;

let outcome_bucket_of_receipt = function
  | None -> Outcome_missing_receipt
  | Some receipt ->
    (match String.lowercase_ascii receipt.outcome with
     | "receipt_done" | "ok" -> Outcome_ok
     | "receipt_skipped" | "skipped" -> Outcome_skipped
     | "receipt_failed" | "error" -> Outcome_error
     | "receipt_cancelled" | "cancelled" -> Outcome_cancelled
     | _ -> Outcome_unknown)
;;

let outcome_bucket_to_string = function
  | Outcome_ok -> "ok"
  | Outcome_skipped -> "skipped"
  | Outcome_error -> "error"
  | Outcome_cancelled -> "cancelled"
  | Outcome_unknown -> "unknown"
  | Outcome_missing_receipt -> "missing_receipt"
;;

let trace_row_of_group receipts trace_id records =
  let records = List.rev records in
  let receipt = String_map.find_opt trace_id receipts in
  let outcome_bucket = outcome_bucket_of_receipt receipt in
  { trace_id
  ; keeper_id = (match records with r :: _ -> Some r.keeper_id | [] -> None)
  ; recall_records = List.length records
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

let evaluate ~masc_root =
  let recall_dir = Filename.concat masc_root "recall_injections" in
  let receipts_dir = Filename.concat masc_root "keepers" in
  let recall_records = load_records recall_dir parse_recall_json in
  let receipts = load_records receipts_dir parse_receipt_json in
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
      (fun acc row -> if row.outcome_bucket = bucket then acc + 1 else acc)
      0
      traces
  in
  { masc_root
  ; recall_dir
  ; receipts_dir
  ; recall_records = List.length recall_records
  ; recall_traces = List.length traces
  ; traces_with_receipt =
      List.fold_left
        (fun acc row -> if Option.is_some row.receipt then acc + 1 else acc)
        0
        traces
  ; traces_without_receipt = count_bucket Outcome_missing_receipt
  ; injected_fact_keys =
      List.fold_left (fun acc row -> acc + row.injected_fact_keys) 0 traces
  ; recall_failure_records =
      List.fold_left (fun acc row -> acc + row.recall_failure_records) 0 traces
  ; outcome_ok = count_bucket Outcome_ok
  ; outcome_skipped = count_bucket Outcome_skipped
  ; outcome_error = count_bucket Outcome_error
  ; outcome_cancelled = count_bucket Outcome_cancelled
  ; outcome_unknown = count_bucket Outcome_unknown
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
    ]
;;

let trace_row_to_json row =
  `Assoc
    [ "trace_id", `String row.trace_id
    ; "keeper_id", string_opt_to_json row.keeper_id
    ; "recall_records", `Int row.recall_records
    ; "injected_fact_keys", `Int row.injected_fact_keys
    ; "recall_failure_records", `Int row.recall_failure_records
    ; "outcome_bucket", `String (outcome_bucket_to_string row.outcome_bucket)
    ; ( "receipt"
      , match row.receipt with
        | Some receipt -> receipt_to_json receipt
        | None -> `Null )
    ]
;;

let take n xs =
  let rec loop remaining acc = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | x :: rest -> loop (remaining - 1) (x :: acc) rest
  in
  loop n [] xs
;;

let to_json ?(trace_limit = 50) report =
  `Assoc
    [ "masc_root", `String report.masc_root
    ; "recall_dir", `String report.recall_dir
    ; "receipts_dir", `String report.receipts_dir
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
    | Some receipt when receipt.terminal_reason_code <> "" -> receipt.terminal_reason_code
    | Some _ | None -> "-"
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

let render_text ?(trace_limit = 50) report =
  let traces = take trace_limit report.traces in
  let trace_lines =
    match traces with
    | [] -> "no recall traces found\n"
    | rows -> rows |> List.map render_trace |> String.concat ""
  in
  Printf.sprintf
    "Memory OS recall outcome eval (local receipts only)\n\
     masc_root: %s\n\
     recall_records: %d, recall_traces: %d\n\
     joined: with_receipt=%d without_receipt=%d\n\
     injected_fact_keys=%d recall_failure_records=%d\n\
     outcomes: ok=%d skipped=%d error=%d cancelled=%d unknown=%d missing_receipt=%d\n\
     trace_limit=%d\n\
     %s"
    report.masc_root
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
    trace_limit
    trace_lines
;;
