type command_result =
  { status : Unix.process_status
  ; output : string
  ; image : string
  ; network_label : string
  ; cwd : string
  }

module type Backend = sig
  val effective_sandbox_profile :
    meta:Keeper_meta_contract.keeper_meta ->
    Keeper_types_profile_sandbox.sandbox_profile * Keeper_types_profile_sandbox.network_mode

  val ensure_runtime :
    timeout_sec:float -> (string list, string) result

  val private_workspace_cwd :
    config:Workspace.config ->
    meta:Keeper_meta_contract.keeper_meta ->
    string ->
    string

  val run_shell_command_with_status :
    config:Workspace.config ->
    meta:Keeper_meta_contract.keeper_meta ->
    cwd:string ->
    timeout_sec:float ->
    cmd:string ->
    network_mode:Keeper_types_profile_sandbox.network_mode ->
    (command_result, string) result

  val run_trusted_shell_command_with_status :
    config:Workspace.config ->
    meta:Keeper_meta_contract.keeper_meta ->
    cwd:string ->
    timeout_sec:float ->
    cmd:string ->
    network_mode:Keeper_types_profile_sandbox.network_mode ->
    (command_result, string) result

  val run_bash :
    turn_sandbox_runtime:Keeper_turn_sandbox_runtime.t option ->
    config:Workspace.config ->
    meta:Keeper_meta_contract.keeper_meta ->
    cwd:string ->
    timeout_sec:float ->
    cmd:string ->
    network_mode:Keeper_types_profile_sandbox.network_mode ->
    string
end

module Make (Backend : Backend) = struct
  let effective_sandbox_profile = Backend.effective_sandbox_profile
  let ensure_runtime = Backend.ensure_runtime
  let private_workspace_cwd = Backend.private_workspace_cwd
  let run_shell_command_with_status = Backend.run_shell_command_with_status
  let run_trusted_shell_command_with_status =
    Backend.run_trusted_shell_command_with_status
  let run_bash = Backend.run_bash
end

let of_docker_result
    (result : Keeper_sandbox_docker.docker_shell_result)
  : command_result =
  { status = result.status
  ; output = result.output
  ; image = result.image
  ; network_label = result.network_label
  ; cwd = result.cwd
  }

module Docker_backend = struct
  let effective_sandbox_profile = Keeper_sandbox_docker.effective_sandbox_profile
  let ensure_runtime = Keeper_sandbox_docker.ensure_keeper_sandbox_runtime
  let private_workspace_cwd = Keeper_sandbox_docker.docker_private_workspace_cwd

  let run_shell_command_with_status ~config ~meta ~cwd ~timeout_sec ~cmd
      ~network_mode =
    Keeper_sandbox_docker.run_docker_shell_command_with_status
      ~config ~meta ~cwd ~timeout_sec ~cmd ~network_mode
    |> Result.map of_docker_result

  let run_trusted_shell_command_with_status ~config ~meta ~cwd ~timeout_sec ~cmd
      ~network_mode =
    Keeper_sandbox_docker.run_trusted_docker_shell_command_with_status
      ~config ~meta ~cwd ~timeout_sec ~cmd ~network_mode
    |> Result.map of_docker_result

  let run_bash = Keeper_sandbox_docker.run_docker_bash
end

include Make (Docker_backend)

let sandbox_backend_via = "docker"
