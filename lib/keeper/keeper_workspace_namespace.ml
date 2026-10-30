let resolve ~(config : Workspace.config)
    ~(meta : Keeper_meta_contract.keeper_meta)
    ~(profile_defaults : Keeper_types_profile.keeper_profile_defaults) =
  match meta.sandbox_profile with
  | Keeper_types_profile_sandbox.Docker ->
    Ok (Keeper_sandbox.container_root meta.name)
  | Micro_vm -> Ok (Keeper_sandbox.host_root_abs_of_meta ~config meta)
  | Remote_ssh ->
    let open Result.Syntax in
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

let project_input ~remote_workspace_root ~(config : Workspace.config)
    ~(meta : Keeper_meta_contract.keeper_meta) path =
  match meta.sandbox_profile with
  | Keeper_types_profile_sandbox.Docker | Micro_vm -> path
  | Remote_ssh ->
    match Keeper_remote_path.endpoint_to_host ~base_path:config.base_path
      ~remote_workspace_root ~keeper:meta.name path with
    | Some host -> host
    | None -> path

let project_file_args ~remote_workspace_root ~config ~meta = function
  | `Assoc fields -> `Assoc (List.map (fun (key, value) ->
      match key, value with
      | ("path" | "cwd"), `String path -> key, `String
          (project_input ~remote_workspace_root ~config ~meta path)
      | _ -> key, value) fields)
  | json -> json
