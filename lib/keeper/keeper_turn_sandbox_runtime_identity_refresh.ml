open Keeper_meta_contract
open Keeper_turn_sandbox_runtime_registry
open Keeper_turn_sandbox_runtime_record
open Keeper_turn_sandbox_runtime_run_argv
open Keeper_turn_sandbox_runtime_container
open Keeper_turn_sandbox_runtime_work_volume
open Keeper_turn_sandbox_runtime_start_failure
open Keeper_turn_sandbox_runtime_apple
open Keeper_turn_sandbox_runtime_start

let retire_current_github_identity_snapshot t =
  update_github_identity_snapshots t (fun snapshots ->
    match snapshots.current with
    | None -> snapshots
    | Some current ->
      { current = None; retired = current :: snapshots.retired })
;;

let stop_container_for_github_identity_refresh ?timeout_sec t =
  if is_microvm t
  then (
    match microvm_backend_of t with
    | Error _ as error -> error
    | Ok Keeper_microvm_backend.Apple_container ->
      let backend = Keeper_microvm_backend.Apple_container in
      let timeout_sec = match timeout_sec with Some seconds -> seconds
        | None -> Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Cleanup_rm () in
      with_apple_lifecycle_scope ~keeper_name:t.meta.name
        ~unavailable:(microvm_start_failure_message Runtime_context_unavailable)
        (fun ~fs ~scope ->
          Result.bind (ensure_apple_volume_helpers_absent ~keeper_name:t.meta.name ~timeout_sec)
            (fun () -> Result.bind
              (stop_owned_apple_guest ~base_path:t.config.base_path ~keeper_name:t.meta.name
                 ~network_mode:t.network_mode ~timeout_sec ~container_name:(keeper_vm_name t))
              (fun () ->
              (* The guest is gone even if later snapshot cleanup cannot
                 settle. Do not retain Running authority for the next call. *)
              set_state t Not_started;
              forget_github_identity_snapshots t;
              Keeper_microvm_github_identity.remove_if_guest_absent ~fs ~coordinator:microvm_lifecycle
                ~scope ~base_path:t.config.base_path ~keeper_name:t.meta.name ~backend
                ~network_mode:t.network_mode ~timeout_sec
              |> Result.map (function
                | Keeper_microvm_github_identity.Removed | Keeper_microvm_github_identity.Already_absent -> ())
              |> Result.map_error Keeper_microvm_github_identity.error_message)))
    | Ok (Keeper_microvm_backend.Nerdctl_kata | Keeper_microvm_backend.Microsandbox) ->
    with_microvm_lifecycle_lock ~keeper_name:t.meta.name ~operation:"identity_refresh" (fun () ->
      let container_name = keeper_vm_name t in
      match
        Result.bind (microvm_backend_of t) (fun backend ->
          stop_and_delete_microvm_container ?timeout_sec ~backend container_name)
      with
      | Error _ as error -> error
      | Ok () ->
        release_registered_microvm_identity container_name;
        forget_github_identity_snapshots t;
        set_state t Not_started;
        Ok ()))
  else
    let retire () =
      set_state t Not_started;
      retire_current_github_identity_snapshot t;
      Ok ()
    in
    match get_state t with
    | Not_started -> retire ()
    | Running { container_name } ->
    let timeout_sec =
      Option.value
        timeout_sec
        ~default:
          (Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Cleanup_rm ())
    in
    let argv =
      Keeper_sandbox_runtime.docker_remove_argv container_name
    in
    let status, output = run_argv_with_status ~timeout_sec argv in
      (match status with
       | Unix.WEXITED 0 -> retire ()
       | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
         (match
            Keeper_sandbox_runtime.probe_container_state_optional
              ~container_name
              ~timeout_sec
              ()
          with
          | Ok Keeper_sandbox_runtime.Docker_container_absent -> retire ()
          | Ok Keeper_sandbox_runtime.Docker_container_running
          | Ok Keeper_sandbox_runtime.Docker_container_stopped
          | Error _ ->
            Error
              (Printf.sprintf
                 "cannot refresh GitHub identity while turn container %s remains: status=%s output=%s"
                 container_name
                 (Keeper_sandbox_exec_failure.status_label status)
                 (Exec_policy.truncate_for_log output))))
;;

let prepare_github_identity_secret_files ?timeout_sec t =
  (* App-identity keepers get a fresh installation token before any lane
     consumes their hosts file; shared-identity keepers pass through
     untouched (RFC keeper-github-apps). A stale token whose mint fails is
     an error — projecting a credential known to be expired is worse. *)
  match
    Keeper_github_app_broker.ensure_fresh
      ~now:(Time_compat.now ())
      ~http_post:Keeper_github_app_broker.default_http_post
      ~config:t.config
      ~keeper_name:t.meta.name
  with
  | Error err -> Error (Identity_unavailable ("github_app_token_refresh_failed: " ^ err))
  | Ok
      ( Keeper_github_app_broker.No_app_identity
      | Keeper_github_app_broker.Fresh _
      | Keeper_github_app_broker.Refreshed _ ) ->
  if is_microvm t
  then (
    (match microvm_backend_of t with
     | Ok Keeper_microvm_backend.Apple_container | Error _ -> ()
     | Ok (Keeper_microvm_backend.Nerdctl_kata | Keeper_microvm_backend.Microsandbox) ->
       ignore (bind_registered_microvm_identity t (keeper_vm_name t)));
    (* The guest's identity is its boot-time snapshot, keeper-lifetime by
       design: only a fresh boot mounts a new one, and a drift from the
       central revision is handled by dropping the handle so the next boot
       rebuilds it. *)
    let ensure_bound () =
      let snapshot_paths () =
        match (Atomic.get t.github_identity_snapshots).current with
        | Some _ -> Ok (github_identity_secret_files t)
        | None -> Error (Identity_unavailable "running container has no GitHub identity snapshot")
      in
      match ensure_started_with_cause ?timeout_sec t with
      | Error _ as error -> error
      | Ok _container_name ->
        (match snapshot_paths () with
         | Ok _ as result -> result
         | Error _ ->
           (* A runtime can retain [Running] across turns while its local
              handle was lost (for example after a failed adoption). Do not
              report a live guest as usable without the credential it was
              booted to mount: force the normal MicroVM start path to
              reconcile the stable guest and registry, which reboots when no
              safe snapshot exists. *)
           set_state t Not_started;
           (match start_container ?timeout_sec t with
            | Error _ as error -> error
            | Ok _ -> snapshot_paths ()))
    in
    match ensure_bound () with
    | Error _ as error -> error
    | Ok paths -> match
      Keeper_github_identity.current_tool_identity_revision
        ~config:t.config
        ~keeper_name:t.meta.name
    with
    | Error detail -> Error (Identity_unavailable detail)
    | Ok central_revision ->
      (match (Atomic.get t.github_identity_snapshots).current with
       | None -> Error (Identity_unavailable "running guest lost its validated identity binding")
       | Some snapshot when String.equal (identity_revision snapshot) central_revision ->
         Ok paths
       | Some _ ->
         (match stop_container_for_github_identity_refresh ?timeout_sec t with
          | Error detail -> Error (Sandbox_unavailable detail)
          | Ok () -> ensure_bound ())))
  else
    (* The persistent Docker container mounts the stable config directory
       read-only, so the token that must stay redacted is the stable
       hosts.yml and binding is [ensure_started] itself -- a central login
       reaches the running container through the mount, with the derived
       gitconfig refreshed at adoption. An unconfigured keeper exposes no
       credential file. *)
    match ensure_started_with_cause ?timeout_sec t with
    | Error _ as error -> error
    | Ok _container_name ->
      (match
         Keeper_github_identity.existing_config_dir
           ~config:t.config
           ~keeper_name:t.meta.name
       with
       | Error detail -> Error (Identity_unavailable detail)
       | Ok None -> Ok []
       | Ok (Some dir) -> Ok [ Filename.concat dir "hosts.yml" ])
;;
