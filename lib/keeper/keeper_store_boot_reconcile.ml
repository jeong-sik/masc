module D = Keeper_durable_store

let store_to_string : D.Refusing.t -> string = function
  | D.Refusing.Keeper_meta -> "keeper_meta"
  | D.Refusing.Memory_current -> "memory_current"
  | D.Refusing.Official_client_session -> "official_client_session"

;;

type undecodable =
  { store : D.Refusing.t
  ; keeper : string
  ; path : string
  ; rejection : string
  }

type discovery_failure =
  { store : D.Refusing.t
  ; path : string
  ; rejection : string
  }

type refusal =
  | Undecodable of undecodable
  | Discovery_failed of discovery_failure

type examination =
  { readable : int
  ; undecodable : undecodable list
  ; discovery_failures : discovery_failure list
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
               { store = D.Refusing.Keeper_meta; keeper; path; rejection } :: examination.undecodable
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
             { store = D.Refusing.Memory_current; keeper; path; rejection } :: examination.undecodable
         })
    examination
    (Keeper_memory_os_current.list_keeper_ids_for_keepers_dir ~keepers_dir)
;;

(* The traversal is the store's own, shared with the deploy preflight. A
   binding this build cannot decode stops every turn of its keeper
   (2026-09-26, #38986), so it refuses boot like a keeper meta does. *)
let examine_official_client_session (config : Workspace.config) examination =
  match
    Keeper_official_client_session_store.stored_bindings
      ~base_path:config.Workspace.base_path
  with
  | Error error ->
    { examination with discovery_failures =
        { store = D.Refusing.Official_client_session
        ; path = Common.keepers_runtime_dir_of_base ~base_path:config.Workspace.base_path
        ; rejection = error
        } :: examination.discovery_failures }
  | Ok stored ->
    List.fold_left
      (fun examination (binding : Keeper_official_client_session_store.stored_binding) ->
         match binding.decoded with
         | Ok (_ : Keeper_official_client_session_store.t) ->
           { examination with readable = examination.readable + 1 }
         | Error rejection ->
           { examination with
             undecodable =
               { store = D.Refusing.Official_client_session
               ; keeper = binding.keeper_name
               ; path = binding.path
               ; rejection
               }
               :: examination.undecodable
           })
      examination
      stored
;;

(* RFC-0444 §2.3 row 8. Read only: nothing is created, repaired or moved,
   and [load_source] logs nothing itself, so this is the one line. *)
let examine_goal_store (config : Workspace.config) =
  match Goal_store.load_source config with
  | Goal_store.Unavailable unavailable ->
    Log.Keeper.info "%s" (Goal_store.unavailable_to_string unavailable)
  | Goal_store.Available _ | Goal_store.Uninitialized -> ()
;;

let examine_refusing (store : D.Refusing.t) config examination =
  match store with
  | D.Refusing.Keeper_meta -> examine_keeper_meta config examination
  | D.Refusing.Memory_current -> examine_memory_current config examination
  | D.Refusing.Official_client_session ->
    examine_official_client_session config examination

;;

let examine_reported (store : D.Reported.t) config =
  match store with
  | D.Reported.Goal_store -> examine_goal_store config
;;

(* Each store in the one list goes to the examiner its policy names. A
   [Refuse_boot] store records file rejections or inventory failures; a
   [Degrade_typed] store has no row there to land in; boot does not read a
   [Preflight_only] store. *)
let examine config =
  let examination =
    List.fold_left
      (fun examination id ->
         match D.reader id with
         | D.Refuse_boot (store, _) -> examine_refusing store config examination
         | D.Degrade_typed store ->
           examine_reported store config;
           examination
         | D.Preflight_only _ -> examination)
      { readable = 0; undecodable = []; discovery_failures = [] }
      D.Id.all
  in
  { examination with
    undecodable = List.rev examination.undecodable
  ; discovery_failures = List.rev examination.discovery_failures
  }
;;

let admit ~accept_quarantine examination =
  let discovery = List.map (fun failure -> Discovery_failed failure) examination.discovery_failures in
  let undecodable = List.map (fun row -> Undecodable row) examination.undecodable in
  match discovery, undecodable, accept_quarantine with
  | [], [], (true | false) | [], _ :: _, true -> Ok examination
  | [], _ :: _, false -> Error undecodable
  | _ :: _, _, (true | false) -> Error (discovery @ undecodable)
;;

let refusal_to_string undecodable =
  String.concat
    "\n"
    ((Printf.sprintf
        "boot refused: %d store(s) this build cannot read"
        (List.length undecodable)
      :: List.map
           (function
            | Undecodable u ->
              Printf.sprintf "  %s keeper=%s path=%s: %s"
                (store_to_string u.store) u.keeper u.path u.rejection
            | Discovery_failed failure ->
              Printf.sprintf "  %s inventory path=%s: %s (repair directory access; quarantine cannot recover an unread inventory)"
                (store_to_string failure.store) failure.path failure.rejection)
           undecodable)
     @ [ "strip or repair the files and run `deployment_preflight_helper validate-stores` \
          against this base path; once all inventories are readable, start with \
          --accept-store-quarantine to move rejected files \
          aside and start those keepers with empty stores"
       ])
;;

type quarantined =
  { store : D.Refusing.t
  ; keeper : string
  ; path : string
  ; rejected_path : string
  ; rejection : string
  }

type failure =
  { store : D.Refusing.t
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

let move_aside ~now ~base_path ~keepers_dir (u : undecodable) =
  match u.store with
  | D.Refusing.Keeper_meta ->
    let rejected_path = unused_rejected_path ~path:u.path ~now in
    (match Sys.rename u.path rejected_path with
     | () -> Ok rejected_path
     | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
     | exception exn ->
       Error (Printexc.to_string exn ^ " (rejected: " ^ u.rejection ^ ")"))
  | D.Refusing.Memory_current ->
    Keeper_memory_os_current.move_aside_for_keepers_dir
      ~keepers_dir
      ~keeper_id:u.keeper
      ~now
      ~rejection:u.rejection
      ()
  | D.Refusing.Official_client_session ->
    let rejected_path = unused_rejected_path ~path:u.path ~now in
    Keeper_official_client_session_store.move_aside
      ~base_path
      ~keeper_name:u.keeper
      ~rejected_path
    |> Result.map (fun () -> rejected_path)
    |> Result.map_error (fun error -> error ^ " (rejected: " ^ u.rejection ^ ")")
;;

let quarantine ~now (config : Workspace.config) (examination : examination) =
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Workspace.base_path
  in
  let report =
    List.fold_left
      (fun report (u : undecodable) ->
         match move_aside ~now ~base_path:config.Workspace.base_path ~keepers_dir u with
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
           Log.Keeper.error
             ~keeper_name:u.keeper
             "boot reconcile: %s was not moved aside path=%s error=%s"
             (store_to_string u.store)
             u.path
             error;
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
