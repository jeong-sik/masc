type install_error =
  | Inventory_already_installed of string
  | Inventory_load_failed of
      { keeper_name : string option
      ; detail : string
      }

type lookup_error =
  | Inventory_not_installed of string
  | Owner_not_found of string
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
  ; owners_mu : Eio.Mutex.t
  ; owner_handles : Keeper_owner.t list Atomic.t
  ; stopping : bool Atomic.t
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
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | keeper_name :: rest ->
        (match Keeper_meta_store.read_meta config keeper_name with
         | Error detail ->
           Error (Inventory_load_failed { keeper_name = Some keeper_name; detail })
         | Ok None ->
           Error
             (Inventory_load_failed
                { keeper_name = Some keeper_name
                ; detail = "metadata disappeared during strict owner inventory load"
                })
         | Ok (Some meta) -> loop (meta :: acc) rest)
    in
    loop [] names
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
          Keeper_owner.start
            ~sw:pool.sw
            ~store:(store_for pool meta.name)
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
        (match
           Keeper_owner.start
             ~sw:pool.sw
             ~store:(store_for pool keeper_name)
             ~keeper_name
             ~initial_meta:None
         with
         | Error error -> Error (Owner_initialization_failed error)
         | Ok owner ->
           Hashtbl.add pool.owners keeper_name owner;
           install_owner_projection pool keeper_name owner;
           refresh_owner_handles pool;
           Ok owner))
;;

let install_from_store ~sw config =
  let base_path = pool_key config.Workspace.base_path in
  match load_all config with
  | Error _ as error -> error
  | Ok metas ->
    let pool =
      { config
      ; sw
      ; owners = Hashtbl.create (max 16 (List.length metas))
      ; owners_mu = Eio.Mutex.create ()
      ; owner_handles = Atomic.make []
      ; stopping = Atomic.make false
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
           | Error Inventory_stopping ->
             Error
               (Inventory_load_failed
                  { keeper_name = Some meta.name
                  ; detail = "root switch stopped during owner installation"
                  })
           | Error
               (Inventory_not_installed _ | Owner_not_found _
               | Owner_initialization_failed _) ->
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
      | None -> Error (Owner_not_found keeper_name))
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

let create_meta ~base_path meta =
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
              (match Keeper_owner.apply_meta owner (Keeper_owner_reducer.Create meta) with
               | Error error -> Error (Command_rejected error)
               | Ok committed -> Ok committed)))
;;

let all_projections ~base_path =
  match find_pool base_path with
  | Error _ as error -> error
  | Ok pool ->
    Ok (List.map Keeper_owner.projection (Atomic.get pool.owner_handles))
;;

module For_testing = struct
  let installed_owner_count ~base_path =
    match find_pool base_path with
    | Error _ -> 0
    | Ok pool -> Eio.Mutex.use_ro pool.owners_mu (fun () -> Hashtbl.length pool.owners)
  ;;
end
