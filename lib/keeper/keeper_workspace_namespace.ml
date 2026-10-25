let resolve ~(config : Workspace.config)
    ~(meta : Keeper_meta_contract.keeper_meta)
    ~(profile_defaults : Keeper_types_profile.keeper_profile_defaults) =
  match meta.sandbox_profile with
  | Keeper_types_profile_sandbox.Docker ->
    Ok (Keeper_sandbox.container_root meta.name)
  | Micro_vm -> Ok (Keeper_sandbox.host_root_abs_of_meta ~config meta)
  | Remote_ssh ->
    let ( let* ) = Result.bind in
    let* name =
      match profile_defaults.remote_endpoint with
      | Some name when String.trim name <> "" -> Ok (String.trim name)
      | Some _ | None ->
        Error (Printf.sprintf
          "remote_ssh_endpoint_missing: keeper %s has no remote_endpoint" meta.name)
    in
    let* endpoint =
      Keeper_sandbox_ssh.resolve_endpoint_name ~base_path:config.base_path ~name
    in
    Ok (Keeper_sandbox_remote.keeper_root
      ~remote_root:endpoint.remote_root ~keeper_name:meta.name)

let project_input ~(config : Workspace.config)
    ~(meta : Keeper_meta_contract.keeper_meta) path =
  match meta.sandbox_profile with
  | Keeper_types_profile_sandbox.Docker | Micro_vm -> Ok path
  | Remote_ssh ->
    let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
    let normalized = Keeper_remote_path.normalize_remote path in
    let under root = String.equal normalized root
      || String.starts_with ~prefix:(root ^ "/") normalized in
    if Filename.is_relative path || under host_root
       || under (Keeper_alerting_path.normalize_path_for_check_stripped host_root)
    then Ok path
    else
    let ( let* ) = Result.bind in
    let* endpoint = Keeper_sandbox_ssh.resolve_endpoint
      ~base_path:config.base_path ~keeper_name:meta.name in
    let remote_workspace_root = Keeper_sandbox_remote.keeper_root
      ~remote_root:endpoint.remote_root ~keeper_name:meta.name in
    Ok (match Keeper_remote_path.endpoint_to_host ~base_path:config.base_path
      ~remote_workspace_root ~keeper:meta.name path with
      | Some host -> host
      | None -> path)
