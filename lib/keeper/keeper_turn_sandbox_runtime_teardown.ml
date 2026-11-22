open Keeper_meta_contract
open Keeper_turn_sandbox_runtime_registry
open Keeper_turn_sandbox_runtime_boot
open Keeper_turn_sandbox_runtime_run_argv
open Keeper_turn_sandbox_runtime_container
open Keeper_turn_sandbox_runtime_work_volume
open Keeper_turn_sandbox_runtime_start_failure
open Keeper_turn_sandbox_runtime_apple

type policy_network_removal =
  | Policy_network_removed
  | Policy_network_already_absent
  | Policy_network_kept_attached

let list_apple_policy_networks_with ~run ~timeout_sec =
  let open Result.Syntax in
  let* list_argv =
    Keeper_sandbox_microvm.policy_network_list_argv_for
      Keeper_microvm_backend.Apple_container
  in
  let status, stdout, stderr = run ~timeout_sec list_argv in
  match status with
  | Unix.WEXITED 0 -> Keeper_sandbox_microvm.policy_network_names_of_listing ~listing:stdout
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
    Error
      (Printf.sprintf
         "policy network list failed (%s): %s"
         (Keeper_sandbox_exec_failure.status_label status)
         (Keeper_sandbox_runtime.docker_failure_output_for_log
            (output_for_status ~stdout ~stderr)))
;;

let remove_unattached_apple_policy_network_with ~run ~timeout_sec ~network_name =
  let open Result.Syntax in
  let* delete_argv =
    Keeper_sandbox_microvm.policy_network_delete_argv_for
      Keeper_microvm_backend.Apple_container
      ~network_name
  in
  let* existing = list_apple_policy_networks_with ~run ~timeout_sec in
  if not (List.mem network_name existing)
  then Ok Policy_network_already_absent
  else (
    let status, stdout, stderr =
      run ~timeout_sec (Keeper_sandbox_microvm.apple_container_list_argv ())
    in
    let* attached =
      match status with
      | Unix.WEXITED 0 ->
        Keeper_sandbox_microvm.attached_policy_networks_of_apple_containers ~listing:stdout
      | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
        Error
          (Printf.sprintf
             "container list failed while checking policy network %s (%s): %s"
             network_name
             (Keeper_sandbox_exec_failure.status_label status)
             (Keeper_sandbox_runtime.docker_failure_output_for_log
                (output_for_status ~stdout ~stderr)))
    in
    if List.mem network_name attached
    then Ok Policy_network_kept_attached
    else (
      let delete_status, delete_stdout, delete_stderr = run ~timeout_sec delete_argv in
      let* after = list_apple_policy_networks_with ~run ~timeout_sec in
      if List.mem network_name after
      then
        Error
          (Printf.sprintf
             "policy network %s remains after delete (%s): %s"
             network_name
             (Keeper_sandbox_exec_failure.status_label delete_status)
             (Keeper_sandbox_runtime.docker_failure_output_for_log
                (output_for_status ~stdout:delete_stdout ~stderr:delete_stderr)))
      else Ok Policy_network_removed))
;;

let sweep_abandoned_apple_policy_networks_with
      ~run
      ~timeout_sec
      ~protected_keeper_names
      ~revalidate
  =
  let protected_networks =
    List.map
      (fun keeper_name -> Keeper_sandbox_microvm.policy_network_name ~keeper_name)
      protected_keeper_names
  in
  match list_apple_policy_networks_with ~run ~timeout_sec with
  | Error detail ->
    { Keeper_sandbox_microvm.removed = []; failed = [ "policy-networks", detail ] }
  | Ok networks ->
    let removed, failed =
      List.fold_left
        (fun (removed, failed) network_name ->
           if List.mem network_name protected_networks
           then removed, failed
           else
             match revalidate () with
             | Error detail -> removed, (network_name, detail) :: failed
             | Ok () ->
               (match
                  remove_unattached_apple_policy_network_with ~run ~timeout_sec ~network_name
                with
                | Ok Policy_network_removed -> network_name :: removed, failed
                | Ok (Policy_network_already_absent | Policy_network_kept_attached) ->
                  removed, failed
                | Error detail -> removed, (network_name, detail) :: failed))
        ([], [])
        networks
    in
    { Keeper_sandbox_microvm.removed = List.rev removed; failed = List.rev failed }
;;

let sweep_abandoned_apple_policy_networks ~base_path ~command_available ~timeout_sec =
  let backend = Keeper_microvm_backend.Apple_container in
  if not (command_available (Keeper_microvm_backend.cli_name backend))
  then None
  else
    let module Declarations = Keeper_microvm_declared_guests in
    Some
      (with_microvm_inventory_lock (fun () ->
         match Declarations.read ~base_path with
         | Error error ->
           { Keeper_sandbox_microvm.removed = []
           ; failed = [ "declarations", Declarations.unavailable_message error ]
           }
         | Ok declarations ->
           (match Declarations.protected_keeper_names declarations with
            | None ->
              { Keeper_sandbox_microvm.removed = []
              ; failed =
                  [ ( "declarations"
                    , "keeper declaration roster has unreadable declarations; preserving policy networks" )
                  ]
              }
            | Some protected_keeper_names ->
              sweep_abandoned_apple_policy_networks_with
                ~run:(fun ~timeout_sec argv -> run_argv_with_status_split ~timeout_sec argv)
                ~timeout_sec
                ~protected_keeper_names
                ~revalidate:(fun () ->
                  Declarations.revalidate declarations
                  |> Result.map_error Declarations.unavailable_message))))
;;

let list_apple_volumes_with ~run ~timeout_sec =
  let status, stdout, stderr =
    run ~timeout_sec (Keeper_sandbox_microvm.apple_volume_list_argv ())
  in
  match status with
  | Unix.WEXITED 0 ->
    (match Yojson.Safe.from_string stdout with
     | exception Yojson.Json_error detail ->
       Error ("microvm_volume_removal_listing_failed: invalid volume listing JSON: " ^ detail)
     | json ->
       Keeper_sandbox_microvm.volume_names_of_json json
       |> Result.map_error (fun detail -> "microvm_volume_removal_listing_failed: " ^ detail))
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
    Error
      (Printf.sprintf
         "microvm_volume_removal_listing_failed: %s: %s"
         (Keeper_sandbox_exec_failure.status_label status)
         (Keeper_sandbox_runtime.docker_failure_output_for_log
            (output_for_status ~stdout ~stderr)))
;;

let remove_apple_keeper_volumes_for_workspace_with
      ~run
      ~timeout_sec
      ~base_path
      ~keeper_name
      ?sandbox_image
      ()
  =
  let open Result.Syntax in
  let* scoped_work =
    Keeper_sandbox_microvm.scoped_work_volume_name ~base_path ~keeper_name
    |> Result.map_error (fun detail -> "microvm_volume_removal_unnamed: " ^ detail)
  in
  let* scoped_build =
    Keeper_sandbox_microvm.scoped_build_volume_name ~base_path ~keeper_name
    |> Result.map_error (fun detail -> "microvm_volume_removal_unnamed: " ^ detail)
  in
  let* legacy_work =
    Keeper_sandbox_microvm.work_volume_name ~keeper_name
    |> Result.map_error (fun detail -> "microvm_volume_removal_unnamed: " ^ detail)
  in
  let* listed = list_apple_volumes_with ~run ~timeout_sec in
  let present_scoped =
    List.filter (fun name -> List.mem name listed) [ scoped_work; scoped_build ]
  in
  let has_legacy_work = List.mem legacy_work listed in
  let scoped_result =
    match present_scoped with
    | [] -> Ok ()
    | volume_names ->
      let workspace_hash = Keeper_sandbox_microvm.base_path_volume_hash ~base_path in
      (match
         Keeper_sandbox_microvm.apple_keeper_workspace_owner_containers
           ~run
           ~timeout_sec
           ~workspace_hash
           ~keeper_name
       with
       | Error detail -> Error detail
       | Ok (_ :: _ as owners) ->
         Log.Keeper.warn ~keeper_name
           "keeper removed; its workspace-scoped Apple volumes are kept: containers still reference the keeper: %s"
           (String.concat ", " owners);
         Ok ()
       | Ok [] ->
         Keeper_sandbox_microvm.remove_apple_volumes_by_names
           ~run
           ~timeout_sec
           ~volume_names)
  in
  let legacy_result =
    if present_scoped <> [] || not has_legacy_work
    then Ok ()
    else
      match sandbox_image with
      | None ->
        Error
          (Printf.sprintf
             "microvm_volume_removal_image_unresolved: keeper %s's volumes \
              cannot be released without an image to run the claims helper; \
              automatic deletion was skipped"
             keeper_name)
      | Some image ->
        let claimant =
          Keeper_sandbox_runtime_setup.normalize_base_path_for_hash base_path
        in
        (match
           Keeper_sandbox_microvm.release_apple_work_volume_claim
             ~run
             ~timeout_sec
             ~keeper_name
             ~volume_name:legacy_work
             ~image
             ~claimant
         with
         | Keeper_sandbox_microvm.Kept_for_claimants claimants ->
           Log.Keeper.warn ~keeper_name
             "keeper removed; its Apple volumes are kept: %d other workspace(s) \
              still claim them: %s"
             (List.length claimants)
             (String.concat ", " claimants);
           Ok ()
         | Keeper_sandbox_microvm.Kept_for_containers owners ->
           Log.Keeper.warn ~keeper_name
             "keeper removed; its claim was released but its Apple volumes are \
              kept: containers still reference the keeper: %s"
             (String.concat ", " owners);
           Ok ()
         | Keeper_sandbox_microvm.Skipped_unverified detail -> Error detail)
  in
  match scoped_result, legacy_result with
  | Ok (), result -> result
  | (Error _ as err), Ok () -> err
  | (Error _ as err), Error detail ->
    Log.Keeper.warn ~keeper_name
      "keeper removed; legacy volume claim release also failed: %s" detail;
    err
;;

let sweep_abandoned_microvm_guests
    ~base_path ~command_available ~timeout_sec ~is_pid_alive ~run_argv =
  let module Inventory = Keeper_microvm_guest_inventory in
  let module Declarations = Keeper_microvm_declared_guests in
  let backend = Keeper_microvm_backend.Apple_container in
  let outcomes, removed = with_microvm_inventory_lock (fun () ->
    let other = sweep_process_bound_microvm_guests ~base_path ~command_available
        ~timeout_sec ~is_pid_alive ~run_argv in
    if not (command_available (Keeper_microvm_backend.cli_name backend)) then other, []
    else
      let removed = ref [] in
      let failed = ref [] in
      let declarations = ref (Declarations.read ~base_path) in
      let inventory = Inventory.read_apple ~timeout_sec in
      (match inventory with
       | Error error ->
         failed := ["inventory", Inventory.error_message error]
       | Ok inventory ->
         (match !declarations with
          | Error error -> failed := ["declarations", Declarations.unavailable_message error]
          | Ok _ -> ());
         List.iter (fun row ->
           match Declarations.select ~base_path ~declarations:!declarations row with
           | Declarations.Preserve _ -> ()
           | Declarations.Delete candidate ->
             let current = match !declarations with
               | Error _ as error -> error
               | Ok observed -> Result.map (fun () -> observed) (Declarations.revalidate observed) in
             declarations := current;
             (match current with
              | Error error -> failed := (candidate.guest_name, Declarations.unavailable_message error) :: !failed
              | Ok _ ->
                let modes = List.filter (fun network_mode ->
                  let name = Keeper_sandbox_container_name.make
                      (Keeper_sandbox_container_name.Micro_vm_persistent
                         {base_path; keeper_name=candidate.keeper_name; network_mode})
                    |> Keeper_sandbox_container_name.to_string in
                  String.equal name candidate.guest_name) Keeper_types_profile_sandbox.all_network_modes in
                let observation = match modes with
                  | [network_mode] ->
                    Result.bind
                      (read_apple_guest ~timeout_sec ~container_name:candidate.guest_name
                       |> Result.map_error microvm_start_failure_message)
                      (fun observation ->
                        Result.map (fun () -> observation)
                          (check_apple_guest_observation ~base_path ~keeper_name:candidate.keeper_name
                             ~network_mode ~container_name:candidate.guest_name observation))
                  | [] | _ :: _ :: _ -> Error "guest name does not identify one network mode" in
                (match observation with
                 | Error detail -> failed := (candidate.guest_name, detail) :: !failed
                 | Ok observation ->
                   (* Inspect may wait on the provider. Recheck the same roster
                      after it returns and before any deletion or cleanup. This
                      is still an observation, not a fence against a writer. *)
                   let current = match !declarations with
                     | Error _ as error -> error
                     | Ok observed -> Result.map (fun () -> observed) (Declarations.revalidate observed) in
                   declarations := current;
                   (match current with
                    | Error error ->
                      failed := (candidate.guest_name, Declarations.unavailable_message error) :: !failed
                    | Ok _ ->
                   (* Delete is an effect attempt. Only a new actual complete
                      inventory can establish its postcondition. An already
                      absent name does not authorize a delete. *)
                   let deletion = match observation with
                     | Apple_absent -> None
                     | Apple_stopped _ | Apple_running _ ->
                       Some (Keeper_microvm_cli_output.read ~timeout_sec
                         ~argv:(Keeper_sandbox_microvm.delete_force_argv_for backend
                                  ~container_name:candidate.guest_name)) in
                   match Inventory.read ~backend ~guest_name:candidate.guest_name ~timeout_sec with
                   | Ok Inventory.Absent ->
                     forget_microvm_guest_state ~backend ~container_name:candidate.guest_name;
                     removed := candidate :: !removed
                   | Ok Inventory.Present ->
                     let detail = match deletion with
                       | None -> "guest appeared after absence observation"
                       | Some (Error error) -> Keeper_microvm_cli_output.error_message error
                       | Some (Ok (status, _)) -> "guest remains after deletion " ^ Keeper_sandbox_exec_failure.status_label status in
                     failed := (candidate.guest_name, detail) :: !failed
                   | Error error -> failed := (candidate.guest_name, Inventory.error_message error) :: !failed))))
           (Inventory.rows inventory));
      let removed = List.rev !removed in
      let outcome : Keeper_sandbox_microvm.sweep_outcome =
        {removed=List.map (fun (candidate : Declarations.candidate) -> candidate.guest_name) removed;
         failed=List.rev !failed} in
      (backend, outcome) :: other, removed) in
  (* Snapshot cleanup takes a fresh Keeper owner after inventory exclusion has
     ended. Reacquiring a Keeper inside that exclusion would deadlock. The store
     independently rereads actual absence; the earlier result is not a token. *)
  let cleanup_failures = List.concat_map (fun (candidate : Declarations.candidate) ->
    List.filter_map (fun network_mode ->
      let name = Keeper_sandbox_container_name.make
          (Keeper_sandbox_container_name.Micro_vm_persistent
             {base_path; keeper_name=candidate.keeper_name; network_mode})
        |> Keeper_sandbox_container_name.to_string in
      if not (String.equal name candidate.guest_name) then None
      else
        let result = with_apple_lifecycle_scope ~keeper_name:candidate.keeper_name
            ~unavailable:(microvm_start_failure_message Runtime_context_unavailable)
            (fun ~fs ~scope ->
              Keeper_microvm_github_identity.remove_if_guest_absent ~fs ~coordinator:microvm_lifecycle
                ~scope ~base_path ~keeper_name:candidate.keeper_name ~backend ~network_mode ~timeout_sec
              |> Result.map_error Keeper_microvm_github_identity.error_message) in
        match result with
        | Ok (Keeper_microvm_github_identity.Removed | Keeper_microvm_github_identity.Already_absent) -> None
        | Error detail -> Some (candidate.guest_name, detail))
      Keeper_types_profile_sandbox.all_network_modes) removed in
  List.map (fun (runtime, (outcome : Keeper_sandbox_microvm.sweep_outcome)) ->
    if runtime = backend then runtime, {outcome with failed=outcome.failed @ cleanup_failures}
    else runtime, outcome) outcomes

(* Shutdown finalization retains the typed backend through registry removal.
   A remote-SSH keeper owns no local container, while Docker and
   microVM names project to different runtimes and must not probe each other. *)
let teardown_keeper_sandbox_by_name
      ?timeout_sec
      ~(config : Workspace.config)
      ~(keeper_name : string)
      ~(backend : Keeper_sandbox.backend)
      ?microvm_backend
      ()
  =
  let helper_timeout_sec =
    match timeout_sec with
    | Some seconds -> seconds
    | None -> Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Io ()
  in
  let timeout_sec =
    Option.value
      timeout_sec
      ~default:
        (Env_config_sandbox.Shell_timeout.timeout_sec
           ~bucket:Env_config_sandbox.Shell_timeout.Cleanup_rm
           ())
  in
  match backend with
  | Keeper_sandbox.Remote_ssh -> Ok ()
  | Keeper_sandbox.Docker ->
    Keeper_sandbox_runtime.remove_persistent_containers
      ~keeper_name
      ~base_path:config.base_path
      ~timeout_sec
      ()
  | Keeper_sandbox.Micro_vm ->
    (* Teardown runs after the registry entry is gone, so there is no meta
       left to read the backend from. The caller passes the one the keeper
       declared; shutdown supplies it from the meta it still holds. Without
       it there is nothing to remove the guest with -- an assumed runtime
       would send `container delete --force` to a guest msb booted and
       report success while it kept running. *)
    (match microvm_backend with
     | None ->
       Error
         (Printf.sprintf
            "microvm_teardown_backend_unresolved: keeper %s's guest cannot be \
             removed without the runtime it was booted on; the caller passes it \
             from the keeper's meta"
            keeper_name)
     | Some microvm_backend ->
       (* Every mode's name, not the current one. The guest name carries the
          network mode so adopt cannot cross modes, and teardown runs after
          the registry entry is gone -- it does not know which mode the guest
          on disk was booted under. Removing only today's name would leave a
          guest from yesterday's mode running with nothing tracking it.

          A name with no guest behind it is not an error: [stop_and_delete]
          is idempotent for an absent guest, which is what makes sweeping the
          whole set cheap. *)
       let guests = List.map (fun network_mode ->
           network_mode, microvm_container_name ~config ~keeper_name ~network_mode)
           Keeper_types_profile_sandbox.all_network_modes in
       let perform stop_guest release_identity =
         let helper_observation = match microvm_backend with
           | Keeper_microvm_backend.Microsandbox | Keeper_microvm_backend.Nerdctl_kata -> Ok ()
           | Keeper_microvm_backend.Apple_container ->
             ensure_apple_volume_helpers_absent ~keeper_name ~timeout_sec:helper_timeout_sec in
         let guest_cleanup = List.fold_left (fun previous (network_mode, guest_name) ->
             let current = Result.bind
                 (stop_guest ~network_mode ~guest_name)
                 (fun () -> release_identity ~network_mode ~guest_name) in
             match previous, current with
             | Ok (), result -> result
             | Error _, Ok () -> previous
             | Error _, Error detail ->
               Log.Keeper.warn "microvm teardown %s additional cleanup failed: %s" keeper_name detail;
               previous) (Ok ()) guests in
         match guest_cleanup, helper_observation with
         | (Error _ as error), Error helper_detail ->
           Log.Keeper.warn
             "microvm teardown %s: guest removal failed; helper observation also failed: %s"
             keeper_name helper_detail;
           error
         | (Error _ as error), Ok () -> error
         | Ok (), helper_observation -> helper_observation in
       match microvm_backend with
       | Keeper_microvm_backend.Apple_container ->
         with_apple_lifecycle_scope ~keeper_name
           ~unavailable:(microvm_start_failure_message Runtime_context_unavailable)
           (fun ~fs ~scope ->
             Result.bind (check_apple_guest_modes ~base_path:config.base_path ~keeper_name ~timeout_sec)
               (fun () ->
                 Result.bind
                   (perform
                      (fun ~network_mode ~guest_name ->
                        stop_owned_apple_guest ~base_path:config.base_path ~keeper_name
                          ~network_mode ~timeout_sec ~container_name:guest_name)
                      (fun ~network_mode ~guest_name:_ ->
                        Keeper_microvm_github_identity.remove_if_guest_absent ~fs ~coordinator:microvm_lifecycle
                          ~scope ~base_path:config.base_path ~keeper_name ~backend:microvm_backend
                          ~network_mode ~timeout_sec
                        |> Result.map (function
                          | Keeper_microvm_github_identity.Removed | Keeper_microvm_github_identity.Already_absent -> ())
                        |> Result.map_error Keeper_microvm_github_identity.error_message))
                   (fun () ->
                     let network_name = Keeper_sandbox_microvm.policy_network_name ~keeper_name in
                     (match
                        remove_unattached_apple_policy_network_with
                          ~run:(fun ~timeout_sec argv -> run_argv_with_status_split ~timeout_sec argv)
                          ~timeout_sec
                          ~network_name
                      with
                      | Ok (Policy_network_removed | Policy_network_already_absent | Policy_network_kept_attached) -> ()
                      | Error detail ->
                        Log.Keeper.warn ~keeper_name
                          "microvm teardown %s: policy network %s cleanup skipped: %s"
                          keeper_name network_name detail);
                     Ok ())))
       | Keeper_microvm_backend.Nerdctl_kata | Keeper_microvm_backend.Microsandbox ->
         with_microvm_lifecycle_lock ~keeper_name ~operation:"teardown" (fun () ->
           perform
             (fun ~network_mode:_ ~guest_name ->
               stop_and_delete_microvm_container ~timeout_sec ~backend:microvm_backend guest_name)
             (fun ~network_mode:_ ~guest_name ->
               release_registered_microvm_identity guest_name; Ok ())))
;;

(* Separate from the teardown because a paused keeper is torn down too and
   must come back to its work volume. Only dissolution calls this, after the
   teardown has removed the guest that held the volumes. *)
let remove_keeper_volumes_by_name
      ?timeout_sec
      ~base_path:(base_path : string)
      ~(keeper_name : string)
      ~(backend : Keeper_sandbox.backend)
      ?microvm_backend
      ?sandbox_image
      ()
  =
  let timeout_sec =
    Option.value
      timeout_sec
      ~default:
        (Env_config_sandbox.Shell_timeout.timeout_sec
           ~bucket:Env_config_sandbox.Shell_timeout.Cleanup_rm
           ())
  in
  match backend with
  | Keeper_sandbox.Docker | Keeper_sandbox.Remote_ssh -> Ok ()
  | Keeper_sandbox.Micro_vm ->
    (match microvm_backend with
     | None ->
       Error
         (Printf.sprintf
            "microvm_volume_removal_backend_unresolved: keeper %s's volumes \
             cannot be removed without the runtime that created them"
            keeper_name)
     | Some Keeper_microvm_backend.Apple_container ->
       with_microvm_inventory_lock (fun () ->
         remove_apple_keeper_volumes_for_workspace_with
           ~run:(fun ~timeout_sec argv -> run_argv_with_status_split ~timeout_sec argv)
           ~timeout_sec
           ~base_path
           ~keeper_name
           ?sandbox_image
           ())
     | Some
         ((Keeper_microvm_backend.Microsandbox | Keeper_microvm_backend.Nerdctl_kata) as
          microvm_backend) ->
       (* Both create the work volume as a host directory, but no removal
          spelling is established for either. Name what is left instead of
          reporting a removal that did not happen. *)
       Error
         (Printf.sprintf
            "microvm_volume_removal_not_established: keeper %s's work volume \
             on %s, if present, was not removed; verify ownership across \
             workspaces before deleting it"
            keeper_name
            (Keeper_microvm_backend.to_string microvm_backend)))
;;

let teardown_keeper_sandbox
      ?timeout_sec
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ()
  =
  teardown_keeper_sandbox_by_name
    ?timeout_sec
    ~config
    ~keeper_name:meta.name
    ~backend:meta.sandbox_profile
    (* The meta is still here, so the runtime the guest was booted on travels
       with the removal. Without it a microsandbox guest would be sent
       [container delete --force] and survive its own teardown. *)
    ?microvm_backend:meta.microvm_backend
    ()
;;
