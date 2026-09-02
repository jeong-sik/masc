type store =
  | Keeper_meta
  | Memory_current

let store_to_string = function
  | Keeper_meta -> "keeper_meta"
  | Memory_current -> "memory_current"
;;

type quarantined =
  { store : store
  ; keeper : string
  ; path : string
  ; rejected_path : string
  ; rejection : string
  }

type failure =
  { store : store
  ; keeper : string
  ; path : string
  ; error : string
  }

type report =
  { examined : int
  ; readable : int
  ; quarantined : quarantined list
  ; failed : failure list
  }

let empty = { examined = 0; readable = 0; quarantined = []; failed = [] }

(* [rename] replaces its destination, so a name already taken by an earlier
   quarantine gets a numbered suffix rather than being overwritten. *)
let unused_rejected_path ~path ~now =
  let base = Printf.sprintf "%s.rejected-%.0f" path now in
  if not (Sys.file_exists base)
  then base
  else (
    let rec next attempt =
      let candidate = Printf.sprintf "%s-%d" base attempt in
      if Sys.file_exists candidate then next (attempt + 1) else candidate
    in
    next 2)
;;

let quarantine_log ~store ~keeper ~path ~rejected_path ~rejection =
  Log.Keeper.warn
    ~keeper_name:keeper
    "boot reconcile: %s moved aside path=%s rejected_path=%s rejection=%s"
    (store_to_string store)
    path
    rejected_path
    rejection
;;

let reconcile_keeper_meta ~now (config : Workspace.config) report =
  match Keeper_meta_store.persisted_keeper_names_result config with
  | Error error ->
    Log.Keeper.warn "boot reconcile: keeper meta directory unreadable: %s" error;
    report
  | Ok names ->
    List.fold_left
      (fun report keeper ->
         let path = Keeper_types_profile.keeper_meta_path config keeper in
         match Keeper_meta_store.validate_current_meta_file_result path with
         | Ok () ->
           { report with examined = report.examined + 1; readable = report.readable + 1 }
         | Error rejection ->
           let rejection =
             match rejection with
             | Keeper_meta_store.Unreadable detail
             | Keeper_meta_store.Not_current detail ->
               detail
           in
           let rejected_path = unused_rejected_path ~path ~now in
           (match Sys.rename path rejected_path with
            | () ->
              quarantine_log ~store:Keeper_meta ~keeper ~path ~rejected_path ~rejection;
              { report with
                examined = report.examined + 1
              ; quarantined =
                  { store = Keeper_meta; keeper; path; rejected_path; rejection }
                  :: report.quarantined
              }
            | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
            | exception exn ->
              { report with
                examined = report.examined + 1
              ; failed =
                  { store = Keeper_meta
                  ; keeper
                  ; path
                  ; error = Printexc.to_string exn ^ " (rejected: " ^ rejection ^ ")"
                  }
                  :: report.failed
              }))
      report
      names
;;

let reconcile_memory_current ~now (config : Workspace.config) report =
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Workspace.base_path
  in
  List.fold_left
    (fun report keeper ->
       let path = Keeper_memory_os_current.path_for_keepers_dir ~keepers_dir ~keeper_id:keeper in
       match
         Keeper_memory_os_current.quarantine_undecodable_for_keepers_dir
           ~keepers_dir
           ~keeper_id:keeper
           ~now
           ()
       with
       | Ok Keeper_memory_os_current.Snapshot_absent -> report
       | Ok Keeper_memory_os_current.Snapshot_readable ->
         { report with examined = report.examined + 1; readable = report.readable + 1 }
       | Ok (Keeper_memory_os_current.Snapshot_quarantined { rejection; rejected_path }) ->
         quarantine_log ~store:Memory_current ~keeper ~path ~rejected_path ~rejection;
         { report with
           examined = report.examined + 1
         ; quarantined =
             { store = Memory_current; keeper; path; rejected_path; rejection }
             :: report.quarantined
         }
       | Error error ->
         { report with
           examined = report.examined + 1
         ; failed = { store = Memory_current; keeper; path; error } :: report.failed
         })
    report
    (Keeper_memory_os_current.list_keeper_ids_for_keepers_dir ~keepers_dir)
;;

let reconcile ~now config =
  let report = reconcile_keeper_meta ~now config empty in
  let report = reconcile_memory_current ~now config report in
  { report with
    quarantined = List.rev report.quarantined
  ; failed = List.rev report.failed
  }
;;

let summary report =
  Printf.sprintf
    "boot reconcile: examined=%d readable=%d quarantined=%d failed=%d"
    report.examined
    report.readable
    (List.length report.quarantined)
    (List.length report.failed)
;;
