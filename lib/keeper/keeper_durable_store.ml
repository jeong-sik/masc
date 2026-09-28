let ( let* ) = Result.bind

(* How each store is read.

   A shell gate reads a store by knowing its layout: it runs [find] for a
   glob and calls a per-file subcommand, so every store needs a new
   subcommand and a new [find]. The path conventions
   already live in OCaml (a keeper's memory snapshot is a suffix on a
   configured id, a disposition receipt sits under a sha256 of the keeper
   name), so the enumeration belongs where the convention is.

   Adding a store is adding a constructor to [Id.t], a record here, and an
   arm in [reader]. The records are not exported, so one [reader] no longer
   routes to is an unused value and fails the build.

   [on_refusal] says what the runtime does with a row it cannot read. That is
   the part an operator needs at 3am and it differs per store: some refuse the
   whole file and stop the keeper, some drop the row and never say so. It is
   stated per row rather than inferred, because it is a property of the
   consumer and not of the decoder.

   Every scan runs the production decoder. A fixture cannot go stale here
   because there is no fixture -- these are the rows on disk, read by the
   binary about to serve them. *)
type report =
  { rows : int
  ; refused : int
  ; first_refusal : string option
  }

type store_scan =
  { store : string
  ; on_refusal : string
  ; scan : base_path:string -> (report, string) result
  }

let empty_report = { rows = 0; refused = 0; first_refusal = None }

let count_row report = function
  | Ok () -> { report with rows = report.rows + 1 }
  | Error detail ->
    { rows = report.rows + 1
    ; refused = report.refused + 1
    ; first_refusal =
        (match report.first_refusal with
         | Some _ as kept -> kept
         | None -> Some detail)
    }
;;

let scan_files ~paths ~decode =
  List.fold_left
    (fun report path ->
       match Fs_compat.load_file path with
       | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
       | exception exn ->
         count_row report (Error (path ^ ": " ^ Printexc.to_string exn))
       | contents ->
         count_row
           report
           (decode ~path contents |> Result.map_error (fun d -> path ^ ": " ^ d)))
    empty_report
    paths
;;

let scan_jsonl ~path ~decode =
  if not (Fs_compat.file_exists path)
  then empty_report
  else (
    let rows, malformed = Fs_compat.load_jsonl_diagnostics path in
    let report =
      List.fold_left
        (fun report json -> count_row report (decode json))
        empty_report
        rows
    in
    if malformed = 0
    then report
    else
      { rows = report.rows + malformed
      ; refused = report.refused + malformed
      ; first_refusal =
          (match report.first_refusal with
           | Some _ as refusal -> refusal
           | None ->
             Some
               (Printf.sprintf
                  "%s: %d malformed JSON row(s)"
                  path
                  malformed))
      })
;;

let files_under dir ~keep =
  match Sys.readdir dir with
  | exception Sys_error _ -> []
  | entries ->
    Array.to_list entries
    |> List.filter keep
    |> List.sort String.compare
    |> List.map (Filename.concat dir)
;;

(* The runtime writes keeper stores under the cluster's keepers directory; reading
   the default cluster's instead finds nothing on any other cluster and passes
   without having read a row. *)
let runtime_keepers_dir ~base_path =
  Workspace.keepers_runtime_dir_for_base_path base_path
;;

let keeper_meta_store =
  { store = "keeper meta"
  ; on_refusal =
      "the runtime reads the meta as absent and re-materialises the keeper \
       from its declaration, losing accumulated counters and the task binding"
  ; scan =
      (fun ~base_path ->
         let dir = runtime_keepers_dir ~base_path in
         Ok
           (scan_files
              ~paths:
                (files_under dir ~keep:(fun name ->
                   Filename.check_suffix name ".json"))
              ~decode:(fun ~path _ ->
                Keeper_meta_store.validate_current_meta_file_result path
                |> Result.map (fun _ -> ())
                |> Result.map_error (function
                  | Keeper_meta_store.Unreadable detail
                  | Keeper_meta_store.Not_current detail -> detail))))
  }
;;

let memory_os_current_store =
  { store = "memory OS current snapshot"
  ; on_refusal =
      "recall injection, the librarian and keeper_memory_write all fail for \
       that keeper, and neither writer repairs it because both read first"
  ; scan =
      (fun ~base_path ->
         let keepers_dir =
           Config_dir_resolver.keepers_dir_for_base_path ~base_path
         in
         Ok
           (Keeper_memory_os_current.list_keeper_ids_for_keepers_dir
              ~keepers_dir
            |> List.fold_left
                 (fun report keeper_id ->
                    match
                      Keeper_memory_os_current.read_for_keepers_dir
                        ~keepers_dir
                        ~keeper_id
                    with
                    | Ok None -> report
                    | Ok (Some _) -> count_row report (Ok ())
                    | Error detail ->
                      count_row report (Error (keeper_id ^ ": " ^ detail)))
                 empty_report))
  }
;;

let librarian_range_receipt_store =
  { store = "Librarian range receipt ledger"
  ; on_refusal =
      "every Memory write for that keeper -- the librarian, keeper_memory_write \
       and retraction -- reconciles the ledger first and fails, and the \
       Librarian cannot prove which range it already committed"
  ; scan =
      (fun ~base_path ->
         let keepers_dir =
           Config_dir_resolver.keepers_dir_for_base_path ~base_path
         in
         Ok
           (Keeper_memory_os_current.list_durable_range_receipt_keeper_ids
              ~keepers_dir
            |> List.fold_left
                 (fun report keeper_id ->
                    count_row
                      report
                      (Keeper_memory_os_current.validate_durable_range_receipts
                         ~keepers_dir
                         ~keeper_id
                       |> Result.map_error (fun detail -> keeper_id ^ ": " ^ detail)))
                 empty_report))
  }
;;

let memory_source_current_store =
  { store = "memory-source current claims"
  ; on_refusal =
      "keeper_memory_write and recall both refuse the claim for that source        path, and neither writer repairs it because the upsert reads first"
  ; scan =
      (fun ~base_path ->
         let keepers_dir =
           Config_dir_resolver.keepers_dir_for_base_path ~base_path
         in
         Ok
           (Keeper_memory_source_current.list_keeper_ids_for_keepers_dir
              ~keepers_dir
            |> List.fold_left
                 (fun report keeper_id ->
                    match
                      Keeper_memory_source_current.read_for_keepers_dir
                        ~keepers_dir
                        ~keeper_id
                    with
                    | Ok None -> report
                    | Ok (Some _) -> count_row report (Ok ())
                    | Error detail ->
                      count_row report (Error (keeper_id ^ ": " ^ detail)))
                 empty_report))
  }
;;

let disposition_receipt_store =
  { store = "paused-work disposition receipts"
  ; on_refusal =
      "the operation id neither replays its receipt nor records a new one, \
       because save_if_absent reads before it writes"
  ; scan =
      (fun ~base_path ->
         let root =
           Filename.concat
             (Common.masc_dir_from_base_path ~base_path)
             ("paused-work-dispositions-"
              ^ Keeper_paused_work_disposition_receipt.store_version)
         in
         let receipts =
           files_under root ~keep:(fun name ->
             String.starts_with ~prefix:"keeper-" name)
           |> List.concat_map (fun keeper_dir ->
             files_under keeper_dir ~keep:(fun name ->
               String.starts_with ~prefix:"operation-" name
               && Filename.check_suffix name ".json"))
         in
         Ok
           (scan_files ~paths:receipts ~decode:(fun ~path:_ contents ->
              match Yojson.Safe.from_string contents with
              | exception Yojson.Json_error detail -> Error detail
              | json ->
                Keeper_paused_work_disposition_receipt.of_yojson json
                |> Result.map (fun _ -> ()))))
  }
;;

let board_posts_store =
  { store = "board posts"
  ; on_refusal =
      "the loader drops the row without a log or a counter, and the next \
       full-snapshot write removes it from disk"
  ; scan =
      (fun ~base_path ->
         let path =
           Filename.concat
             (Common.masc_dir_from_base_path ~base_path)
             "board_posts.jsonl"
         in
         Ok
           (scan_jsonl ~path ~decode:(fun json ->
              match Masc_board_handlers.Board_votes_json.post_of_yojson json with
              | Some _ -> Ok ()
              | None -> Error "post rejected by the current field set")))
  }
;;

let provider_input_store =
  { store = "keeper provider-input snapshots"
  ; on_refusal =
      "the administrator exact-input endpoint cannot resolve that turn, and "
      ^ "a malformed newer row can mask older exact-input observations"
  ; scan =
      (fun ~base_path ->
         let keepers_dir = runtime_keepers_dir ~base_path in
         let store_dir =
           Common.keeper_runtime_store_dirname Common.Keeper_provider_inputs
         in
         let snapshot_files keeper_dir =
           files_under (Filename.concat keeper_dir store_dir) ~keep:(fun name ->
             not (String.starts_with ~prefix:"." name))
           |> List.concat_map (fun month ->
             files_under month ~keep:(fun name ->
               Filename.check_suffix name ".jsonl"))
         in
         let rec scan_rows input path line_number report =
           match input_line input with
           | exception End_of_file -> report
           | line ->
             let report =
               if String.trim line = ""
               then report
               else
                 count_row
                   report
                   (match Yojson.Safe.from_string line with
                    | exception Yojson.Json_error detail ->
                      Error
                        (Printf.sprintf
                           "%s:%d: %s"
                           path
                           line_number
                           detail)
                    | json ->
                      Keeper_provider_input_snapshot.of_json json
                      |> Result.map (fun _ -> ())
                      |> Result.map_error (fun detail ->
                        Printf.sprintf
                          "%s:%d: %s"
                          path
                          line_number
                          detail))
             in
             scan_rows input path (line_number + 1) report
         in
         let scan_file report path =
           match open_in path with
           | exception Sys_error detail ->
             count_row report (Error (path ^ ": " ^ detail))
           | input ->
             Fun.protect
               ~finally:(fun () -> close_in_noerr input)
               (fun () -> scan_rows input path 1 report)
         in
         Ok
           (files_under keepers_dir ~keep:(fun name ->
              not (Filename.check_suffix name ".json"))
            |> List.concat_map snapshot_files
            |> List.fold_left scan_file empty_report))
  }
;;

(* #29590 removed [generation] from TurnRecord as well as from the memory
   snapshot. [Turn_record.of_json] rejects unknown fields, and
   [Keeper_raw_trace_retention.protected_references] folds the whole sweep on
   the first refusal while its caller only warns -- so raw traces stop being
   collected and the disk grows with nothing failing loudly. The rows age out
   after [history_limit] new turns, which is exactly the window this gate
   exists to check before a deploy rather than after (#29666). *)
let turn_record_store =
  { store = "keeper turn records"
  ; on_refusal =
      "raw-trace retention folds its whole sweep on the first refused row and \
       the caller only warns, so traces accumulate with no failing turn"
  ; scan =
      (fun ~base_path ->
         let keepers_dir = runtime_keepers_dir ~base_path in
         let store_dir =
           Common.keeper_runtime_store_dirname Common.Keeper_turn_records
         in
         let recent_files keeper_dir =
           let root = Filename.concat keeper_dir store_dir in
           files_under root ~keep:(fun name ->
             not (String.starts_with ~prefix:"." name))
           |> List.concat_map (fun month ->
             files_under month ~keep:(fun name ->
               Filename.check_suffix name ".jsonl"))
         in
         let scan_file report path =
           match open_in path with
           | exception Sys_error _ -> report
           | ic ->
             Fun.protect
               ~finally:(fun () -> close_in_noerr ic)
               (fun () ->
                  let acc = ref report in
                  (try
                     while true do
                       let line = input_line ic in
                       if String.trim line <> ""
                       then
                         acc :=
                           count_row
                             !acc
                             (match Yojson.Safe.from_string line with
                              | exception Yojson.Json_error _ ->
                                Error (Filename.basename path ^ ": not JSON")
                              | json ->
                                (match Turn_record.of_json json with
                                 | Ok _ -> Ok ()
                                 | Error detail ->
                                   Error (Filename.basename path ^ ": " ^ detail)))
                     done
                   with End_of_file -> ());
                  !acc)
         in
         Ok
           (files_under keepers_dir ~keep:(fun name ->
              not (Filename.check_suffix name ".json"))
            |> List.concat_map recent_files
            |> List.fold_left scan_file empty_report))
  }
;;

(* The official-client session store decodes with the same exact-field
   contract the memory snapshot and TurnRecord use, and it lives on disk per
   keeper. [load] never turns malformed state into a fresh session, so every
   runtime that plans a claim refuses the turn. The traversal is the store's
   own [stored_bindings], which boot reconcile reads too. *)
let official_client_session_store =
  { store = "official-client session state"
  ; on_refusal =
      "every turn of that keeper fails before the provider call, because the \
       Claude Code, Codex and Antigravity runtimes cannot plan a claim, and \
       the operator's Restart_fresh reads the same file first"
  ; scan =
      (fun ~base_path ->
         Keeper_official_client_session_store.stored_bindings ~base_path
         |> Result.map
              (List.fold_left
                 (fun report
                   (stored : Keeper_official_client_session_store.stored_binding) ->
                    count_row
                      report
                      (match stored.decoded with
                       | Ok (_ : Keeper_official_client_session_store.t) -> Ok ()
                       | Error detail -> Error (stored.keeper_name ^ ": " ^ detail)))

                 empty_report))
  }
;;

(* Each keeper's queue is a snapshot and a transition WAL that carry one
   state. [Keeper_event_queue_persistence] keeps an undecodable snapshot and
   its WAL as they are and returns an error, so registration refuses the
   keeper, and a running keeper's heartbeat selects no stimulus; it takes no
   turn until the files are readable (#37900). The read is the persistence's
   own read-only validation, under its owner lock. *)
let event_queue_store =
  { store = "keeper event queue"
  ; on_refusal =
      "the keeper is not registered while its queue snapshot or transition \
       WAL does not decode, and a running one selects no stimulus, so it takes \
       no turn; the files are kept as they are"
  ; scan =
      (fun ~base_path ->
         let discovery =
           Keeper_event_queue_persistence.discover_keeper_names_with_durable_state
             ~base_path
         in
         match discovery.read_error with
         | Some detail -> Error detail
         | None ->
           Ok
             (List.fold_left
                (fun report keeper_name ->
                   count_row
                     report
                     (Keeper_event_queue_persistence
                      .validate_existing_state_read_only_result
                        ~base_path
                        ~keeper_name
                      |> Result.map (fun (_ : Keeper_event_queue_state.t) -> ())
                      |> Result.map_error (fun detail -> keeper_name ^ ": " ^ detail)))
                empty_report
                discovery.keeper_names))
  }
;;

(* The three position stores the Librarian lifecycle writes per keeper (RFC
   librarian-lifecycle sections 4.6 and 10.3), the turn fragments it consumes,
   and the two memory OS sidecars beside them (RFC-0456) decode field-exact,
   and nothing read them before a deploy (#37019). Each entry reads with the
   module's own decoder. A JSONL line a
   store reports as [Incomplete_line] is an append a crash cut short, which the
   next durable append trims away; it is not a row the new binary refuses, so
   it is neither counted as a row nor held against the deploy. *)
(* Journals and checkpoint locks live beside these directories. Their names
   do not make them stores; inspect the entry itself without following links. *)
let store_directories root =
  match Fs_compat.exact_path_kind ~follow:false root with
  | Fs_compat.Exact_missing -> Ok []
  | Fs_compat.Exact_kind Unix.S_DIR ->
    (match Sys.readdir root with
     | exception Sys_error detail -> Error detail
     | entries ->
       Array.to_list entries |> List.sort String.compare
       |> List.fold_left (fun result name ->
         let* paths = result in
         let path = Filename.concat root name in
         match Fs_compat.exact_path_kind ~follow:false path with
         | Fs_compat.Exact_kind Unix.S_DIR -> Ok (path :: paths)
         | Fs_compat.Exact_kind Unix.S_REG -> Ok paths
         | Fs_compat.Exact_missing | Fs_compat.Exact_unknown
         | Fs_compat.Exact_kind _ -> Error ("store entry cannot be inspected safely: " ^ path))
         (Ok [])
       |> Result.map List.rev)
  | Fs_compat.Exact_unknown | Fs_compat.Exact_kind _ ->
    Error ("store directory cannot be inspected safely: " ^ root)
;;

let scan_keeper_dirs ~base_path scan_keeper =
  let* directories = store_directories (runtime_keepers_dir ~base_path) in
  Ok
    (directories
     |> List.fold_left
          (fun report keeper_dir ->
             scan_keeper report ~keeper_id:(Filename.basename keeper_dir))
          empty_report)
;;

let turn_boundary_store =
  { store = "keeper turn boundaries"
  ; on_refusal =
      "the Librarian round stops at the line and journals it, so the keeper's \
       turns after it are not read until the line is readable"
  ; scan =
      (fun ~base_path ->
         let keepers_dir = runtime_keepers_dir ~base_path in
         scan_keeper_dirs ~base_path (fun report ~keeper_id ->
           match Keeper_turn_boundaries.read ~keepers_dir ~keeper_id with
           | Error detail -> count_row report (Error (keeper_id ^ ": " ^ detail))
           | Ok lines ->
             List.fold_left
               (fun report (line, decoded) ->
                  match decoded with
                  | Ok _ -> count_row report (Ok ())
                  | Error Keeper_turn_boundaries.Incomplete_line -> report
                  | Error
                      (( Keeper_turn_boundaries.Not_json _
                       | Keeper_turn_boundaries.Malformed _ ) as error) ->
                    count_row
                      report
                      (Error
                         (Printf.sprintf
                            "%s line %d: %s"
                            keeper_id
                            line
                            (Keeper_turn_boundaries.read_error_to_string error))))
               report
               lines))
  }
;;

let librarian_progress_store =
  { store = "keeper Librarian progress"
  ; on_refusal =
      "the read position is an error, never \"not read yet\", so the keeper's \
       history is neither read again from zero nor read further until the \
       file is readable"
  ; scan =
      (fun ~base_path ->
         let keepers_dir = runtime_keepers_dir ~base_path in
         scan_keeper_dirs ~base_path (fun report ~keeper_id ->
           match Keeper_librarian_progress.read ~keepers_dir ~keeper_id with
           | Ok None -> report
           | Ok (Some _) -> count_row report (Ok ())
           | Error error ->
             count_row
               report
               (Error
                  (keeper_id
                   ^ ": "
                   ^ Keeper_librarian_progress.read_error_to_string error))))
  }
;;

let librarian_official_progress_store =
  { store = "keeper official-client Librarian progress"
  ; on_refusal =
      "the official-client read position is an error, never \"not read yet\", so the \
       keeper's official turns are not read until the file is readable"
  ; scan =
      (fun ~base_path ->
         let keepers_dir = runtime_keepers_dir ~base_path in
         scan_keeper_dirs ~base_path (fun report ~keeper_id ->
           match
             Keeper_librarian_official_progress.read ~keepers_dir ~keeper_id
           with
           | Ok None -> report
           | Ok (Some _) -> count_row report (Ok ())
           | Error error ->
             count_row
               report
               (Error
                  (keeper_id
                   ^ ": "
                   ^ Keeper_librarian_official_progress.read_error_to_string
                       error))))
  }
;;

let turn_fragment_store =
  { store = "keeper official-client turn fragments"
  ; on_refusal =
      "a Librarian round stops before a refused named-turn fragment instead of \
       reading past words or tool observations it cannot assign to that turn"
  ; scan =
      (fun ~base_path ->
         let root = Keeper_fs.session_store_path_for_base_path base_path in
         let* directories = store_directories root in
         Ok
           (directories
            |> List.fold_left
                 (fun report session_dir ->
                    let trace_id = Filename.basename session_dir in
                    List.fold_left
                      (fun report file ->
                         match Keeper_turn_fragments.read ~session_dir file with
                         | Error detail ->
                           count_row report (Error (trace_id ^ ": " ^ detail))
                         | Ok lines ->
                           List.fold_left
                             (fun report (line, decoded) ->
                                match decoded with
                                | Ok _ -> count_row report (Ok ())
                                | Error Keeper_turn_fragments.Incomplete_line ->
                                  report
                                | Error error ->
                                  count_row
                                    report
                                    (Error
                                       (Printf.sprintf
                                          "%s line %d: %s"
                                          trace_id
                                          line
                                          (Keeper_turn_fragments.read_error_to_string
                                             error))))
                             report
                             lines)
                      report
                      [ Keeper_turn_fragments.Main
                      ; Keeper_turn_fragments.Internal
                      ])
                 empty_report))
  }
;;

let memory_absorbed_store =
  { store = "keeper absorbed memory facts"
  ; on_refusal =
      "the row stays an error its readers count and name, and the fact it \
       carries is not read"
  ; scan =
      (fun ~base_path ->
         let keepers_dir = runtime_keepers_dir ~base_path in
         scan_keeper_dirs ~base_path (fun report ~keeper_id ->
           match Keeper_memory_absorbed.read ~keepers_dir ~keeper_id with
           | Error detail -> count_row report (Error (keeper_id ^ ": " ^ detail))
           | Ok lines ->
             List.fold_left
               (fun report (line, decoded) ->
                  match decoded with
                  | Ok _ -> count_row report (Ok ())
                  | Error Keeper_memory_absorbed.Incomplete_line -> report
                  | Error
                      (( Keeper_memory_absorbed.Not_json _
                       | Keeper_memory_absorbed.Malformed _ ) as error) ->
                    count_row
                      report
                      (Error
                         (Printf.sprintf
                            "%s line %d: %s"
                            keeper_id
                            line
                            (Keeper_memory_absorbed.read_error_to_string error))))
               report
               lines))
  }
;;

let memory_os_events_store =
  { store = "keeper memory OS events"
  ; on_refusal =
      "the event stays an error its readers count and name, and the retrieval \
       it records drops out of the memory's summary"
  ; scan =
      (fun ~base_path ->
         let keepers_dir = runtime_keepers_dir ~base_path in
         scan_keeper_dirs ~base_path (fun report ~keeper_id ->
           match Keeper_memory_os_events.read ~keepers_dir ~keeper_id with
           | Error file_error ->
             count_row
               report
               (Error
                  (keeper_id
                   ^ ": "
                   ^ Keeper_memory_os_events.file_read_error_to_string file_error))
           | Ok lines ->
             List.fold_left
               (fun report (line, decoded) ->
                  match decoded with
                  | Ok _ -> count_row report (Ok ())
                  | Error error ->
                    count_row
                      report
                      (Error
                         (Printf.sprintf
                            "%s line %d: %s"
                            keeper_id
                            line
                            (Keeper_memory_os_events.read_error_to_string error))))
               report
               lines))
  }
;;

let gate_pending_store =
  { store = "gate pending approvals"
  ; on_refusal =
      "install_persistence refuses the whole approval queue at boot and every \
       gate decision is unavailable; for an unsupported version, reset \
       gate/pending.json and gate/pending.log.jsonl after the server is \
       confirmed stopped and before it starts"
  ; scan =
      (fun ~base_path ->
         let path = Keeper_gate_path.pending ~base_path in
         Ok
           (scan_files
              ~paths:(if Fs_compat.file_exists path then [ path ] else [])
              ~decode:(fun ~path:_ contents ->
                match Yojson.Safe.from_string contents with
                | exception Yojson.Json_error detail -> Error ("invalid JSON: " ^ detail)
                | json -> Keeper_approval_queue.validate_pending_snapshot ~base_path json)))
  }
;;

module Id = struct
  type t =
    | Keeper_meta
    | Gate_pending
    | Official_client_session
    | Memory_current
    | Goal_store
    | Librarian_range_receipts
    | Memory_source_current
    | Disposition_receipts
    | Board_posts
    | Provider_inputs
    | Turn_records
    | Turn_boundaries
    | Librarian_progress
    | Librarian_official_progress
    | Turn_fragments
    | Memory_absorbed
    | Memory_os_events
    | Keeper_event_queue
  [@@deriving enumerate]
end

module Refusing = struct
  type t =
    | Keeper_meta
    | Memory_current
    | Official_client_session
    | Event_queue

  [@@deriving enumerate]
end

module Reported = struct
  type t = Goal_store [@@deriving enumerate]
end

type scan = store_scan

type reader =
  | Refuse_boot of Refusing.t * scan
  | Degrade_typed of Reported.t
  | Preflight_only of scan

let reader : Id.t -> reader = function
  | Id.Keeper_meta -> Refuse_boot (Refusing.Keeper_meta, keeper_meta_store)
  | Id.Memory_current -> Refuse_boot (Refusing.Memory_current, memory_os_current_store)
  | Id.Goal_store -> Degrade_typed Reported.Goal_store
  | Id.Gate_pending -> Preflight_only gate_pending_store
  | Id.Official_client_session ->
    Refuse_boot (Refusing.Official_client_session, official_client_session_store)

  | Id.Librarian_range_receipts -> Preflight_only librarian_range_receipt_store
  | Id.Memory_source_current -> Preflight_only memory_source_current_store
  | Id.Disposition_receipts -> Preflight_only disposition_receipt_store
  | Id.Board_posts -> Preflight_only board_posts_store
  | Id.Provider_inputs -> Preflight_only provider_input_store
  | Id.Turn_records -> Preflight_only turn_record_store
  | Id.Turn_boundaries -> Preflight_only turn_boundary_store
  | Id.Librarian_progress -> Preflight_only librarian_progress_store
  | Id.Librarian_official_progress -> Preflight_only librarian_official_progress_store
  | Id.Turn_fragments -> Preflight_only turn_fragment_store
  | Id.Memory_absorbed -> Preflight_only memory_absorbed_store
  | Id.Memory_os_events -> Preflight_only memory_os_events_store
  | Id.Keeper_event_queue -> Refuse_boot (Refusing.Event_queue, event_queue_store)
;;

let name id =
  match reader id with
  | Refuse_boot (_, scan) | Preflight_only scan -> scan.store
  | Degrade_typed Reported.Goal_store -> "goal store"
;;

let preflight_scan id =
  match reader id with
  | Refuse_boot (_, scan) | Preflight_only scan -> Some scan
  | Degrade_typed _ -> None
;;

let run (scan : scan) ~base_path = scan.scan ~base_path
let on_refusal (scan : scan) = scan.on_refusal
