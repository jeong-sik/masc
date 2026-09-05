type store =
  | Keeper_meta
  | Memory_current

let store_to_string = function
  | Keeper_meta -> "keeper_meta"
  | Memory_current -> "memory_current"
;;

type undecodable =
  { store : store
  ; keeper : string
  ; path : string
  ; rejection : string
  }

type examination =
  { readable : int
  ; undecodable : undecodable list
  }

let examine_keeper_meta (config : Workspace.config) examination =
  match Keeper_meta_store.persisted_keeper_names_result config with
  | Error error ->
    Log.Keeper.warn "boot reconcile: keeper meta directory unreadable: %s" error;
    examination
  | Ok names ->
    List.fold_left
      (fun examination keeper ->
         let path = Keeper_types_profile.keeper_meta_path config keeper in
         match Keeper_meta_store.validate_current_meta_file_result path with
         | Ok () -> { examination with readable = examination.readable + 1 }
         | Error
             ( Keeper_meta_store.Unreadable rejection
             | Keeper_meta_store.Not_current rejection ) ->
           { examination with
             undecodable =
               { store = Keeper_meta; keeper; path; rejection } :: examination.undecodable
           })
      examination
      names
;;

let examine_memory_current (config : Workspace.config) examination =
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Workspace.base_path
  in
  List.fold_left
    (fun examination keeper ->
       match
         Keeper_memory_os_current.read_for_keepers_dir ~keepers_dir ~keeper_id:keeper
       with
       | Ok None -> examination
       | Ok (Some _) -> { examination with readable = examination.readable + 1 }
       | Error rejection ->
         let path =
           Keeper_memory_os_current.path_for_keepers_dir ~keepers_dir ~keeper_id:keeper
         in
         { examination with
           undecodable =
             { store = Memory_current; keeper; path; rejection } :: examination.undecodable
         })
    examination
    (Keeper_memory_os_current.list_keeper_ids_for_keepers_dir ~keepers_dir)
;;

let examine config =
  let examination = examine_keeper_meta config { readable = 0; undecodable = [] } in
  let examination = examine_memory_current config examination in
  { examination with undecodable = List.rev examination.undecodable }
;;

let admit ~accept_quarantine examination =
  match examination.undecodable, accept_quarantine with
  | [], (true | false) -> Ok examination
  | _ :: _, true -> Ok examination
  | (_ :: _ as undecodable), false -> Error undecodable
;;

let refusal_to_string undecodable =
  String.concat
    "\n"
    ((Printf.sprintf
        "boot refused: %d store(s) this build cannot read"
        (List.length undecodable)
      :: List.map
           (fun (u : undecodable) ->
              Printf.sprintf
                "  %s keeper=%s path=%s: %s"
                (store_to_string u.store)
                u.keeper
                u.path
                u.rejection)
           undecodable)
     @ [ "strip or repair the files and run `deployment_preflight_helper validate-stores` \
          against this base path, or start with --accept-store-quarantine to move them \
          aside and start those keepers with empty stores"
       ])
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

let move_aside ~now ~keepers_dir (u : undecodable) =
  match u.store with
  | Keeper_meta ->
    let rejected_path = unused_rejected_path ~path:u.path ~now in
    (match Sys.rename u.path rejected_path with
     | () -> Ok rejected_path
     | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
     | exception exn ->
       Error (Printexc.to_string exn ^ " (rejected: " ^ u.rejection ^ ")"))
  | Memory_current ->
    Keeper_memory_os_current.move_aside_for_keepers_dir
      ~keepers_dir
      ~keeper_id:u.keeper
      ~now
      ~rejection:u.rejection
      ()
;;

let quarantine ~now (config : Workspace.config) (examination : examination) =
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Workspace.base_path
  in
  let report =
    List.fold_left
      (fun report (u : undecodable) ->
         match move_aside ~now ~keepers_dir u with
         | Ok rejected_path ->
           quarantine_log
             ~store:u.store
             ~keeper:u.keeper
             ~path:u.path
             ~rejected_path
             ~rejection:u.rejection;
           { report with
             quarantined =
               { store = u.store
               ; keeper = u.keeper
               ; path = u.path
               ; rejected_path
               ; rejection = u.rejection
               }
               :: report.quarantined
           }
         | Error error ->
           { report with
             failed =
               { store = u.store; keeper = u.keeper; path = u.path; error } :: report.failed
           })
      { examined = examination.readable + List.length examination.undecodable
      ; readable = examination.readable
      ; quarantined = []
      ; failed = []
      }
      examination.undecodable
  in
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
