open Keeper_meta_contract
open Keeper_turn_sandbox_runtime_container

let microvm_profile_check (meta : keeper_meta) =
  if meta.sandbox_profile = Keeper_types_profile_sandbox.Micro_vm then Ok ()
  else Error (Printf.sprintf
      "microvm_remote_endpoint_requires_microvm: keeper %s runs sandbox_profile=%s"
      meta.name (Keeper_types_profile_sandbox.sandbox_profile_to_string meta.sandbox_profile))

let build_microvm_endpoint
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~container_root
      ~uid
      ~gid
      ~container_name
      ~identity_environment
      ~delivery
  =
  let open Result.Syntax in
  let* () = microvm_profile_check meta in
    let gh_config_dir =
      Keeper_github_identity.container_config_dir
        ~container_masc_dir:
          (Keeper_sandbox_runtime_setup.container_masc_dir
             ~container_root)
        ~keeper_name:meta.name
    in
    let injected_env =
      Keeper_sandbox_runtime.docker_config_env ~base_path:config.base_path ~container_root
      @ identity_environment
    in
    (* The exec prefix is the declaring runtime's, built here because this is
       where the runtime, the work root and the shim config path are all in
       hand. *)
    Result.bind (microvm_backend_of_meta meta) (fun backend ->
      match (delivery : Keeper_types_profile_sandbox.microvm_delivery), backend with
      | Keeper_types_profile_sandbox.Agent_socket, Keeper_microvm_backend.Apple_container ->
        Ok
          (Keeper_sandbox_remote.of_agent_socket
             ~base_path:config.base_path
             ~keeper_name:meta.name
             ~remote_root:Keeper_sandbox_microvm.work_volume_guest_root
             ~gh_config_dir
             ~injected_env
             ~env_allowlist:Keeper_sandbox_microvm.remote_env_allowlist
             ~connect_timeout_sec:Keeper_sandbox_microvm.remote_connect_timeout_sec
             ~max_concurrent_sessions:Keeper_sandbox_microvm.remote_max_concurrent_sessions
             ~container_name
             ~shim_path:Keeper_sandbox_microvm.shim_guest_path
             ~host_socket:
               (Keeper_microvm_agent_socket.host_path ~base_path:config.base_path
                  ~guest_name:container_name)
             ~expected:{ Keeper_guest_socket.uid; gid })
      | ( Keeper_types_profile_sandbox.Agent_socket
        , (Keeper_microvm_backend.Nerdctl_kata | Keeper_microvm_backend.Microsandbox) ) ->
        Error
          (Printf.sprintf
             "microvm_agent_requires_apple_container: keeper %s has no guest agent \
              on microvm_backend = %S"
             meta.name (Keeper_microvm_backend.to_string backend))
      | ( Keeper_types_profile_sandbox.Exec_per_request
        , ( Keeper_microvm_backend.Apple_container | Keeper_microvm_backend.Nerdctl_kata
          | Keeper_microvm_backend.Microsandbox ) ) ->
      Result.bind
        (Keeper_sandbox_microvm.shim_exec_prefix_for
           ~stdin:true
           backend
           ~container_name
           ~uid
           ~gid
           ~remote_root:Keeper_sandbox_microvm.work_volume_guest_root
           ~shim_config_path:Keeper_sandbox_microvm.shim_config_guest_path)
        (fun prefix ->
          Result.map
            (fun probe_prefix ->
              Keeper_sandbox_remote.of_container_exec
                ~base_path:config.base_path
                ~keeper_name:meta.name
                ~remote_root:Keeper_sandbox_microvm.work_volume_guest_root
                ~gh_config_dir
                ~injected_env
                ~env_allowlist:Keeper_sandbox_microvm.remote_env_allowlist
                ~connect_timeout_sec:Keeper_sandbox_microvm.remote_connect_timeout_sec
                ~max_concurrent_sessions:
                  Keeper_sandbox_microvm.remote_max_concurrent_sessions
                { prefix
                ; probe_prefix = Some probe_prefix
                ; container_name
                ; shim_path = Keeper_sandbox_microvm.shim_guest_path
                })
            (Keeper_sandbox_microvm.shim_exec_prefix_for
               ~stdin:false
               backend
               ~container_name
               ~uid
               ~gid
               ~remote_root:Keeper_sandbox_microvm.work_volume_guest_root
               ~shim_config_path:Keeper_sandbox_microvm.shim_config_guest_path)))
;;
