type install_error =
  | Inventory_already_installed of string
  | Inventory_load_failed of
      { keeper_name : string option
      ; detail : string
      }

type lookup_error =
  | Inventory_not_installed of string
  | Owner_not_found of string
  | Owner_unavailable of string
  | Owner_initialization_failed of Keeper_owner.error
  | Inventory_stopping

type command_error =
  | Command_lookup_failed of lookup_error
  | Command_lifecycle_reserved of Keeper_lifecycle_reservation.snapshot
  | Command_rejected of Keeper_owner.error

exception Install_failed of install_error

type pool =
  { config : Workspace.config
  ; sw : Eio.Switch.t
  ; owners : (string, Keeper_owner.t) Hashtbl.t
  ; unavailable : (string, string) Hashtbl.t
  ; owners_mu : Eio.Mutex.t
  ; owner_handles : Keeper_owner.t list Atomic.t
  ; stopping : bool Atomic.t
  ; operation_runner : Keeper_owner.operation_runner option
  ; on_turn_slot_released : (keeper_name:string -> unit) option
  }

let pools : (string, pool) Hashtbl.t = Hashtbl.create 4
let pools_mu = Stdlib.Mutex.create ()

let canonical_base_path base_path =
  Keeper_registry_types.canonical_base_path_exn base_path
;;

let pool_key base_path = canonical_base_path base_path

let install_error_to_string = function
  | Inventory_already_installed base_path ->
    Printf.sprintf "Keeper owner inventory already installed for BasePath %s" base_path
  | Inventory_load_failed { keeper_name; detail } ->
    (match keeper_name with
     | None -> "failed to load Keeper owner inventory: " ^ detail
     | Some keeper_name ->
       Printf.sprintf "failed to load Keeper owner %s: %s" keeper_name detail)
;;

let lookup_error_to_string = function
  | Inventory_not_installed base_path ->
    Printf.sprintf "Keeper owner inventory is not installed for BasePath %s" base_path
  | Owner_not_found keeper_name ->
    Printf.sprintf "Keeper owner not found: %s" keeper_name
  | Owner_unavailable keeper_name ->
    Printf.sprintf "Keeper owner unavailable: %s" keeper_name
  | Owner_initialization_failed error ->
    "Keeper owner initialization failed: " ^ Keeper_owner.error_to_string error
  | Inventory_stopping -> "Keeper owner inventory is stopping"
;;

let command_error_to_string = function
  | Command_lookup_failed error -> lookup_error_to_string error
  | Command_lifecycle_reserved owner ->
    "Keeper owner command rejected by lifecycle reservation: "
    ^ Keeper_lifecycle_reservation.snapshot_to_string owner
  | Command_rejected error -> Keeper_owner.error_to_string error
;;

let () =
  Printexc.register_printer (function
    | Install_failed error -> Some (install_error_to_string error)
    | _ -> None)
;;

let load_all config =
  match Keeper_meta_store.keeper_names_result config with
  | Error detail -> Error (Inventory_load_failed { keeper_name = None; detail })
  | Ok names ->
    let reject keeper_name detail =
      Log.Keeper.error
        "keeper_owner: metadata owner unavailable keeper=%s error=%s"
        keeper_name
        detail
    in
    let rec loop metas unavailable = function
      | [] -> Ok (List.rev metas, List.rev unavailable)
      | keeper_name :: rest ->
        (match Keeper_meta_store.read_meta config keeper_name with
         | Error detail ->
           reject keeper_name detail;
           loop metas ((keeper_name, detail) :: unavailable) rest
         | Ok None ->
           (* Absent, including a file the store could not decode (it has
              already said so at WARN). Nothing is fenced: [unavailable] has
              no removal path, and boot materialisation must be able to
              create the declared keeper through [create_meta]. *)
           loop metas unavailable rest
         | Ok (Some meta) when not (String.equal keeper_name meta.name) ->
           let detail =
             Printf.sprintf
               "metadata identity mismatch: path owner=%s payload owner=%s"
               keeper_name
               meta.name
           in
           reject keeper_name detail;
           loop metas ((keeper_name, detail) :: unavailable) rest
         | Ok (Some meta) -> loop (meta :: metas) unavailable rest)
    in
    loop [] [] names
;;

let store_for pool keeper_name : Keeper_owner.store =
  { replace =
      (fun meta ->
         if not (String.equal meta.Keeper_meta_contract.name keeper_name)
         then
           Error
             (Printf.sprintf
                "owner snapshot identity mismatch: expected=%s actual=%s"
                keeper_name
                meta.name)
         else Keeper_meta_store.replace_snapshot pool.config meta)
  ; remove =
      (fun _meta -> Keeper_meta_store.remove_snapshot pool.config ~name:keeper_name)
  }
;;

let operation_store_path pool keeper_name =
  Filename.concat
    (Filename.concat (Workspace.keepers_runtime_dir pool.config) keeper_name)
    Keeper_chat_operation_store.database_file
;;

let prepare_operation_store_path pool keeper_name =
  let path = operation_store_path pool keeper_name in
  let keeper_dir = Filename.dirname path in
  try
    Eio_unix.run_in_systhread ~label:"open Keeper chat operation store" (fun () ->
      (try Unix.mkdir keeper_dir 0o755 with
       | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
      if not (Sys.is_directory keeper_dir)
      then
        Error
          (Keeper_owner.Store_unavailable
             (Printf.sprintf "Keeper runtime path is not a directory: %s" keeper_dir))
      else Ok path)
  with
  | exn ->
    Error
      (Keeper_owner.Store_unavailable
         (Printf.sprintf
            "failed to open Keeper chat operation store %s: %s"
            path
            (Printexc.to_string exn)))
;;

let start_owner pool ~keeper_name ~initial_meta =
  match prepare_operation_store_path pool keeper_name with
  | Error _ as error -> error
  | Ok operation_store_path ->
    Keeper_owner.start
      ~sw:pool.sw
      ~store:(store_for pool keeper_name)
      ~operation_store_path
      (* NDT-OK: wall time is injected once at the Owner persistence boundary. *)
      ~now:Unix.gettimeofday
      ~operation_runner:pool.operation_runner
      ~on_turn_slot_released:
        (Option.map (fun notify () -> notify ~keeper_name) pool.on_turn_slot_released)
      ~keeper_name
      ~initial_meta
;;

let refresh_owner_handles pool =
  let owner_handles =
    Hashtbl.to_seq_values pool.owners
    |> List.of_seq
    |> List.sort (fun left right ->
      let name owner =
        match (Keeper_owner.projection owner).Keeper_owner_reducer.meta with
        | Some meta -> meta.name
        | None -> ""
      in
      String.compare (name left) (name right))
  in
  Atomic.set pool.owner_handles owner_handles
;;

let install_owner_projection pool keeper_name owner =
  Keeper_owner_projection.install
    ~base_path:pool.config.Workspace.base_path
    ~keeper_name
    owner;
  Eio.Switch.on_release pool.sw (fun () ->
    Keeper_owner_projection.remove
      ~base_path:pool.config.base_path
      ~keeper_name
      owner)
;;

let ensure_in_pool pool meta =
  if Atomic.get pool.stopping
  then Error Inventory_stopping
  else
    Eio.Mutex.use_rw ~protect:true pool.owners_mu (fun () ->
      match Hashtbl.find_opt pool.owners meta.Keeper_meta_contract.name with
      | Some owner -> Ok owner
      | None ->
        (match
          start_owner
            pool
            ~keeper_name:meta.name
            ~initial_meta:(Some meta)
         with
         | Error error -> Error (Owner_initialization_failed error)
         | Ok owner ->
           Hashtbl.add pool.owners meta.name owner;
           install_owner_projection pool meta.name owner;
           refresh_owner_handles pool;
           Ok owner))
;;

let ensure_empty_in_pool pool keeper_name =
  if Atomic.get pool.stopping
  then Error Inventory_stopping
  else
    Eio.Mutex.use_rw ~protect:true pool.owners_mu (fun () ->
      match Hashtbl.find_opt pool.owners keeper_name with
      | Some owner -> Ok owner
      | None ->
        (match Hashtbl.find_opt pool.unavailable keeper_name with
         | Some _ -> Error (Owner_unavailable keeper_name)
         | None ->
           (match
              start_owner pool ~keeper_name ~initial_meta:None
            with
            | Error error -> Error (Owner_initialization_failed error)
            | Ok owner ->
              Hashtbl.add pool.owners keeper_name owner;
              install_owner_projection pool keeper_name owner;
              refresh_owner_handles pool;
              Ok owner)))
;;

let install_from_store ~sw ~operation_runner ~on_turn_slot_released config =
  let base_path = pool_key config.Workspace.base_path in
  match load_all config with
  | Error _ as error -> error
  | Ok (metas, unavailable) ->
    let pool =
      { config
      ; sw
      ; owners = Hashtbl.create (max 16 (List.length metas))
      ; unavailable = Hashtbl.of_seq (List.to_seq unavailable)
      ; owners_mu = Eio.Mutex.create ()
      ; owner_handles = Atomic.make []
      ; stopping = Atomic.make false
      ; operation_runner
      ; on_turn_slot_released
      }
    in
    let installed =
      Stdlib.Mutex.protect pools_mu (fun () ->
        if Hashtbl.mem pools base_path
        then false
        else (
          Hashtbl.add pools base_path pool;
          true))
    in
    if not installed
    then Error (Inventory_already_installed base_path)
    else (
      Eio.Switch.on_release sw (fun () ->
        Atomic.set pool.stopping true;
        Stdlib.Mutex.protect pools_mu (fun () ->
          match Hashtbl.find_opt pools base_path with
          | Some current when current == pool -> Hashtbl.remove pools base_path
          | Some _ | None -> ()));
      let rec start_all count = function
        | [] -> Ok count
        | meta :: rest ->
          (match ensure_in_pool pool meta with
           | Ok _ -> start_all (count + 1) rest
           | Error (Owner_initialization_failed error) ->
             let detail = Keeper_owner.error_to_string error in
             Log.Keeper.error
               "keeper_owner: owner unavailable keeper=%s error=%s"
               meta.name
               detail;
             Hashtbl.replace pool.unavailable meta.name detail;
             start_all count rest
           | Error Inventory_stopping ->
             Error
               (Inventory_load_failed
                  { keeper_name = Some meta.name
                  ; detail = "root switch stopped during owner installation"
                  })
           | Error
               (Inventory_not_installed _ | Owner_not_found _ | Owner_unavailable _) ->
             Error
               (Inventory_load_failed
                  { keeper_name = Some meta.name
                  ; detail = "owner inventory installation invariant failed"
                  }))
      in
      start_all 0 metas)
;;

let find_pool base_path =
  let base_path = pool_key base_path in
  Stdlib.Mutex.protect pools_mu (fun () ->
    match Hashtbl.find_opt pools base_path with
    | None -> Error (Inventory_not_installed base_path)
    | Some pool when Atomic.get pool.stopping -> Error Inventory_stopping
    | Some pool -> Ok pool)
;;

let get ~base_path ~keeper_name =
  match find_pool base_path with
  | Error _ as error -> error
  | Ok pool ->
    Eio.Mutex.use_ro pool.owners_mu (fun () ->
      match Hashtbl.find_opt pool.owners keeper_name with
      | Some owner -> Ok owner
      | None ->
        (match Hashtbl.find_opt pool.unavailable keeper_name with
         | Some _ -> Error (Owner_unavailable keeper_name)
         | None -> Error (Owner_not_found keeper_name)))
;;

let operation_projection ~base_path ~keeper_name =
  match get ~base_path ~keeper_name with
  | Error error -> Error error
  | Ok owner -> Ok (Keeper_owner.operation_projection owner)
;;

let interrupt_running_operation ~base_path ~keeper_name operation_id =
  match get ~base_path ~keeper_name with
  | Error error -> Error (Command_lookup_failed error)
  | Ok owner ->
      Keeper_owner.interrupt_running_operation owner operation_id
      |> Result.map_error (fun error -> Command_rejected error)
;;

let wake_operation_drain ~base_path ~keeper_name =
  match get ~base_path ~keeper_name with
  | Error error -> Error (Command_lookup_failed error)
  | Ok owner ->
    Keeper_owner.wake_operation_drain owner
    |> Result.map_error (fun error -> Command_rejected error)
;;

let shutdown_operation_id ~base_path ~keeper_name =
  match get ~base_path ~keeper_name with
  | Error _ as error -> error
  | Ok owner -> Ok (Keeper_owner.shutdown_operation_id owner)
;;

let shutdown_fence_error detail =
  Command_rejected
    (Keeper_owner.Store_unavailable ("shutdown intake fence conflict: " ^ detail))
;;

let begin_shutdown ~base_path ~keeper_name ~operation_id =
  match get ~base_path ~keeper_name with
  | Error error -> Error (Command_lookup_failed error)
  | Ok owner ->
    Eio.Cancel.protect (fun () ->
      match Keeper_owner.begin_shutdown owner ~operation_id with
      | Error error -> Error (Command_rejected error)
      | Ok owner_result ->
        let owner_id =
          match owner_result with
          | Keeper_owner.Shutdown_reserved reservation
          | Keeper_owner.Shutdown_already_reserved reservation ->
            reservation.operation_id
        in
        let fence_result =
          Keeper_shutdown_intake_fence.begin_shutdown
            ~base_path
            ~keeper_name
            ~operation_id:owner_id
        in
        let fence_id =
          match fence_result with
          | Keeper_shutdown_intake_fence.Reserved reservation
          | Keeper_shutdown_intake_fence.Already_reserved reservation ->
            reservation.operation_id
        in
        if Keeper_shutdown_types.Operation_id.equal owner_id fence_id
        then Ok owner_result
        else
          Error
            (shutdown_fence_error
               (Printf.sprintf
                  "keeper=%s owner=%s intake=%s"
                  keeper_name
                  (Keeper_shutdown_types.Operation_id.to_string owner_id)
                  (Keeper_shutdown_types.Operation_id.to_string fence_id))))
;;

let rollback_shutdown ~base_path ~keeper_name ~operation_id =
  match get ~base_path ~keeper_name with
  | Error error -> Error (Command_lookup_failed error)
  | Ok owner ->
    Eio.Cancel.protect (fun () ->
      match
        Keeper_shutdown_intake_fence.rollback_shutdown
          ~base_path
          ~keeper_name
          ~operation_id
      with
      | Keeper_shutdown_intake_fence.Reserved_by_other existing ->
        Error
          (shutdown_fence_error
             (Printf.sprintf
                "keeper=%s rollback_owner=%s intake_owner=%s"
                keeper_name
                (Keeper_shutdown_types.Operation_id.to_string operation_id)
                (Keeper_shutdown_types.Operation_id.to_string existing)))
      | Keeper_shutdown_intake_fence.Rolled_back
      | Keeper_shutdown_intake_fence.Not_reserved ->
        Keeper_owner.rollback_shutdown owner ~operation_id
        |> Result.map_error (fun error -> Command_rejected error))
;;

let restore_shutdown ~base_path ~keeper_name ~operation_id =
  match get ~base_path ~keeper_name with
  | Error error -> Error (Command_lookup_failed error)
  | Ok owner ->
    Eio.Cancel.protect (fun () ->
      match
        Keeper_shutdown_intake_fence.restore_shutdown
          ~base_path
          ~keeper_name
          ~operation_id
      with
      | Keeper_shutdown_intake_fence.Restore_conflict existing ->
        Error
          (shutdown_fence_error
             (Printf.sprintf
                "keeper=%s restore_owner=%s intake_owner=%s"
                keeper_name
                (Keeper_shutdown_types.Operation_id.to_string operation_id)
                (Keeper_shutdown_types.Operation_id.to_string existing)))
      | Keeper_shutdown_intake_fence.Restored
      | Keeper_shutdown_intake_fence.Already_restored ->
        Keeper_owner.restore_shutdown owner ~operation_id
        |> Result.map_error (fun error -> Command_rejected error))
;;

let transition_shutdown
      ~base_path
      ~keeper_name
      ~from_operation_id
      ~to_operation_id
  =
  match get ~base_path ~keeper_name with
  | Error error -> Error (Command_lookup_failed error)
  | Ok owner ->
    Eio.Cancel.protect (fun () ->
      match
        Keeper_owner.transition_shutdown owner ~from_operation_id ~to_operation_id
      with
      | Error error -> Error (Command_rejected error)
      | Ok owner_result ->
        ignore
          (Keeper_shutdown_intake_fence.transition_shutdown
             ~base_path
             ~keeper_name
             ~from_operation_id
             ~to_operation_id
            : Keeper_shutdown_intake_fence.transition_result);
        let owner_id = Keeper_owner.shutdown_operation_id owner in
        let fence_id =
          Keeper_shutdown_intake_fence.shutdown_operation_id
            ~base_path
            ~keeper_name
        in
        let same_id =
          match owner_id, fence_id with
          | None, None -> true
          | Some left, Some right ->
            Keeper_shutdown_types.Operation_id.equal left right
          | None, Some _ | Some _, None -> false
        in
        if same_id
        then Ok owner_result
        else
          Error
            (shutdown_fence_error
               (Printf.sprintf "keeper=%s transition results diverged" keeper_name)))
;;

let await_idle_after_shutdown ~base_path ~keeper_name =
  match get ~base_path ~keeper_name with
  | Error error -> Error (Command_lookup_failed error)
  | Ok owner ->
    (match Keeper_owner.await_idle_after_shutdown owner with
     | Error error -> Error (Command_rejected error)
     | Ok () ->
       Keeper_shutdown_intake_fence.await_idle_after_shutdown
         ~base_path
         ~keeper_name;
       Ok ())
;;

let run_autonomous_if_idle ~base_path ~keeper_name run =
  match get ~base_path ~keeper_name with
  | Error error -> Error (Command_lookup_failed error)
  | Ok owner ->
    Keeper_owner.run_autonomous_if_idle owner run
    |> Result.map_error (fun error -> Command_rejected error)
;;

let run_maintenance_if_idle ~base_path ~keeper_name run =
  match get ~base_path ~keeper_name with
  | Error error -> Error (Command_lookup_failed error)
  | Ok owner ->
    Keeper_owner.run_maintenance_if_idle owner run
    |> Result.map_error (fun error -> Command_rejected error)
;;

let refresh_registry_projection ?lifecycle_token entry meta =
  let result =
    match lifecycle_token with
    | None ->
      Keeper_registry.update_entry_exact entry (fun current -> { current with meta })
    | Some token ->
      Keeper_registry.update_entry_exact_for_lifecycle token entry (fun current ->
        { current with meta })
  in
  match result with
  | Keeper_registry.Exact_updated
  | Keeper_registry.Exact_update_missing
  | Keeper_registry.Exact_update_replaced -> ()
  | Keeper_registry.Exact_update_invalid error ->
    Log.Keeper.warn
      "keeper_owner: committed metadata registry projection rejected keeper=%s error=%s"
      entry.Keeper_registry.name
      (Keeper_registry.registry_entry_validation_error_to_string error)
;;

let apply_meta ?lifecycle_token ~base_path ~keeper_name command =
  let result =
    Keeper_lifecycle_reservation.with_key_lock
      ~base_path
      ~keeper_name
      (fun () ->
         match get ~base_path ~keeper_name with
         | Error error -> Error (Command_lookup_failed error)
         | Ok owner ->
           (match
              Keeper_lifecycle_reservation.authorize
                ?token:lifecycle_token
                ~base_path
                ~keeper_name
                ()
            with
            | Error reservation -> Error (Command_lifecycle_reserved reservation)
            | Ok () ->
              let observed_entry = Keeper_registry.get ~base_path keeper_name in
              (match Keeper_owner.apply_meta owner command with
               | Error error -> Error (Command_rejected error)
               | Ok meta -> Ok (meta, observed_entry))))
  in
  (match result with
   | Ok (Some meta, observed_entry) ->
     Option.iter
       (fun entry -> refresh_registry_projection ?lifecycle_token entry meta)
       observed_entry;
     Ok (Some meta)
   | Ok (None, _) -> Ok None
   | Error _ as error -> error)
;;

let commit_turn_runtime ~base_path ~keeper_name ~before ~after =
  match Keeper_owner_reducer.turn_runtime_delta_of_snapshots ~before ~after with
  | Error error -> Error (Command_rejected (Keeper_owner.Reducer_rejected error))
  | Ok delta ->
    apply_meta
      ~base_path
      ~keeper_name
      (Keeper_owner_reducer.Commit_turn_runtime delta)
;;

let with_owner_command ~base_path ~keeper_name f =
  match get ~base_path ~keeper_name with
  | Error error -> Error (Command_lookup_failed error)
  | Ok owner ->
    f owner |> Result.map_error (fun error -> Command_rejected error)
;;

let exact_operation ~base_path ~keeper_name operation_id =
  with_owner_command ~base_path ~keeper_name (fun owner ->
    Keeper_owner.exact_operation owner operation_id)
;;

let submit_operation ~base_path ~keeper_name ~operation_id ~source ~input =
  with_owner_command ~base_path ~keeper_name (fun owner ->
    Keeper_owner.submit_operation owner ~operation_id ~source ~input)
;;

let list_queued_operations ~base_path ~keeper_name ~after_sequence ~limit =
  with_owner_command ~base_path ~keeper_name (fun owner ->
    Keeper_owner.list_queued_operations owner ~after_sequence ~limit)
;;

let edit_queued_operation ~base_path ~keeper_name ~operation_id ~input =
  with_owner_command ~base_path ~keeper_name (fun owner ->
    Keeper_owner.edit_queued_operation owner ~operation_id ~input)
;;

let move_queued_operation_to_end ~base_path ~keeper_name operation_id =
  with_owner_command ~base_path ~keeper_name (fun owner ->
    Keeper_owner.move_queued_operation_to_end owner operation_id)
;;

let cancel_queued_operation ~base_path ~keeper_name operation_id =
  with_owner_command ~base_path ~keeper_name (fun owner ->
    Keeper_owner.cancel_queued_operation owner operation_id)
;;

let create_meta_unfenced ~base_path meta =
  match find_pool base_path with
  | Error error -> Error (Command_lookup_failed error)
  | Ok pool ->
    Keeper_lifecycle_reservation.with_key_lock
      ~base_path
      ~keeper_name:meta.Keeper_meta_contract.name
      (fun () ->
         match
           Keeper_lifecycle_reservation.authorize
             ~base_path
             ~keeper_name:meta.name
             ()
         with
         | Error reservation -> Error (Command_lifecycle_reserved reservation)
         | Ok () ->
           (match ensure_empty_in_pool pool meta.name with
            | Error error -> Error (Command_lookup_failed error)
            | Ok owner ->
              (match
                 Keeper_owner.apply_meta owner (Keeper_owner_reducer.Create meta)
               with
               | Error error -> Error (Command_rejected error)
               | Ok committed -> Ok committed)))
;;

let create_meta ?intake_token ~base_path meta =
  match intake_token with
  | Some token ->
    if
      Keeper_shutdown_intake_fence.intake_token_matches
        token
        ~base_path
        ~keeper_name:meta.Keeper_meta_contract.name
    then create_meta_unfenced ~base_path meta
    else
      Error
        (shutdown_fence_error
           (Printf.sprintf "keeper=%s create_meta_intake_token_not_live" meta.name))
  | None ->
    (match
       Keeper_shutdown_intake_fence.run_durable_intake_if_open
         ~base_path
         ~keeper_name:meta.Keeper_meta_contract.name
         (fun _intake_token -> create_meta_unfenced ~base_path meta)
     with
     | Keeper_shutdown_intake_fence.Intake_committed result -> result
     | Keeper_shutdown_intake_fence.Intake_shutdown_reserved operation_id ->
       Error
         (shutdown_fence_error
            (Printf.sprintf
               "keeper=%s create_meta_operation=%s"
               meta.name
               (Keeper_shutdown_types.Operation_id.to_string operation_id))))
;;

let all_projections ~base_path =
  match find_pool base_path with
  | Error _ as error -> error
  | Ok pool ->
    Ok (List.map Keeper_owner.projection (Atomic.get pool.owner_handles))
;;

let begin_stopping_all ~base_path =
  let base_path = pool_key base_path in
  match
    Stdlib.Mutex.protect pools_mu (fun () -> Hashtbl.find_opt pools base_path)
  with
  | None -> Error (Inventory_not_installed base_path)
  | Some pool ->
    Atomic.set pool.stopping true;
    let owners = Atomic.get pool.owner_handles in
    let results =
      Eio.Fiber.List.map
        (fun owner -> Keeper_owner.begin_stopping owner)
        owners
    in
    Ok results
;;

module For_testing = struct
  let installed_owner_count ~base_path =
    match find_pool base_path with
    | Error _ -> 0
    | Ok pool -> Eio.Mutex.use_ro pool.owners_mu (fun () -> Hashtbl.length pool.owners)
  ;;
end

(* For [Heap_roots]: the value the diagnostic walks. *)
let heap_root () = Obj.repr pools
