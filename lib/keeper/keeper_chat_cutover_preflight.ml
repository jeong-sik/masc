type queue_counts =
  { total : int
  ; pending : int
  ; inflight : int
  ; recovery_required : int
  ; terminal : int
  }

type queue_database =
  { keeper_name : string
  ; path : string
  ; counts : queue_counts
  }

type artifact =
  { keeper_name : string
  ; path : string
  }

type report =
  { queue_databases : queue_database list
  ; queue_sidecars : artifact list
  ; direct_delivery_directories : artifact list
  ; direct_marker_count : int
  }

type error =
  | Filesystem_error of
      { path : string
      ; detail : string
      }
  | Unexpected_file_kind of
      { path : string
      ; expected : string
      ; actual : string
      }
  | Queue_database_error of
      { path : string
      ; detail : string
      }

let ( let* ) = Result.bind

let legacy_queue_database = "chat-queue.sqlite3"
let legacy_queue_sidecars = [ "chat-queue.sqlite3-journal"; "chat-queue.sqlite3-wal"; "chat-queue.sqlite3-shm" ]
let legacy_direct_delivery_directory = ".chat-direct-active-v1"

let file_kind_to_string = function
  | Unix.S_REG -> "regular_file"
  | S_DIR -> "directory"
  | S_CHR -> "character_device"
  | S_BLK -> "block_device"
  | S_LNK -> "symlink"
  | S_FIFO -> "fifo"
  | S_SOCK -> "socket"
;;

let lstat_optional path =
  try Ok (Some (Unix.lstat path)) with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
  | Unix.Unix_error (error, syscall, argument) ->
    Error
      (Filesystem_error
         { path
         ; detail =
             Printf.sprintf "%s(%s): %s" syscall argument (Unix.error_message error)
         })
;;

let directory_entries path =
  try Ok (Sys.readdir path |> Array.to_list |> List.sort String.compare) with
  | Sys_error detail -> Error (Filesystem_error { path; detail })
;;

let checked_int path field value =
  if Int64.compare value 0L < 0 || Int64.compare value (Int64.of_int max_int) > 0
  then
    Error
      (Queue_database_error
         { path; detail = Printf.sprintf "%s is outside the supported range" field })
  else Ok (Int64.to_int value)
;;

let saturating_add left right =
  if left > max_int - right then max_int else left + right
;;

let sqlite_error db operation rc =
  Printf.sprintf
    "%s: rc=%s detail=%s"
    operation
    (Sqlite3.Rc.to_string rc)
    (Sqlite3.errmsg db)
;;

let read_queue_counts path =
  try
    let db = Sqlite3.db_open ~mode:`READONLY path in
    let result =
      try
        let statement =
          Sqlite3.prepare
            db
            "SELECT COUNT(*), COALESCE(SUM(state_kind = 'pending'), 0), COALESCE(SUM(state_kind = 'inflight'), 0), COALESCE(SUM(state_kind = 'recovery_required'), 0), COALESCE(SUM(state_kind IN ('delivered', 'failed')), 0) FROM receipts"
        in
        let finalize_rc = ref Sqlite3.Rc.OK in
        let result =
          Fun.protect
            ~finally:(fun () -> finalize_rc := Sqlite3.finalize statement)
            (fun () ->
               match Sqlite3.step statement with
               | Sqlite3.Rc.ROW ->
                 let* total =
                   checked_int path "total" (Sqlite3.column_int64 statement 0)
                 in
                 let* pending =
                   checked_int path "pending" (Sqlite3.column_int64 statement 1)
                 in
                 let* inflight =
                   checked_int path "inflight" (Sqlite3.column_int64 statement 2)
                 in
                 let* recovery_required =
                   checked_int
                     path
                     "recovery_required"
                     (Sqlite3.column_int64 statement 3)
                 in
                 let* terminal =
                   checked_int path "terminal" (Sqlite3.column_int64 statement 4)
                 in
                 let remaining_after_pending = total - pending in
                 if pending > total
                    || inflight > remaining_after_pending
                    || recovery_required > remaining_after_pending - inflight
                    || terminal
                       <> remaining_after_pending - inflight - recovery_required
                 then
                   Error
                     (Queue_database_error
                        { path
                        ; detail = "receipt state counts do not sum to the total"
                        })
                 else Ok { total; pending; inflight; recovery_required; terminal }
               | rc ->
                 Error
                   (Queue_database_error
                      { path
                      ; detail = sqlite_error db "count legacy chat rows" rc
                      }))
        in
        if Sqlite3.Rc.is_success !finalize_rc
        then result
        else
          Error
            (Queue_database_error
               { path
               ; detail =
                   sqlite_error db "finalize legacy chat row count" !finalize_rc
               })
      with
      | Sqlite3.Error detail -> Error (Queue_database_error { path; detail })
    in
    let closed = Sqlite3.db_close db in
    (match result, closed with
     | Ok counts, true -> Ok counts
     | Error _ as error, _ -> error
     | Ok _, false ->
       Error
         (Queue_database_error
            { path; detail = "read-only legacy chat database did not close cleanly" }))
  with
  | Sqlite3.Error detail -> Error (Queue_database_error { path; detail })
;;

let rec count_descendants path =
  let* entries = directory_entries path in
  List.fold_left
    (fun result entry ->
       let* count = result in
       let child = Filename.concat path entry in
       let* stat = lstat_optional child in
       match stat with
       | None -> Ok count
       | Some { Unix.st_kind = Unix.S_DIR; _ } ->
         let* descendants = count_descendants child in
         Ok (saturating_add count descendants)
       | Some _ -> Ok (saturating_add count 1))
    (Ok 0)
    entries
;;

let inspect_keeper keeper_name keeper_dir =
  let queue_path = Filename.concat keeper_dir legacy_queue_database in
  let direct_path = Filename.concat keeper_dir legacy_direct_delivery_directory in
  let* queue_stat = lstat_optional queue_path in
  let* queue_database =
    match queue_stat with
    | None -> Ok None
    | Some { Unix.st_kind = Unix.S_REG; _ } ->
      let* counts = read_queue_counts queue_path in
      Ok (Some { keeper_name; path = queue_path; counts })
    | Some stat ->
      Error
        (Unexpected_file_kind
           { path = queue_path
           ; expected = "regular_file"
           ; actual = file_kind_to_string stat.Unix.st_kind
           })
  in
  let* queue_sidecars =
    List.fold_left
      (fun result basename ->
         let* found = result in
         let path = Filename.concat keeper_dir basename in
         let* stat = lstat_optional path in
         match stat with
         | None -> Ok found
         | Some { Unix.st_kind = Unix.S_REG; _ } ->
           Ok ({ keeper_name; path } :: found)
         | Some observed ->
           Error
             (Unexpected_file_kind
                { path
                ; expected = "regular_file"
                ; actual = file_kind_to_string observed.Unix.st_kind
                }))
      (Ok [])
      legacy_queue_sidecars
  in
  let* direct_stat = lstat_optional direct_path in
  let* direct_delivery_directory, direct_marker_count =
    match direct_stat with
    | None -> Ok (None, 0)
    | Some { Unix.st_kind = Unix.S_DIR; _ } ->
      let* count = count_descendants direct_path in
      Ok (Some { keeper_name; path = direct_path }, count)
    | Some stat ->
      Error
        (Unexpected_file_kind
           { path = direct_path
           ; expected = "directory"
           ; actual = file_kind_to_string stat.Unix.st_kind
           })
  in
  Ok (queue_database, List.rev queue_sidecars, direct_delivery_directory, direct_marker_count)
;;

let empty_report =
  { queue_databases = []
  ; queue_sidecars = []
  ; direct_delivery_directories = []
  ; direct_marker_count = 0
  }
;;

let inspect ~keepers_root =
  let* root_stat = lstat_optional keepers_root in
  match root_stat with
  | None -> Ok empty_report
  | Some { Unix.st_kind = Unix.S_DIR; _ } ->
    let* entries = directory_entries keepers_root in
    List.fold_left
      (fun result keeper_name ->
         let* report = result in
         let keeper_dir = Filename.concat keepers_root keeper_name in
         let* keeper_stat = lstat_optional keeper_dir in
         match keeper_stat with
         | None -> Ok report
         | Some { Unix.st_kind = Unix.S_DIR; _ } ->
           let* queue_database, queue_sidecars, direct_delivery_directory, marker_count =
             inspect_keeper keeper_name keeper_dir
           in
           Ok
             { queue_databases =
                 (match queue_database with
                  | None -> report.queue_databases
                  | Some database -> database :: report.queue_databases)
             ; queue_sidecars = List.rev_append queue_sidecars report.queue_sidecars
             ; direct_delivery_directories =
                 (match direct_delivery_directory with
                  | None -> report.direct_delivery_directories
                  | Some directory -> directory :: report.direct_delivery_directories)
             ; direct_marker_count =
                 saturating_add report.direct_marker_count marker_count
             }
         | Some { Unix.st_kind = Unix.S_LNK; _ } ->
           Error
             (Unexpected_file_kind
                { path = keeper_dir
                ; expected = "directory_or_runtime_metadata"
                ; actual = "symlink"
                })
         | Some _ -> Ok report)
      (Ok empty_report)
      entries
    |> Result.map (fun report ->
      { report with
        queue_databases = List.rev report.queue_databases
      ; queue_sidecars = List.rev report.queue_sidecars
      ; direct_delivery_directories = List.rev report.direct_delivery_directories
      })
  | Some stat ->
    Error
      (Unexpected_file_kind
         { path = keepers_root
         ; expected = "directory"
         ; actual = file_kind_to_string stat.Unix.st_kind
         })
;;

let artifact_count report =
  List.length report.queue_databases
  + List.length report.queue_sidecars
  + List.length report.direct_delivery_directories
;;

let is_clear report = artifact_count report = 0

let active_queue_row_count report =
  List.fold_left
    (fun total database ->
       saturating_add
         total
         (saturating_add
            database.counts.pending
            (saturating_add
               database.counts.inflight
               database.counts.recovery_required)))
    0
    report.queue_databases
;;

let stranded_work_count report =
  saturating_add (active_queue_row_count report) report.direct_marker_count
;;

let error_to_string = function
  | Filesystem_error { path; detail } ->
    Printf.sprintf "Keeper chat cutover filesystem error path=%s: %s" path detail
  | Unexpected_file_kind { path; expected; actual } ->
    Printf.sprintf
      "Keeper chat cutover path has the wrong kind path=%s expected=%s actual=%s"
      path
      expected
      actual
  | Queue_database_error { path; detail } ->
    Printf.sprintf "Keeper chat cutover database is unreadable path=%s: %s" path detail
;;

let queue_counts_to_yojson counts =
  `Assoc
    [ "total", `Int counts.total
    ; "pending", `Int counts.pending
    ; "inflight", `Int counts.inflight
    ; "recovery_required", `Int counts.recovery_required
    ; "terminal", `Int counts.terminal
    ]
;;

let artifact_to_yojson artifact =
  `Assoc [ "keeper_name", `String artifact.keeper_name; "path", `String artifact.path ]
;;

let report_to_yojson report =
  `Assoc
    [ "schema", `String "masc.keeper_chat_cutover_preflight.v1"
    ; "artifact_count", `Int (artifact_count report)
    ; "active_queue_row_count", `Int (active_queue_row_count report)
    ; "direct_marker_count", `Int report.direct_marker_count
    ; "stranded_work_count", `Int (stranded_work_count report)
    ; ( "queue_databases"
      , `List
          (List.map
             (fun (database : queue_database) ->
                `Assoc
                  [ "keeper_name", `String database.keeper_name
                  ; "path", `String database.path
                  ; "counts", queue_counts_to_yojson database.counts
                  ])
             report.queue_databases) )
    ; "queue_sidecars", `List (List.map artifact_to_yojson report.queue_sidecars)
    ; ( "direct_delivery_directories"
      , `List (List.map artifact_to_yojson report.direct_delivery_directories) )
    ]
;;

let report_to_string report = Yojson.Safe.to_string (report_to_yojson report)
