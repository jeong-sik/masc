open Result.Syntax
open Keeper_msg_async_types
open Keeper_msg_async_record
open Keeper_msg_async_state
open Keeper_msg_async_locks

let request_dir ~base_path =
  Filename.concat (Common.masc_dir_from_base_path ~base_path) "keeper_msg_requests"
;;

let active_request_dir ~base_path = Filename.concat (request_dir ~base_path) "active"
let terminal_request_dir ~base_path = Filename.concat (request_dir ~base_path) "terminal"
let atomic_staging_dir ~base_path =
  Filename.concat (request_dir ~base_path) ".atomic-staging"
;;

let canonical_base_path base_path =
  let normalized = Workspace_utils_backend_setup.normalize_base_path base_path in
  if String.equal normalized ""
  then Error (Invalid_base_path { reason = "base_path is empty" })
  else
    try Ok (Fs_compat.realpath normalized) with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Error
        (Invalid_base_path
           { reason =
               Printf.sprintf
                 "cannot canonicalize base_path: %s"
                 (Printexc.to_string exn)
           })
;;

let validate_caller caller =
  let trimmed = String.trim caller in
  if String.equal trimmed "" || not (String.equal caller trimmed)
  then Error Invalid_caller
  else Ok caller
;;

let resolve_access_identity ~base_path ~caller =
  let* base_path = canonical_base_path base_path in
  let* submitted_by = validate_caller caller in
  Ok (base_path, submitted_by)
;;

let request_key ~base_path ~submitted_by ~request_id : Request_key.t =
  { base_path; submitted_by; request_id }
;;

let max_request_id_len = 128

let is_safe_request_id request_id =
  let len = String.length request_id in
  if len = 0
  then false
  else if request_id = "." || request_id = ".."
  then false
  else if len > max_request_id_len
  then false
  else (
    let rec loop i =
      if i = len
      then true
      else (
        match request_id.[i] with
        | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' | '.' -> loop (i + 1)
        | _ -> false)
    in
    loop 0)
;;

let record_path_in directory ~request_id =
  if is_safe_request_id request_id
  then Some (Filename.concat directory (request_id ^ ".json"))
  else None
;;

let active_record_path ~base_path ~request_id =
  record_path_in (active_request_dir ~base_path) ~request_id
;;

let terminal_record_path ~base_path ~request_id =
  record_path_in (terminal_request_dir ~base_path) ~request_id
;;

type record_file_load_result =
  | Record_file_found of entry
  | Record_file_absent
  | Record_file_unreadable of string

let load_record_file_at_path ~base_path ~request_id path =
  let decoded =
    match Fs_compat.load_owned_regular_file ~ownership_root:base_path path with
    | Ok None -> None
    | Error error ->
      Some (Error (Fs_compat.owned_regular_file_read_error_to_string error))
    | Ok (Some content) ->
      Some
        (try
           content
           |> Yojson.Safe.from_string
           |> entry_of_record_json ~base_path ~request_id
         with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | exn -> Error (Printexc.to_string exn))
  in
  match decoded with
  | None -> Record_file_absent
  | Some (Ok entry) -> Record_file_found entry
  | Some (Error reason) ->
    Log.Keeper.warn
      "keeper_msg_async: load failed request_id=%s path=%s error=%s"
      request_id
      path
      reason;
    Record_file_unreadable reason
;;

let load_record_at_path ~base_path ~request_id path =
  match load_record_file_at_path ~base_path ~request_id path with
  | Record_file_found entry -> Found entry
  | Record_file_absent -> Absent
  | Record_file_unreadable reason -> Unreadable reason
;;

type record_location =
  | Active_location
  | Terminal_location

type located_load_result =
  | Located of entry * record_location
  | Located_absent
  | Located_unreadable of string
  | Located_rejected of access_rejection

let observe_namespace_degradation ~operation (entry : entry) detail =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string FsFailures)
    ~labels:[ "subsystem", "keeper_msg_async"; "operation", operation ]
    ();
  Log.Keeper.warn
    "keeper_msg_async: namespace durability degraded operation=%s request_id=%s path_identity=%s detail=%s"
    operation
    entry.request_id
    entry.base_path
    detail
;;

let remove_duplicate_source_unlocked ~ops ~(entry : entry) path =
  let result =
    ops.remove_file_durable ~ownership_root:entry.base_path path
  in
  let removed =
    match result with
    | Ok () -> true
    | Error error ->
      observe_namespace_degradation
        ~operation:"terminal_source_cleanup"
        entry
        (Printf.sprintf
           "removed=%b %s"
           error.removed
           (Keeper_fs.durable_remove_error_to_string error));
      error.removed
  in
  if removed then Keeper_msg_async_broadcast.requests_changed ~keeper_name:entry.keeper_name;
  removed
;;

type persist_integrity_error =
  | Unsafe_request_id
  | Invalid_keeper_name of string
  | Terminal_partition_nonterminal
  | Terminal_conflict
  | Terminal_unreadable of string
  | Terminal_access_rejected of access_rejection

type write_failure =
  | Not_published of Keeper_fs.durable_write_error
  | Published_uncertain of Keeper_fs.durable_write_error

type persist_error =
  | Write_failed of write_failure
  | Integrity_failed of persist_integrity_error

let persist_integrity_error_to_string = function
  | Unsafe_request_id -> "request_id is unsafe for persistence"
  | Invalid_keeper_name reason -> reason
  | Terminal_partition_nonterminal ->
    "terminal partition contains a non-terminal request record"
  | Terminal_conflict ->
    "terminal request record conflicts with the transition candidate"
  | Terminal_unreadable reason ->
    Printf.sprintf "terminal request record is unreadable: %s" reason
  | Terminal_access_rejected rejection ->
    access_rejection_to_json rejection |> Yojson.Safe.to_string
;;

let persist_error_to_string = function
  | Write_failed (Not_published error | Published_uncertain error) ->
    Keeper_fs.durable_write_error_to_string error
  | Integrity_failed error -> persist_integrity_error_to_string error
;;

let persist_error_published = function
  | Write_failed (Not_published _) -> false
  | Write_failed (Published_uncertain _) -> true
  | Integrity_failed _ -> false
;;

let save_entry_durable ~ops path (entry : entry) =
  let temp_dir = atomic_staging_dir ~base_path:entry.base_path in
  let saved =
    ops.save_json_durable
      ~ownership_root:entry.base_path
      ~temp_dir
      path
      (entry_record_to_json entry)
    |> Result.map_error (fun error ->
      Write_failed
        (if error.Keeper_fs.renamed
         then Published_uncertain error
         else Not_published error))
  in
  (* A write whose rename may have landed can be read, so it is announced as a
     write that landed. *)
  (match saved with
   | Ok () | Error (Write_failed (Published_uncertain _)) ->
     Keeper_msg_async_broadcast.requests_changed ~keeper_name:entry.keeper_name
   | Error (Write_failed (Not_published _) | Integrity_failed _) -> ());
  saved
;;

let persist_terminal_from_source ~ops ~(entry : entry) ~source_path =
  match terminal_record_path ~base_path:entry.base_path ~request_id:entry.request_id with
  | None -> Error (Integrity_failed Unsafe_request_id)
  | Some terminal_path ->
    if String.equal source_path terminal_path
    then save_entry_durable ~ops source_path entry
    else (
      match
        load_record_at_path
          ~base_path:entry.base_path
          ~request_id:entry.request_id
          terminal_path
      with
      | Found terminal_entry when not (is_terminal_status terminal_entry.status) ->
        Error (Integrity_failed Terminal_partition_nonterminal)
      | Found terminal_entry ->
        if same_entry_record terminal_entry entry
        then (
          (* See lossless namespace protocol: observed cleanup failure is retried. *)
          ignore (remove_duplicate_source_unlocked ~ops ~entry source_path : bool);
          Ok ())
        else
          Error (Integrity_failed Terminal_conflict)
      | Unreadable reason ->
        Error (Integrity_failed (Terminal_unreadable reason))
      | Absent ->
        (* Lossless namespace protocol: first durably publish the terminal
           destination, then durably remove the active source. A crash
           before destination commit leaves the source authoritative; a crash
           after destination commit may leave both names, and exact lookup gives
           terminal precedence. Never rename the sole source across directories:
           partial parent-directory fsync can otherwise lose both names. *)
        let* () = save_entry_durable ~ops terminal_path entry in
        (* See lossless namespace protocol: observed cleanup failure is retried. *)
        ignore (remove_duplicate_source_unlocked ~ops ~entry source_path : bool);
        Ok ()
      | Rejected rejection ->
        Error (Integrity_failed (Terminal_access_rejected rejection))
    )
;;

let persist_entry_unlocked ~ops ?source_path (entry : entry) =
  match active_record_path ~base_path:entry.base_path ~request_id:entry.request_id with
  | None -> Error (Integrity_failed Unsafe_request_id)
  | Some active_path ->
    if is_terminal_status entry.status
    then (
      let source_path =
        match source_path with
        | Some source_path -> source_path
        | None -> active_path
      in
      persist_terminal_from_source
        ~ops
        ~entry
        ~source_path)
    else save_entry_durable ~ops active_path entry
;;

let with_entry_persistence_transaction (entry : entry) f =
  match Keeper_id.Keeper_name.of_string entry.keeper_name with
  | Error reason -> Error (Integrity_failed (Invalid_keeper_name reason))
  | Ok keeper_name ->
    with_keeper_persistence_lock
      ~base_path:entry.base_path
      ~keeper_name
      f
;;

let persist_entry ~ops ?source_path (entry : entry) =
  with_entry_persistence_transaction entry (fun () ->
    persist_entry_unlocked ~ops ?source_path entry)
;;

let load_record_canonical_located ~base_path ~request_id : located_load_result =
  match
    terminal_record_path ~base_path ~request_id,
    active_record_path ~base_path ~request_id
  with
  | None, _ | _, None -> Located_rejected Invalid_request_id
  | Some terminal_path, Some active_path ->
    (match load_record_at_path ~base_path ~request_id terminal_path with
     | Found terminal_entry when not (is_terminal_status terminal_entry.status) ->
       Located_unreadable
         "terminal partition contains a non-terminal request record"
     | Found terminal_entry ->
       (match load_record_at_path ~base_path ~request_id active_path with
        | Found active_entry when not (same_request_identity active_entry terminal_entry) ->
          Located_unreadable
            "conflicting request identities coexist across persistence partitions"
        | Found active_entry
          when is_terminal_status active_entry.status
               && entry_record_to_json active_entry
                  <> entry_record_to_json terminal_entry ->
          Located_unreadable
            "conflicting terminal request records coexist across persistence partitions"
        | Found _ | Absent -> Located (terminal_entry, Terminal_location)
        | Unreadable reason ->
          Located_unreadable
            (Printf.sprintf
               "terminal request record coexists with an unreadable active record: %s"
               reason)
        | Rejected rejection -> Located_rejected rejection)
     | Unreadable reason -> Located_unreadable reason
     | Rejected rejection -> Located_rejected rejection
     | Absent ->
       (match load_record_at_path ~base_path ~request_id active_path with
      | Found entry -> Located (entry, Active_location)
      | Unreadable reason -> Located_unreadable reason
      | Rejected rejection -> Located_rejected rejection
      | Absent -> Located_absent))
;;

let load_record_canonical ~base_path ~request_id : load_result =
  match load_record_canonical_located ~base_path ~request_id with
  | Located (entry, _) -> Found entry
  | Located_absent -> Absent
  | Located_unreadable reason -> Unreadable reason
  | Located_rejected rejection -> Rejected rejection
;;

let load_record ~base_path ~request_id : load_result =
  match canonical_base_path base_path with
  | Error rejection -> Rejected rejection
  | Ok base_path -> load_record_canonical ~base_path ~request_id
;;

let observe_persist_error ~operation (entry : entry) = function
  | Ok () -> Ok ()
  | Error error ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string FsFailures)
      ~labels:[ "subsystem", "keeper_msg_async"; "operation", operation ]
      ();
    let published = persist_error_published error in
    let reason = persist_error_to_string error in
    Log.Keeper.error
      "keeper_msg_async: %s persist failed request_id=%s path_identity=%s published=%b error=%s"
      operation
      entry.request_id
      entry.base_path
      published
      reason;
    Error error
;;

let request_id_of_record_filename name =
  let suffix = ".json" in
  if String.ends_with ~suffix name
  then Some (String.sub name 0 (String.length name - String.length suffix))
  else None
;;

let active_inventory_record_error ?request_id ~path kind =
  { path; request_id; kind }
;;

let read_active_inventory_record ~base_path ~dir name =
  let path = Filename.concat dir name in
  match request_id_of_record_filename name with
  | None ->
    Error (active_inventory_record_error ~path Invalid_record_name)
  | Some request_id when not (is_safe_request_id request_id) ->
    Error
      (active_inventory_record_error
         ~request_id
         ~path
         Invalid_record_name)
  | Some request_id ->
    (try
       match Unix.lstat path with
       | { Unix.st_kind = Unix.S_REG; _ } ->
         (match load_record_file_at_path ~base_path ~request_id path with
          | Record_file_found
              ({ status = (Queued | Running | Cancelling _); _ } as entry) ->
            Ok entry
          | Record_file_found
              ({ status = (Lost _ | Cancelled _ | Persistence_failed _ | Waiting_for_dependencies _ | Done _); _ }
               as entry) ->
            Error
              (active_inventory_record_error
                 ~request_id
                 ~path
                 (Record_terminal_status entry.status))
          | Record_file_absent ->
            Error
              (active_inventory_record_error
                 ~request_id
                 ~path
                 Record_missing)
          | Record_file_unreadable reason ->
            Error
              (active_inventory_record_error
                 ~request_id
                 ~path
                 (Record_unreadable reason)))
       | { Unix.st_kind =
             (Unix.(S_DIR | S_CHR | S_BLK | S_LNK | S_FIFO | S_SOCK) as st_kind)
         ; _
         } ->
         Error
           (active_inventory_record_error
              ~request_id
              ~path
              (Record_not_regular st_kind))
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | Unix.Unix_error (Unix.ENOENT, _, _) ->
       Error
         (active_inventory_record_error
            ~request_id
            ~path
            Record_missing)
     | exn ->
       Error
         (active_inventory_record_error
            ~request_id
            ~path
            (Record_inspection_failed { reason = Printexc.to_string exn })))
;;

let compare_active_inventory_entry left right =
  let by_submitted_at = Float.compare left.submitted_at right.submitted_at in
  if by_submitted_at <> 0
  then by_submitted_at
  else String.compare left.request_id right.request_id
;;

let compare_active_inventory_record_error
    (left : active_inventory_record_error)
    (right : active_inventory_record_error) =
  let by_path = String.compare left.path right.path in
  if by_path <> 0
  then by_path
  else Option.compare String.compare left.request_id right.request_id
;;

let read_durable_active_inventory ~base_path =
  match canonical_base_path base_path with
  | Error rejection -> Error (Inventory_access_rejected rejection)
  | Ok base_path ->
    let dir = active_request_dir ~base_path in
    (match Fs_compat.inspect_owned_directory_chain ~ownership_root:base_path dir with
     | Error rejection -> Error (Inventory_directory_rejected rejection)
     | Ok Fs_compat.Owned_directory_missing ->
       Ok { entries = []; record_errors = [] }
     | Ok (Fs_compat.Owned_directory _) ->
       (try
          let entries, record_errors =
            Fs_compat.read_dir dir
            |> List.fold_left
                 (fun (entries, record_errors) name ->
                    match read_active_inventory_record ~base_path ~dir name with
                    | Ok entry -> entry :: entries, record_errors
                    | Error error -> entries, error :: record_errors)
                 ([], [])
          in
          Ok
            { entries = List.sort compare_active_inventory_entry entries
            ; record_errors =
                List.sort compare_active_inventory_record_error record_errors
            }
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
          Error
            (Inventory_directory_read_failed
               { path = dir; reason = Printexc.to_string exn })))
;;

let rollback_rejected_record_file_unlocked ~ops ~ownership_root ~keeper_name path =
  let result = ops.remove_file_durable ~ownership_root path in
  (match result with
   | Ok () -> Keeper_msg_async_broadcast.requests_changed ~keeper_name
   | Error error ->
     if error.removed then Keeper_msg_async_broadcast.requests_changed ~keeper_name);
  match result with
  | Ok () -> Ok ()
  | Error error ->
    Log.Keeper.error
      "keeper_msg_async: rejected-record rollback failed path=%s removed=%b error=%s"
      path
      error.removed
      (Keeper_fs.durable_remove_error_to_string error);
    Error error
;;
