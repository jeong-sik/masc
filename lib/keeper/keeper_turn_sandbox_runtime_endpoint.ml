open Keeper_meta_contract
open Keeper_turn_sandbox_runtime_registry
open Keeper_turn_sandbox_runtime_work_root
open Keeper_turn_sandbox_runtime_boot
open Keeper_turn_sandbox_runtime_record
open Keeper_turn_sandbox_runtime_container
open Keeper_turn_sandbox_runtime_work_volume
open Keeper_turn_sandbox_runtime_start_failure
open Keeper_turn_sandbox_runtime_remote_endpoint
open Keeper_turn_sandbox_runtime_apple
open Keeper_turn_sandbox_runtime_start

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
