(** Runtime-manifest scan: receipt-matching + summary-JSON helpers.

    Extracted from [server_dashboard_http_keeper_api.ml] (lines
    141-235) as part of the godfile decomp campaign. Pure helper
    functions over the
    [Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan] record and
    JSONL receipt rows on disk.

    Surface ownership:
    - receipt row matching ({!receipt_row_matches}, {!read_receipt_rows})
      — operate on raw [Yojson.Safe.t] rows + paths;
    - generic JSON helpers ({!unique_ints}, {!json_int_list},
      {!Json_util.json_string_list}) — local single-use sugar;
    - per-section scan summaries ({!event_bus_summary_json})
      — fold the manifest scan record into a
      single [`Assoc] for dashboard payload;
    - turn-id selection helpers ({!max_int_list_opt},
      {!selected_keeper_turn_id}, {!terminal_event_present_for_turn})
      — used to pick the active keeper turn for runtime-lens. *)

open Server_dashboard_http_keeper_api_types

let receipt_row_matches ?turn_id keeper_name trace_id json =
  let keeper_matches = Json_util.get_string json "keeper_name" = Some keeper_name in
  let trace_matches = Json_util.get_string json "trace_id" = Some trace_id in
  let turn_matches =
    match turn_id with
    | None -> false
    | Some wanted -> Json_util.get_int json "turn_count" = Some wanted
  in
  keeper_matches && (trace_matches || turn_matches)
;;

type receipt_read_error_kind =
  | Receipt_json_error
  | Receipt_row_not_object
  | Receipt_path_is_directory
  | Receipt_io_error

let receipt_read_error_kind_to_string = function
  | Receipt_json_error -> "json_error"
  | Receipt_row_not_object -> "row_not_object"
  | Receipt_path_is_directory -> "path_is_directory"
  | Receipt_io_error -> "io_error"
;;

let receipt_read_error_to_json ~path ?line_index ~kind ~message () =
  let line_index_field =
    match line_index with
    | Some index -> [ "line_index", `Int index ]
    | None -> []
  in
  `Assoc
    ([ "source", `String "runtime_trace_execution_receipt_jsonl"
     ; "path", `String path
     ]
     @ line_index_field
     @ [ "kind", `String (receipt_read_error_kind_to_string kind)
       ; "message", `String message
       ])
;;

let read_receipt_rows_from_path_with_read_errors
      ~keeper_name
      ~trace_id
      ?turn_id
      path
  =
  try
    if not (Sys.file_exists path)
    then [], []
    else if Sys.is_directory path
    then
      ( []
      , [ receipt_read_error_to_json
            ~path
            ~kind:Receipt_path_is_directory
            ~message:"execution receipt path is a directory"
            ()
        ] )
    else (
      let input = open_in_bin path in
      Eio_guard.protect
        ~finally:(fun () -> close_in_noerr input)
        (fun () ->
           let rec loop line_index rows read_errors =
             match input_line input with
             | line ->
               let trimmed = String.trim line in
               if String.equal trimmed ""
               then loop (line_index + 1) rows read_errors
               else (
                 match Yojson.Safe.from_string trimmed with
                 | `Assoc _ as json ->
                   let rows =
                     if receipt_row_matches ?turn_id keeper_name trace_id json
                     then json :: rows
                     else rows
                   in
                   loop (line_index + 1) rows read_errors
                 | other ->
                   loop
                     (line_index + 1)
                     rows
                     (receipt_read_error_to_json
                        ~path
                        ~line_index
                        ~kind:Receipt_row_not_object
                        ~message:
                          (Printf.sprintf
                             "execution receipt JSONL row must be object, got %s"
                             (Json_util.kind_name other))
                        ()
                      :: read_errors)
                 | exception Yojson.Json_error message ->
                   loop
                     (line_index + 1)
                     rows
                     (receipt_read_error_to_json
                        ~path
                        ~line_index
                        ~kind:Receipt_json_error
                        ~message
                        ()
                      :: read_errors))
             | exception End_of_file -> List.rev rows, List.rev read_errors
           in
           loop 1 [] [])
    )
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | (Sys_error _ | Unix.Unix_error _) as exn ->
    ( []
    , [ receipt_read_error_to_json
          ~path
          ~kind:Receipt_io_error
          ~message:(Printexc.to_string exn)
          ()
      ] )
;;

let read_receipt_rows_with_read_errors ~keeper_name ~trace_id ?turn_id paths =
  let rows_rev, read_errors_rev =
    paths
    |> List.fold_left
         (fun (rows_rev, read_errors_rev) path ->
            let rows, read_errors =
              read_receipt_rows_from_path_with_read_errors
                ~keeper_name
                ~trace_id
                ?turn_id
                path
            in
            List.rev_append rows rows_rev, List.rev_append read_errors read_errors_rev)
         ([], [])
  in
  List.rev rows_rev, List.rev read_errors_rev
;;

let read_receipt_rows ~keeper_name ~trace_id ?turn_id paths =
  paths
  |> read_receipt_rows_with_read_errors ~keeper_name ~trace_id ?turn_id
  |> fst
;;

let unique_ints values = values |> List.sort_uniq Int.compare
let json_int_list values = `List (List.map (fun value -> `Int value) values)

let event_bus_summary_json
      (scan : Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan)
  =
  let correlation_ids =
    scan.event_bus_correlation_ids |> List.rev |> Json_util.dedupe_keep_order
  in
  let run_ids = scan.event_bus_run_ids |> List.rev |> Json_util.dedupe_keep_order in
  let last_compaction =
    match scan.last_compaction with
    | Some value -> value
    | None -> `Null
  in
  `Assoc
    [ "event_bus_correlated_count", `Int scan.event_bus_count
    ; "correlation_ids", Json_util.json_string_list correlation_ids
    ; "run_ids", Json_util.json_string_list run_ids
    ; "context_compact_started_count", `Int scan.context_compact_started_count
    ; "context_compacted_count", `Int scan.context_compacted_count
    ; "last_compaction", last_compaction
    ]
;;

let max_int_list_opt values =
  List.fold_left
    (fun acc value ->
       match acc with
       | None -> Some value
       | Some existing -> Some (max existing value))
    None
    values
;;

let selected_keeper_turn_id
      ?turn_id
      (scan : Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan)
  =
  match turn_id with
  | Some value -> Some value
  | None -> max_int_list_opt scan.keeper_turn_ids
;;

let terminal_event_present_for_turn
      ?keeper_turn_id
      (scan : Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan)
  =
  match keeper_turn_id with
  | Some value -> List.mem value scan.terminal_keeper_turn_ids
  | None -> scan.has_terminal
;;
