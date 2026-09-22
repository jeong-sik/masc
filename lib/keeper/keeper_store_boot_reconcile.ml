(* The policy a store gets is carried on its type. The indices are closed
   polymorphic variants rather than abstract types so the checker knows the
   two are distinct and drops the arm a store's index rules out. *)
type refuse_boot = [ `Refuse_boot ]
type degrade_typed = [ `Degrade_typed ]

type _ store =
  | Keeper_meta : refuse_boot store
  | Memory_current : refuse_boot store
  | Goal_store : degrade_typed store

type _ boot_policy =
  | Refuse_boot : refuse_boot boot_policy
  | Degrade_typed : degrade_typed boot_policy

(* RFC-0444 §2.4: the one table. [examine] matches on it, so moving a store
   to the other policy fails to compile until its examiner changes too. *)
let policy : type a. a store -> a boot_policy = function
  | Keeper_meta -> Refuse_boot
  | Memory_current -> Refuse_boot
  | Goal_store -> Degrade_typed
;;

let store_to_string : refuse_boot store -> string = function
  | Keeper_meta -> "keeper_meta"
  | Memory_current -> "memory_current"
;;

type undecodable =
  { store : refuse_boot store
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

(* RFC-0444 §2.3 row 8. Read only: nothing is created, repaired or moved,
   and [load_source] logs nothing itself, so this is the one line. *)
let examine_goal_store (config : Workspace.config) =
  match Goal_store.load_source config with
  | Goal_store.Unavailable unavailable ->
    Log.Keeper.info "%s" (Goal_store.unavailable_to_string unavailable)
  | Goal_store.Available _ | Goal_store.Uninitialized -> ()
;;

(* Each store goes to the examiner its policy names. A [Refuse_boot] store's
   rejections can only land in [undecodable]; the [Degrade_typed] store has
   no row there to land in. *)
let examine config =
  let examination = { readable = 0; undecodable = [] } in
  let examination =
    match policy Keeper_meta with
    | Refuse_boot -> examine_keeper_meta config examination
  in
  let examination =
    match policy Memory_current with
    | Refuse_boot -> examine_memory_current config examination
  in
  (match policy Goal_store with
   | Degrade_typed -> examine_goal_store config);
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
  { store : refuse_boot store
  ; keeper : string
  ; path : string
  ; rejected_path : string
  ; rejection : string
  }

type failure =
  { store : refuse_boot store
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
