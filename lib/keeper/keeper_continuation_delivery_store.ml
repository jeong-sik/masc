type publication =
  | Not_published
  | Published_indeterminate

type error =
  | Invalid_keeper_name of string
  | Invalid_intent_id of string
  | Not_found of string
  | Read_failed of string
  | Decode_failed of string
  | Identity_conflict of string
  | Invalid_state_transition of
      { from_state : string
      ; to_state : string
      }
  | Persistence_failed of
      { publication : publication
      ; detail : string
      }

type persist_outcome =
  | Created
  | Advanced
  | Already_current

type record_failure =
  { path : string
  ; detail : string
  }

type inventory =
  { intents : Keeper_continuation_delivery_intent.t list
  ; record_failures : record_failure list
  }

let ( let* ) = Result.bind

let publication_to_string = function
  | Not_published -> "not_published"
  | Published_indeterminate -> "published_indeterminate"
;;

let error_to_string = function
  | Invalid_keeper_name detail ->
    "invalid continuation delivery store keeper name: " ^ detail
  | Invalid_intent_id detail ->
    "invalid continuation delivery store intent id: " ^ detail
  | Not_found path -> "continuation delivery intent not found: " ^ path
  | Read_failed detail -> "continuation delivery store read failed: " ^ detail
  | Decode_failed detail -> "continuation delivery store decode failed: " ^ detail
  | Identity_conflict detail ->
    "continuation delivery store identity conflict: " ^ detail
  | Invalid_state_transition { from_state; to_state } ->
    Printf.sprintf
      "invalid continuation delivery store state transition: %s -> %s"
      from_state
      to_state
  | Persistence_failed { publication; detail } ->
    Printf.sprintf
      "continuation delivery store persistence failed: publication=%s detail=%s"
      (publication_to_string publication)
      detail
;;

let validate_keeper_name keeper_name =
  Keeper_id.Keeper_name.of_string keeper_name
  |> Result.map (fun _ -> keeper_name)
  |> Result.map_error (fun detail -> Invalid_keeper_name detail)
;;

let canonical_base_path (config : Workspace.config) =
  let normalized =
    Workspace_utils_backend_setup.normalize_base_path config.base_path
  in
  if String.equal normalized ""
  then Error (Read_failed "base_path is empty")
  else
    try Ok (Fs_compat.realpath normalized) with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error (Read_failed (Printexc.to_string exn))
;;

let keeper_root ~base_path keeper_name =
  Filename.concat
    (Filename.concat
       (Common.masc_dir_from_base_path ~base_path)
       Common.keepers_runtime_dirname)
    keeper_name
;;

let active_dir ~base_path keeper_name =
  Filename.concat
    (keeper_root ~base_path keeper_name)
    "continuation_delivery_obligations_v1"
;;

let staging_dir ~base_path keeper_name =
  Filename.concat
    (keeper_root ~base_path keeper_name)
    ".continuation_delivery_obligations_staging_v1"
;;

let record_path ~base_path keeper_name intent_id =
  Filename.concat
    (active_dir ~base_path keeper_name)
    (Keeper_continuation_delivery_intent.Intent_id.to_string intent_id)
;;

type operation_lock =
  { mutex : Eio.Mutex.t
  ; mutable users : int
  }

let operation_locks : (string, operation_lock) Hashtbl.t = Hashtbl.create 16
let operation_locks_mutex = Stdlib.Mutex.create ()

let acquire_operation_lock path =
  Stdlib.Mutex.protect operation_locks_mutex (fun () ->
    match Hashtbl.find_opt operation_locks path with
    | Some lock ->
      lock.users <- lock.users + 1;
      lock
    | None ->
      let lock = { mutex = Eio.Mutex.create (); users = 1 } in
      Hashtbl.add operation_locks path lock;
      lock)
;;

let release_operation_lock path lock =
  Stdlib.Mutex.protect operation_locks_mutex (fun () ->
    lock.users <- lock.users - 1;
    if lock.users = 0
    then
      match Hashtbl.find_opt operation_locks path with
      | Some current when current == lock -> Hashtbl.remove operation_locks path
      | Some _ | None -> ())
;;

let with_operation_lock path f =
  let lock = acquire_operation_lock path in
  let release () =
    Eio.Cancel.protect (fun () -> release_operation_lock path lock)
  in
  match Eio.Mutex.use_rw ~protect:true lock.mutex f with
  | value ->
    release ();
    value
  | exception exn ->
    release ();
    raise exn
;;

let load_path_unlocked ~base_path path =
  match Fs_compat.load_owned_regular_file ~ownership_root:base_path path with
  | Error error ->
    Error
      (Read_failed
         (Fs_compat.owned_regular_file_read_error_to_string error))
  | Ok None -> Error (Not_found path)
  | Ok (Some content) ->
    (try
       Yojson.Safe.from_string content
       |> Keeper_continuation_delivery_intent.of_yojson
       |> Result.map_error (fun error ->
         Decode_failed
           (Keeper_continuation_delivery_intent.error_to_string error))
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | Yojson.Json_error detail -> Error (Decode_failed detail)
     | exn -> Error (Decode_failed (Printexc.to_string exn)))
;;

let state_transition_allowed
      (from_state : Keeper_continuation_delivery_intent.state)
      (to_state : Keeper_continuation_delivery_intent.state)
  =
  match from_state, to_state with
  | ( Keeper_continuation_delivery_intent.Pending
    , (Attempting _ | Failed _) ) ->
    true
  | Attempting _, (Delivered _ | Failed _ | Ambiguous _) -> true
  | Pending, (Pending | Delivered _ | Ambiguous _)
  | Attempting _, (Pending | Attempting _)
  | Delivered _, (Pending | Attempting _ | Delivered _ | Failed _ | Ambiguous _)
  | Failed _, (Pending | Attempting _ | Delivered _ | Failed _ | Ambiguous _)
  | Ambiguous _, (Pending | Attempting _ | Delivered _ | Failed _ | Ambiguous _) ->
    false
;;

let persist ~config intent =
  let* keeper_name = validate_keeper_name intent.keeper_name in
  let* base_path = canonical_base_path config in
  let path = record_path ~base_path keeper_name intent.intent_id in
  with_operation_lock path (fun () ->
    match load_path_unlocked ~base_path path with
    | Error (Not_found _) ->
      (match intent.state with
       | Keeper_continuation_delivery_intent.Pending ->
         Keeper_fs.save_json_durable_atomic
           ~ownership_root:base_path
           ~temp_dir:(staging_dir ~base_path keeper_name)
           path
           (Keeper_continuation_delivery_intent.to_yojson intent)
         |> Result.map (fun () -> Created)
         |> Result.map_error (fun error ->
           Persistence_failed
             { publication =
                 (if error.Keeper_fs.renamed
                  then Published_indeterminate
                  else Not_published)
             ; detail = Keeper_fs.durable_write_error_to_string error
             })
       | Keeper_continuation_delivery_intent.(Attempting _ | Delivered _ | Failed _ | Ambiguous _) ->
         Error
           (Invalid_state_transition
              { from_state = "absent"
              ; to_state =
                  Keeper_continuation_delivery_intent.state_label intent.state
              }))
    | Error error -> Error error
    | Ok existing ->
      (match
         Keeper_continuation_delivery_intent.classify_replay
           ~existing
           ~incoming:intent
       with
       | Keeper_continuation_delivery_intent.Distinct_identity ->
         Error
           (Identity_conflict
              "record filename resolved to a different deterministic intent id")
       | Keeper_continuation_delivery_intent.Identity_conflict ->
         Error
           (Identity_conflict
              (Printf.sprintf
                 "intent_id=%s already has different immutable content"
                 (Keeper_continuation_delivery_intent.Intent_id.to_string
                    intent.intent_id)))
       | Keeper_continuation_delivery_intent.Exact_replay ->
         let existing_json =
           Keeper_continuation_delivery_intent.to_yojson existing
         in
         let incoming_json =
           Keeper_continuation_delivery_intent.to_yojson intent
         in
         if Yojson.Safe.equal existing_json incoming_json
         then Ok Already_current
         else if state_transition_allowed existing.state intent.state
         then
           Keeper_fs.save_json_durable_atomic
             ~ownership_root:base_path
             ~temp_dir:(staging_dir ~base_path keeper_name)
             path
             incoming_json
           |> Result.map (fun () -> Advanced)
           |> Result.map_error (fun error ->
             Persistence_failed
               { publication =
                   (if error.Keeper_fs.renamed
                    then Published_indeterminate
                    else Not_published)
               ; detail = Keeper_fs.durable_write_error_to_string error
               })
         else
           Error
             (Invalid_state_transition
                { from_state =
                    Keeper_continuation_delivery_intent.state_label existing.state
                ; to_state =
                    Keeper_continuation_delivery_intent.state_label intent.state
                })))
;;

let load ~config ~keeper_name ~intent_id =
  let* keeper_name = validate_keeper_name keeper_name in
  let* intent_id =
    Keeper_continuation_delivery_intent.Intent_id.of_string
      (Keeper_continuation_delivery_intent.Intent_id.to_string intent_id)
    |> Result.map_error (fun detail -> Invalid_intent_id detail)
  in
  let* base_path = canonical_base_path config in
  let path = record_path ~base_path keeper_name intent_id in
  with_operation_lock path (fun () -> load_path_unlocked ~base_path path)
;;

let inventory ~config ~keeper_name =
  let* keeper_name = validate_keeper_name keeper_name in
  let* base_path = canonical_base_path config in
  let directory = active_dir ~base_path keeper_name in
  match
    Fs_compat.inspect_owned_directory_chain
      ~ownership_root:base_path
      directory
  with
  | Error rejection ->
    Error
      (Read_failed
         (Fs_compat.owned_directory_chain_rejection_to_string rejection))
  | Ok Fs_compat.Owned_directory_missing ->
    Ok { intents = []; record_failures = [] }
  | Ok (Fs_compat.Owned_directory _) ->
    let names =
      Eio_guard.run_in_systhread (fun () ->
        try Ok (Fs_compat.read_dir directory) with
        | exn -> Error (Read_failed (Printexc.to_string exn)))
    in
    Eio_guard.check_if_ready ();
    let* names = names in
    List.fold_left
      (fun (intents, failures) name ->
         Eio_guard.fair_yield ();
         let path = Filename.concat directory name in
         match Keeper_continuation_delivery_intent.Intent_id.of_string name with
         | Error detail ->
           intents, { path; detail = "invalid filename: " ^ detail } :: failures
         | Ok intent_id ->
           (match
              with_operation_lock path (fun () ->
                load_path_unlocked ~base_path path)
            with
            | Ok intent
              when Keeper_continuation_delivery_intent.Intent_id.equal
                     intent.intent_id
                     intent_id ->
              intent :: intents, failures
            | Ok _ ->
              ( intents
              , { path; detail = "filename and record intent identity differ" }
                :: failures )
            | Error error ->
              intents, { path; detail = error_to_string error } :: failures))
      ([], [])
      names
    |> fun (intents, record_failures) ->
    Ok
      { intents = List.rev intents
      ; record_failures = List.rev record_failures
      }
;;

let cleanup_staging_for_startup ~config ~keeper_name =
  let* keeper_name = validate_keeper_name keeper_name in
  let* base_path = canonical_base_path config in
  let staging = staging_dir ~base_path keeper_name in
  let report =
    Eio_guard.run_in_systhread (fun () ->
      Fs_compat.cleanup_atomic_orphans
        ~ownership_root:base_path
        ~base_path:staging
        ~scope:Fs_compat.Directory_only
        ())
  in
  Eio_guard.check_if_ready ();
  Ok report
;;

module For_testing = struct
  let active_directory ~config ~keeper_name =
    let* keeper_name = validate_keeper_name keeper_name in
    canonical_base_path config
    |> Result.map (fun base_path -> active_dir ~base_path keeper_name)
  ;;

  let staging_directory ~config ~keeper_name =
    let* keeper_name = validate_keeper_name keeper_name in
    canonical_base_path config
    |> Result.map (fun base_path -> staging_dir ~base_path keeper_name)
  ;;
end
