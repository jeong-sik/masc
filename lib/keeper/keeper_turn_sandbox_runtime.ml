open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

include Keeper_turn_sandbox_runtime_registry
include Keeper_turn_sandbox_runtime_work_root
include Keeper_turn_sandbox_runtime_boot
include Keeper_turn_sandbox_runtime_record
include Keeper_turn_sandbox_runtime_run_argv
include Keeper_turn_sandbox_runtime_container
include Keeper_turn_sandbox_runtime_work_volume
include Keeper_turn_sandbox_runtime_start_failure
include Keeper_turn_sandbox_runtime_process_bound
include Keeper_turn_sandbox_runtime_remote_endpoint
include Keeper_turn_sandbox_runtime_apple
include Keeper_turn_sandbox_runtime_teardown
include Keeper_turn_sandbox_runtime_start

type apple_endpoint_admission =
  | Diagnostic_read
  | Existing_execution
  | Prepared_execution

type apple_endpoint_observation =
  | Apple_snapshot_only
  | Apple_running_guest of { timeout_sec : float; admission : apple_endpoint_admission }

(* The caller holds the Apple lifecycle scope while observing and constructing
   this endpoint. Snapshot-only construction does not authorize guest effects. *)
let apple_endpoint_of_snapshot_owned ~fs ~scope
      ~(config : Workspace.config) ~(meta : keeper_meta) ~network_mode ~container_root
      ~uid ~gid ~container_name ~observation =
  let open Result.Syntax in
  let backend = Keeper_microvm_backend.Apple_container in
  let container_config_dir = Keeper_github_identity.container_config_dir
      ~container_masc_dir:(Keeper_sandbox_runtime_setup.container_masc_dir ~container_root)
      ~keeper_name:meta.name in
  let* snapshot = Keeper_microvm_github_identity.load ~fs ~coordinator:microvm_lifecycle ~scope
      ~base_path:config.base_path ~keeper_name:meta.name ~backend ~network_mode
    |> Result.map_error Keeper_microvm_github_identity.error_message in
  match snapshot with
  | None -> Error "microvm host credential snapshot is missing"
  | Some snapshot ->
    (* A guest that was read is reached the way it was booted; a snapshot
       alone has only the keeper TOML's choice to go by. *)
    let* delivery = match observation with
      | Apple_snapshot_only ->
        microvm_delivery_for ~base_path:config.base_path ~keeper_name:meta.name
      | Apple_running_guest {timeout_sec; admission} ->
        let* observed = read_apple_guest ~timeout_sec ~container_name
          |> Result.map_error microvm_start_failure_message in
        (match observed with
         | Apple_absent -> Error "microvm guest is not running"
         | Apple_stopped reading ->
           let* () = check_apple_guest_scope ~base_path:config.base_path
               ~keeper_name:meta.name ~network_mode ~container_name reading in
           (* This stopped observation is already under the lifecycle owner.
              Invalidate before returning so every caller, including captured
              reads and turn execution, can prepare a later handoff. *)
           forget_microvm_guest_state ~backend ~container_name;
           Error "microvm guest is not running"
         | Apple_running reading ->
           let* () = check_apple_guest_scope ~base_path:config.base_path
               ~keeper_name:meta.name ~network_mode ~container_name reading in
           let* () = match admission with
             | Diagnostic_read -> Ok ()
             | Existing_execution | Prepared_execution ->
               let* () = microvm_build_cleanup_admission ~backend ~keeper_name:meta.name in
               microvm_build_link_effect_admission ~backend ~keeper_name:meta.name in
           let* () = match admission with
             | Diagnostic_read -> Ok ()
             | Existing_execution ->
               (* This endpoint can start new work without first preparing it.
                  A later ordinary handoff must not clean that new output. *)
               ignore (set_microvm_build_cleanup_state ~backend ~keeper_name:meta.name
                 ~expected:Build_cleanup_available Build_cleanup_skipped_not_sent);
               Ok ()
             | Prepared_execution ->
               microvm_build_links_admission ~base_path:config.base_path ~backend
                 ~keeper_name:meta.name ~container_name in
           match reading with
           | Keeper_microvm_boot_plan.Facts facts ->
             Ok (Keeper_microvm_agent_socket.delivery_of_facts ~base_path:config.base_path
                   ~guest_name:container_name facts)
           | Keeper_microvm_boot_plan.Unreadable detail -> Error detail) in
    let* () = Keeper_microvm_shim_readiness.verify ~fs ~base_path:config.base_path
        ~backend ~guest_name:container_name
      |> Result.map_error Keeper_microvm_shim_readiness.error_message in
    let identity_environment = Keeper_microvm_github_identity.environment snapshot ~container_config_dir in
    let* endpoint = build_microvm_endpoint ~config ~meta ~container_root ~uid ~gid
        ~container_name ~identity_environment ~delivery in
    Ok (endpoint, Keeper_microvm_github_identity.revision snapshot)
;;

(* Endpoint admission reads the host-side identity snapshot and verifies the shared shim.
   It never starts a guest or prepares build output on behalf of attached reads. *)
let microvm_remote_endpoint_of_running_fields
      ~(config : Workspace.config) ~(meta : keeper_meta) ~network_mode ~container_root
      ~uid ~gid ~container_name ~timeout_sec ~admission =
  let open Result.Syntax in
  let* () = microvm_profile_check meta in
  let* backend = microvm_backend_of_meta meta in
  let container_config_dir = Keeper_github_identity.container_config_dir
      ~container_masc_dir:(Keeper_sandbox_runtime_setup.container_masc_dir ~container_root)
      ~keeper_name:meta.name in
  let build identity_environment =
    let* () = verify_microvm_shim ~base_path:config.base_path
        ~backend ~guest_name:container_name
      |> Result.map_error Keeper_microvm_shim_readiness.error_message in
    (* Only Apple publishes a guest socket; the TOML refuses the agent elsewhere. *)
    build_microvm_endpoint ~config ~meta ~container_root ~uid ~gid ~container_name ~identity_environment
      ~delivery:Keeper_types_profile_sandbox.Exec_per_request in
  match backend with
  | Keeper_microvm_backend.Apple_container ->
    with_apple_lifecycle_scope ~keeper_name:meta.name
      ~unavailable:(microvm_start_failure_message Runtime_context_unavailable)
      (fun ~fs ~scope ->
        apple_endpoint_of_snapshot_owned ~fs ~scope ~config ~meta ~network_mode ~container_root
          ~uid ~gid ~container_name ~observation:(Apple_running_guest {timeout_sec; admission})
        |> Result.map fst)
  | Keeper_microvm_backend.Nerdctl_kata | Keeper_microvm_backend.Microsandbox ->
    build (Keeper_github_identity.microvm_git_credential_env
      ~config ~keeper_name:meta.name ~container_config_dir)
;;

let microvm_remote_endpoint_of_running_with_timeout ?timeout_sec ?(admission = Existing_execution) (t : t) ~container_name =
  let timeout_sec = match timeout_sec with
    | Some timeout_sec -> timeout_sec
    | None -> Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Io () in
  microvm_remote_endpoint_of_running_fields
    ~config:t.config
    ~meta:t.meta
    ~network_mode:t.network_mode
    ~container_root:t.container_root
    ~uid:t.uid
    ~gid:t.gid
    ~container_name
    ~timeout_sec
    ~admission
;;

let microvm_remote_endpoint_of_running (t : t) ~container_name =
  microvm_remote_endpoint_of_running_with_timeout t ~container_name
;;

(* Apple preparation belongs to the canonical Keeper owner, including a
   retry after an incomplete first handoff. Attached readers never run it. *)
let microvm_remote_endpoint ?timeout_sec (t : t) =
  match ensure_started ?timeout_sec t with
  | Error _ as err -> err
  | Ok container_name ->
    let root =
      Result.bind (microvm_backend_of t) (fun backend ->
        let prepared = match backend with
          | Keeper_microvm_backend.Apple_container ->
            Result.is_ok (microvm_build_links_admission ~base_path:t.config.base_path
              ~backend ~keeper_name:t.meta.name ~container_name)
          | Keeper_microvm_backend.Nerdctl_kata | Keeper_microvm_backend.Microsandbox ->
            microvm_work_root_ready ~base_path:t.config.base_path ~backend ~container_name in
        if prepared
        then Ok ()
        else match backend with
          | Keeper_microvm_backend.Apple_container ->
            start_microvm_container ?timeout_sec t
            |> Result.map (fun _ -> ())
            |> Result.map_error github_identity_preparation_error_message
          | (Keeper_microvm_backend.Nerdctl_kata | Keeper_microvm_backend.Microsandbox) as backend ->
            match ensure_microvm_keeper_work_root ?timeout_sec t ~backend ~container_name with
            | Ok () ->
              mark_microvm_work_root_ready ~base_path:t.config.base_path ~backend ~container_name;
              Ok ()
            | Error _ as err -> err)
    in
    (match root with
     | Error _ as err -> err
     | Ok () -> microvm_remote_endpoint_of_running_with_timeout ?timeout_sec ~admission:Prepared_execution t ~container_name)
;;

(* Reading a keeper's tree needs the guest, not the turn that happens to be
   using it. The guest name is a function of the keeper and the base path,
   and the guest is keeper-lifetime, so a caller holding no lifecycle
   authority can still name and reach one that is up. Endpoint admission
   validates the host-side identity snapshot under a Keeper owner and verifies the
   shared shim. It never calls [ensure_started]. Booting on behalf of a reader
   would spend a VM start, write the identity snapshot and make the work
   root -- effects that belong to the keeper's own turn.

   Apple observes the running guest's scope before returning an endpoint. This
   is not a fence against a replacement after the observation. Other backends
   still rely on [container exec] and [microvm_guest_absence_reason]. *)
let microvm_attached_endpoint ?timeout_sec ~(config : Workspace.config) ~(meta : keeper_meta) () =
  let container_name =
    microvm_container_name
      ~config
      ~keeper_name:meta.name
      ~network_mode:meta.network_mode
  in
  microvm_remote_endpoint_of_running_fields
    ~config
    ~meta
    ~network_mode:meta.network_mode
    ~container_root:(container_root_of_meta meta)
    ~uid:(Unix.getuid ())
    ~gid:(Unix.getgid ())
    ~container_name
    ~timeout_sec:(Option.value timeout_sec
      ~default:(Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Io ()))
    ~admission:Diagnostic_read
;;

let with_apple_endpoint_observation ~(config : Workspace.config) ~(meta : keeper_meta) ~observation use =
  let open Result.Syntax in
  let* () = microvm_profile_check meta in
  let* backend = microvm_backend_of_meta meta in
  match backend with
  | Keeper_microvm_backend.Nerdctl_kata | Keeper_microvm_backend.Microsandbox ->
    Error "captured Apple authority requires the Apple microVM backend"
  | Keeper_microvm_backend.Apple_container ->
    let network_mode = meta.network_mode in
    let container_name = microvm_container_name ~config ~keeper_name:meta.name ~network_mode in
    with_apple_lifecycle_scope ~keeper_name:meta.name
      ~unavailable:(microvm_start_failure_message Runtime_context_unavailable)
      (fun ~fs ~scope ->
        let* endpoint, revision = apple_endpoint_of_snapshot_owned ~fs ~scope ~config ~meta
            ~network_mode ~container_root:(container_root_of_meta meta) ~uid:(Unix.getuid ())
            ~gid:(Unix.getgid ()) ~container_name ~observation in
        use ~revision endpoint)
;;

let with_apple_snapshot_endpoint ~(config : Workspace.config) ~(meta : keeper_meta) use =
  with_apple_endpoint_observation ~config ~meta ~observation:Apple_snapshot_only use
;;

let with_apple_attached_endpoint ?timeout_sec ~(config : Workspace.config) ~(meta : keeper_meta) use =
  let timeout_sec = Option.value timeout_sec
      ~default:(Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Io ()) in
  with_apple_endpoint_observation ~config ~meta
    ~observation:(Apple_running_guest {timeout_sec; admission=Diagnostic_read}) use
;;

(* [Some reason] when the guest is not running, so a caller can replace a raw
   exec failure with the fact behind it; [None] when the guest is up or the
   probe itself could not answer, leaving the caller's own error in place. *)
let microvm_guest_absence_reason ?timeout_sec ~(config : Workspace.config)
      ~(meta : keeper_meta) () =
  if meta.sandbox_profile <> Keeper_types_profile_sandbox.Micro_vm
  then None
  else
    let container_name =
      microvm_container_name
        ~config
        ~keeper_name:meta.name
        ~network_mode:meta.network_mode
    in
    (* No recorded runtime means nothing here can state a fact about the
       guest, so the caller's own error stands rather than a probe run
       against a runtime the keeper never named. *)
    match meta.microvm_backend with
    | None -> None
    | Some backend ->
    let observe () =
      let not_running = match backend with
        | Keeper_microvm_backend.Apple_container ->
          let timeout_sec = Option.value timeout_sec
              ~default:(Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Io ()) in
          (match read_apple_guest ~timeout_sec ~container_name with
           | Ok Apple_absent -> true
           | Ok (Apple_stopped reading) ->
             Result.is_ok (check_apple_guest_scope ~base_path:config.base_path
               ~keeper_name:meta.name ~network_mode:meta.network_mode ~container_name reading)
           | Ok (Apple_running _) | Error _ -> false)
        | Keeper_microvm_backend.Nerdctl_kata | Keeper_microvm_backend.Microsandbox ->
          (match probe_microvm_container_state ?timeout_sec ~backend container_name with
           | Ok (Keeper_sandbox_runtime.Docker_container_stopped
                | Keeper_sandbox_runtime.Docker_container_absent) -> true
           | Ok Keeper_sandbox_runtime.Docker_container_running | Error _ -> false) in
      if not not_running then None
      else (
        forget_microvm_work_root ~backend ~container_name;
        Keeper_microvm_shim_readiness.forget ~backend ~guest_name:container_name;
        Some
          (Printf.sprintf
             "microvm_guest_not_running: keeper %s's guest %s is not running; a read \
              attaches to a running guest and never boots one"
             meta.name container_name))
    in
    (* Apple handoff uses this same owner. Never let an earlier failed read
       invalidate a newer handoff after the owner has been released. *)
    match backend, Fs_compat.execution_context () with
    | Keeper_microvm_backend.Apple_container, Fs_compat.Non_eio -> None
    | Keeper_microvm_backend.Apple_container, Fs_compat.Eio_fiber
    | (Keeper_microvm_backend.Nerdctl_kata | Keeper_microvm_backend.Microsandbox),
      (Fs_compat.Eio_fiber | Fs_compat.Non_eio) ->
      with_microvm_lifecycle_lock ~keeper_name:meta.name ~operation:"absence_probe" observe
;;

let is_microvm_guest_booted ~(config : Workspace.config) ~(meta : keeper_meta) () =
  if meta.sandbox_profile <> Keeper_types_profile_sandbox.Micro_vm
  then false
  else
    let container_name =
      microvm_container_name
        ~config
        ~keeper_name:meta.name
        ~network_mode:meta.network_mode
    in
    match meta.microvm_backend with
    | None -> false
    | Some backend -> microvm_work_root_ready ~base_path:config.base_path ~backend ~container_name
;;

let forget_microvm_guest_booted ~(config : Workspace.config) ~(meta : keeper_meta) () =
  let container_name =
    microvm_container_name
      ~config
      ~keeper_name:meta.name
      ~network_mode:meta.network_mode
  in
  Option.iter (fun backend ->
    forget_microvm_work_root ~backend ~container_name;
    Keeper_microvm_shim_readiness.forget ~backend ~guest_name:container_name)
    meta.microvm_backend
;;

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

(* The argv [run_exec_with_status_split_once] runs: the turn-scoped
   container, the same uid, the rewritten paths. *)
let exec_argv ?stdin ?timeout_sec ~validate_cached_container (t : t) ~cwd ~command_argv =
  let open Result.Syntax in
  let* () = docker_exec_only t in
  let* container_cwd = container_path_of_host t ~host_path:cwd in
  let* container_name =
    ensure_started ~validate_running:validate_cached_container ?timeout_sec t
  in
  let command_argv =
    List.map
      (fun arg ->
         let rewritten =
           Keeper_sandbox_runtime.rewrite_host_root_to_container_root
             ~host_root:t.host_root
             ~container_root:t.container_root
             arg
         in
         if String.equal t.raw_host_root t.host_root
         then rewritten
         else
           Keeper_sandbox_runtime.rewrite_host_root_to_container_root
             ~host_root:t.raw_host_root
             ~container_root:t.container_root
             rewritten)
      command_argv
  in
  Ok
    (exec_prefix t ~container_cwd ~stdin:(Option.value stdin ~default:false)
     @ (container_name :: command_argv))
;;

let run_exec_with_status_split_once
      ?(validate_cached_container = false)
      ?(stdin_content : string option)
      ?on_stdout_chunk
      ?on_stderr_chunk
      ?timeout_sec
      ?capture_dir
      (t : t)
      ~(cwd : string)
      ~(command_argv : string list)
  =
  match
    exec_argv
      ~stdin:(Option.is_some stdin_content)
      ?timeout_sec
      ~validate_cached_container
      t
      ~cwd
      ~command_argv
  with
  | Error _ as err -> err
  | Ok argv ->
    let run ?output_capture () =
      match stdin_content with
      | Some content ->
        run_argv_with_stdin_and_status_split
          ?timeout_sec
          ?on_stdout_chunk
          ?on_stderr_chunk
          ?output_capture
          ~stdin_content:content
          argv
      | None ->
        run_argv_with_status_split
          ?timeout_sec
          ?on_stdout_chunk
          ?on_stderr_chunk
          ?output_capture
          argv
    in
    let (st, stdout, stderr), files =
      match capture_dir with
      | None -> run (), None
      | Some capture_dir ->
        let result, files =
          Process_output_capture.with_capture ~capture_dir (fun output_capture ->
            run ~output_capture ())
        in
        result, Some files
    in
    Ok (st, stdout, stderr, files)
;;

let run_exec_with_optional_output_files
      ?stdin_content
      ?on_stdout_chunk
      ?on_stderr_chunk
      ?timeout_sec
      ?capture_dir
      (t : t)
      ~(cwd : string)
      ~(command_argv : string list)
  =
  let has_output_callback =
    Option.is_some on_stdout_chunk || Option.is_some on_stderr_chunk
  in
  match
    run_exec_with_status_split_once
      ~validate_cached_container:has_output_callback
      ?stdin_content
      ?on_stdout_chunk
      ?on_stderr_chunk
      ?timeout_sec
      ?capture_dir
      t
      ~cwd
      ~command_argv
  with
  | Error _ as err -> err
  | Ok (((Unix.WEXITED 126 | Unix.WEXITED 127) as status), stdout, stderr, _) as failed ->
    (match failed_exec_recovery ?timeout_sec t with
     | Preserve_failed_exec -> failed
     | Restart_failed_exec ->
       set_state t Not_started;
       (match
          run_exec_with_status_split_once
            ?stdin_content
            ?on_stdout_chunk
            ?on_stderr_chunk
            ?timeout_sec
            ?capture_dir
            t
            ~cwd
            ~command_argv
        with
        | Ok _ as ok -> ok
        | Error _ as err -> err)
     | Failed_exec_state_probe_error detail ->
       Error
         (failed_exec_state_probe_error
            ~status
            ~output:(output_for_status ~stdout ~stderr)
            detail))
  | Ok (((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _, _, _) as other) ->
    Ok other
;;

let run_exec_with_status_split
      ?stdin_content ?on_stdout_chunk ?on_stderr_chunk ?timeout_sec
      t ~cwd ~command_argv
  =
  run_exec_with_optional_output_files
    ?stdin_content ?on_stdout_chunk ?on_stderr_chunk ?timeout_sec
    t ~cwd ~command_argv
  |> Result.map (fun (status, stdout, stderr, _) -> status, stdout, stderr)
;;

let run_exec_with_output_files
      ?stdin_content ?on_stdout_chunk ?on_stderr_chunk ?timeout_sec
      ~capture_dir t ~cwd ~command_argv
  =
  run_exec_with_optional_output_files
    ?stdin_content ?on_stdout_chunk ?on_stderr_chunk ?timeout_sec
    ~capture_dir t ~cwd ~command_argv
;;

let run_exec_with_status
      ?stdin_content
      ?on_stdout_chunk
      ?on_stderr_chunk
      ?timeout_sec
      (t : t)
      ~(cwd : string)
      ~(command_argv : string list)
  =
  match
    run_exec_with_status_split
      ?stdin_content
      ?on_stdout_chunk
      ?on_stderr_chunk
      ?timeout_sec
      t
      ~cwd
      ~command_argv
  with
  | Error _ as err -> err
  | Ok (status, stdout, stderr) ->
    Ok (status, output_for_status ~stdout ~stderr)
;;

type exec_pipeline_stage = {
  command_argv : string list;
  cwd : string option;
}

let rewrite_command_argv (t : t) command_argv =
  List.map
    (fun arg ->
      let rewritten =
        Keeper_sandbox_runtime.rewrite_host_root_to_container_root
          ~host_root:t.host_root
          ~container_root:t.container_root
          arg
      in
      if String.equal t.raw_host_root t.host_root
      then rewritten
      else
        Keeper_sandbox_runtime.rewrite_host_root_to_container_root
          ~host_root:t.raw_host_root
          ~container_root:t.container_root
          rewritten)
    command_argv
;;

let docker_exec_pipeline_argv (t : t) ~container_name ~container_cwd command_argv =
  exec_prefix t ~container_cwd ~stdin:true
  @ (container_name :: rewrite_command_argv t command_argv)
;;

let run_exec_pipeline_with_status_once
      ?(validate_cached_container = false)
      ?on_stdout_chunk
      ?on_stderr_chunk
      ?timeout_sec
      (t : t)
      ~(cwd : string)
      ~(stages : exec_pipeline_stage list)
  =
  let open Result.Syntax in
  let* () = docker_exec_only t in
  let rec project_stages projected = function
    | [] -> Ok (List.rev projected)
    | ({ command_argv; cwd = stage_cwd } : exec_pipeline_stage) :: rest ->
      let* container_cwd =
        container_path_of_host t ~host_path:(Option.value stage_cwd ~default:cwd)
      in
      project_stages ((command_argv, container_cwd) :: projected) rest
  in
  let* projected_stages = project_stages [] stages in
  let* container_name =
    ensure_started ~validate_running:validate_cached_container ?timeout_sec t
  in
  let process_stages =
    List.map
      (fun (command_argv, container_cwd) ->
        let argv = docker_exec_pipeline_argv t ~container_name ~container_cwd command_argv in
        Process_eio.plumbed_stage
          ~argv
          ~env:(Some (sandbox_environment ()))
          ~cwd:(Some (Config_dir_resolver.current_working_dir ())))
      projected_stages
  in
  (* These stages carry no file redirect, so the runner's redirect error is
     out of reach here; it is passed on rather than folded into a status. *)
  run_argv_pipeline_with_status_split
    ?timeout_sec
    ?on_stdout_chunk
    ?on_stderr_chunk
    process_stages
;;

let run_exec_pipeline_with_status ?on_stdout_chunk ?on_stderr_chunk ?timeout_sec
    t ~cwd ~stages =
  let has_output_callback =
    Option.is_some on_stdout_chunk || Option.is_some on_stderr_chunk
  in
  match
    run_exec_pipeline_with_status_once
      ~validate_cached_container:has_output_callback
      ?timeout_sec
      t
      ?on_stdout_chunk
      ?on_stderr_chunk
      ~cwd
      ~stages
  with
  | Error _ as err -> err
  | Ok (((Unix.WEXITED 126 | Unix.WEXITED 127) as status), stdout, stderr) as failed ->
    (match failed_exec_recovery ?timeout_sec t with
     | Preserve_failed_exec -> failed
     | Restart_failed_exec ->
       set_state t Not_started;
       (match
          run_exec_pipeline_with_status_once
            ?timeout_sec
            t
            ?on_stdout_chunk
            ?on_stderr_chunk
            ~cwd
            ~stages
        with
        | Ok _ as ok -> ok
        | Error _ as err -> err)
     | Failed_exec_state_probe_error detail ->
       Error
         (failed_exec_state_probe_error
            ~status
            ~output:(output_for_status ~stdout ~stderr)
            detail))
  | Ok (((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _, _) as other) ->
    Ok other
;;

let run_command_with_status
      ?(ok_exit_codes = [ 0 ])
      ~timeout_sec
      (t : t)
      ~(cwd : string)
      ~(command_argv : string list)
      ~(max_bytes : int)
      ()
  =
  match command_argv with
  | [] -> Error "run_command_with_status: command_argv is empty"
  | head_program :: _ ->
    (match run_exec_with_status t ~timeout_sec ~cwd ~command_argv with
     | Error _ as err -> err
     | Ok (st, out) ->
       (match st with
        | Unix.WEXITED code when List.exists (fun ok_code -> ok_code = code) ok_exit_codes
          ->
          let body =
            if String.length out > max_bytes then String.sub out 0 max_bytes else out
          in
          Ok (st, body)
        | Unix.WSIGNALED _ | Unix.WSTOPPED _ | WEXITED _ -> Error (format_docker_exec_error ~head_program ~st ~out)))
;;

let cleanup (t : t) =
  (* Both keeper-lifetime containers -- the microvm guest and the persistent
     Docker container -- outlive the turn: cleanup only drops the handle, so
     the next turn (of this server or a later one) adopts what is still
     running. Removal is the keeper's teardown at shutdown finalization, the
     one point that knows the keeper is gone for good rather than between
     turns. A stopped persistent container is collected by the stale sweep,
     which removes stopped containers of any kind. *)
  match get_state t with
  | Not_started -> ()
  | Running { container_name } ->
    set_state t Not_started;
    ignore container_name
;;

type build_cleanup_report = { cleaned : int; failed : int }

let build_cleanup_report_of_string stdout =
  try
    let open Yojson.Safe.Util in
    let report = Yojson.Safe.from_string stdout in
    match member "skip" report with
    | `String reason -> Error ("Keeper guest cleanup skipped: " ^ reason)
    | `Null ->
      let entries = member "entries" report |> to_list in
      let count action = List.fold_left (fun n entry ->
          if member "action" entry = `String action then n + 1 else n) 0 entries in
      Ok { cleaned = count "cleaned"; failed = count "clean failed" }
    | _ -> Error "invalid Keeper cleanup report"
  with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ ->
    Error "invalid Keeper cleanup report"

type microvm_maintenance_audit_phase = Maintenance_reserved | Maintenance_result

let audit_microvm_maintenance ~(config : Workspace.config) ~(meta : keeper_meta)
    ~phase ~attempt ~outcome ~resolved =
  let phase_name = match phase with
    | Maintenance_reserved -> "reserved"
    | Maintenance_result -> "result" in
  let observation = match attempt.observation with
    | None -> `Null
    | Some (Keeper_sandbox_remote.Execution_unavailable _ as observation) ->
      Keeper_sandbox_remote.execution_observation_to_yojson observation
    | Some (Keeper_sandbox_remote.Execution_observed (receipt, trailer)) ->
      let integer = Option.fold ~none:`Null ~some:(fun n -> `Int n) in
      `Assoc ["status", `String "observed";
        "receipt", Exec_ssh_protocol.execution_receipt_to_yojson receipt;
        "outcome", `Assoc ["exit", integer trailer.exit; "signal", integer trailer.signal;
          "timed_out", `Bool trailer.timed_out;
          "shim_error", Option.fold ~none:`Null ~some:(fun detail -> `String detail) trailer.shim_error]] in
  let result = match outcome with
    | None -> `Null
    | Some (Masc_exec.Sandbox_target.Ran {status; _}) ->
      `Assoc ["kind", `String "payload_result";
        "status", `String (Keeper_sandbox_exec_failure.status_label status)]
    | Some (Masc_exec.Sandbox_target.Transport_failed {failure; _}) ->
      let failure = match failure with
        | Payload_timed_out -> "payload_timed_out"
        | Lane_unavailable -> "lane_unavailable" in
      `Assoc ["kind", `String "transport_failure"; "failure", `String failure] in
  let details = Observability_redact.redact_json_strings (`Assoc
      ["keeper_name", `String meta.name; "operation_id", `String attempt.operation_id;
       "guest_name", `String attempt.container_name; "phase", `String phase_name;
       "execution_observation", observation; "result", result;
       "effect_resolved", `Bool resolved]) in
  try
    Audit_log.log_action config ~agent_id:meta.name
      ~action:(Audit_log.Custom "keeper_microvm_build_maintenance")
      ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
      ~details ~outcome:(match phase, outcome, resolved with
        | Maintenance_reserved, _, _ -> Audit_log.Success
        | Maintenance_result, Some (Masc_exec.Sandbox_target.Ran {status=Unix.WEXITED 0; _}), true ->
          Audit_log.Success
        | Maintenance_result,
          (None | Some (Masc_exec.Sandbox_target.Ran
            {status=(Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _); _}
            | Transport_failed _)), (true | false) ->
          Audit_log.Failure "maintenance did not report success") ();
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Observability_redact.redact_text (Printexc.to_string exn))
;;

(* The caller retains the Keeper lifecycle owner through this attempt.
   Its remote effect outlives that scope unless the runner proves termination. *)
let run_microvm_build_maintenance ~config ~(meta : keeper_meta) ~container_name
    ~endpoint ~timeout_sec ~stdin_content ~argv =
  let backend = Keeper_microvm_backend.Apple_container in
  let attempt = {operation_id=Random_id.uuid_v7 (); container_name; observation=None} in
  let settle ~observation ~resolved =
    ignore (settle_microvm_maintenance ~backend ~keeper_name:meta.name
      ~operation_id:attempt.operation_id ~observation ~resolved) in
  if not (reserve_microvm_maintenance ~backend ~keeper_name:meta.name attempt) then
    Result.bind (microvm_build_cleanup_admission ~backend ~keeper_name:meta.name)
      (fun () -> Error "microvm maintenance reservation changed; retry admission")
  else
    (* No request has been sent at reservation. The runner guarantees its
       finally callback on return or exception, replacing this initial fact
       with its own observation before this attempt is settled. *)
    let observation = ref (Some (Keeper_sandbox_remote.Execution_unavailable
        Keeper_sandbox_remote.Request_not_sent)) and outcome = ref None in
    let finish () =
      let state = match !outcome, !observation with
        | Some result, receipt -> microvm_build_cleanup_outcome result receipt
        | None, Some (Keeper_sandbox_remote.Execution_unavailable Request_not_sent) ->
          Build_cleanup_skipped_not_sent
        | None, (Some (Keeper_sandbox_remote.Execution_observed _
            | Execution_unavailable (Transport_unavailable _ | Peer_receipt_missing
              | Invalid_receipt _ | Shim_refused_without_receipt)) | None) ->
          Build_cleanup_effect_unverified in
      let resolved = match state with
        | Build_cleanup_confirmed | Build_cleanup_finished_incomplete
        | Build_cleanup_skipped_not_sent -> true
        | Build_cleanup_available | Build_cleanup_effect_unverified -> false in
      settle ~observation:!observation ~resolved;
      match audit_microvm_maintenance ~config ~meta ~phase:Maintenance_result
          ~attempt:{attempt with observation= !observation} ~outcome:!outcome ~resolved with
      | Ok () -> ()
      | Error detail -> Log.Keeper.warn ~keeper_name:meta.name
          "microvm maintenance %s result audit failed: %s" attempt.operation_id detail in
    Fun.protect ~finally:(fun () -> Eio.Cancel.protect finish) (fun () ->
      match audit_microvm_maintenance ~config ~meta ~phase:Maintenance_reserved
          ~attempt ~outcome:None ~resolved:false with
      | Error detail -> Error ("microvm maintenance intent audit failed before dispatch: " ^ detail)
      | Ok () ->
        let run = Keeper_sandbox_remote.runner ~timeout_sec
            ~on_receipt:(fun receipt -> observation := Some receipt) endpoint in
        let result = run ~on_stdout_chunk:None ~on_stderr_chunk:None
            ~stdin_content:(Some stdin_content) ~env:[||] ~cwd:None ~argv in
        outcome := Some result;
        Ok (result, !observation))
;;

(* Called only while the Owner holds its exclusive maintenance slot. Attach to
   the recorded guest; never boot, stop, pause, or refresh its credentials. *)
let cleanup_attached_builds ~(config : Workspace.config) ~(meta : keeper_meta)
    ~retention_sec () =
  match meta.sandbox_profile, meta.microvm_backend with
  | Keeper_types_profile_sandbox.Micro_vm, Some Keeper_microvm_backend.Apple_container ->
    with_apple_lifecycle_scope ~keeper_name:meta.name
      ~unavailable:(microvm_start_failure_message Runtime_context_unavailable)
      (fun ~fs ~scope ->
        let open Result.Syntax in
        let backend = Keeper_microvm_backend.Apple_container in
        let* () = microvm_build_cleanup_admission ~backend ~keeper_name:meta.name in
        let container_name = microvm_container_name ~config ~keeper_name:meta.name
            ~network_mode:meta.network_mode in
        let timeout_sec = Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Io () in
        (match probe_microvm_container_state ~timeout_sec ~backend container_name with
         | Ok Keeper_sandbox_runtime.Docker_container_running ->
           (match Embedded_config.read "scripts/keeper-build-cleanup.py" with
            | None -> Error "embedded Keeper cleanup payload missing"
            | Some stdin_content ->
              let root = Keeper_sandbox_microvm.keeper_work_root ~keeper_name:meta.name in
              (match apple_endpoint_of_snapshot_owned ~fs ~scope ~config ~meta
                  ~network_mode:meta.network_mode ~container_root:(container_root_of_meta meta)
                  ~uid:(Unix.getuid ()) ~gid:(Unix.getgid ()) ~container_name
                  ~observation:(Apple_running_guest {timeout_sec; admission=Diagnostic_read}) with
               | Error _ as error -> error
               | Ok (endpoint, _) ->
                 let* outcome, observation = run_microvm_build_maintenance ~config ~meta
                     ~container_name ~endpoint ~timeout_sec ~stdin_content
                     ~argv:["python3"; "-"; "--guest-root"; root;
                            "--build-root"; Keeper_sandbox_microvm.build_volume_guest_root; "--idle-hours";
                            string_of_float (retention_sec /. Masc_time_constants.hour); "--apply"] in
                 match outcome, observation with
                 | Masc_exec.Sandbox_target.Ran { status = Unix.WEXITED 0; stdout; _ },
                   Some (Keeper_sandbox_remote.Execution_observed _) ->
                   Result.map Option.some (build_cleanup_report_of_string stdout)
                 | Masc_exec.Sandbox_target.Transport_failed { reason; _ }, _ ->
                   Error ("Keeper guest cleanup transport failed: " ^ reason)
                 | _, (Some (Keeper_sandbox_remote.Execution_unavailable _) | None) ->
                   Error "Keeper guest cleanup exit receipt missing"
                 | Masc_exec.Sandbox_target.Ran
                     { status =
                         (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _)
                     ; _
                     },
                   Some (Keeper_sandbox_remote.Execution_observed _) ->
                   Error "Keeper guest cleanup command failed"))
         | Ok (Keeper_sandbox_runtime.Docker_container_stopped
              | Keeper_sandbox_runtime.Docker_container_absent) -> Ok None
         | Error detail -> Error detail))
  | (Keeper_types_profile_sandbox.Micro_vm, Some (Keeper_microvm_backend.Microsandbox | Keeper_microvm_backend.Nerdctl_kata))
  | (Keeper_types_profile_sandbox.Micro_vm, None) | ((Docker | Remote_ssh), _) -> Ok None
