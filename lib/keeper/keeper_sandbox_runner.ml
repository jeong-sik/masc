type command_result =
  { status : Unix.process_status
  ; output : string
  ; image : string
  ; network_label : string
  ; cwd : string
  }

type command_trust =
  | User_shell
  | Trusted_tool

type host_command =
  { actor : Masc_exec.Agent_id.t
  ; raw_source : string
  ; summary : string
  ; env : string array option
  ; cwd : string option
  ; argv : string list
  }

type backend_command =
  { route_cwd : string
  ; cwd : unit -> string
  ; command_text : string
  ; network_mode : Keeper_types_profile_sandbox.network_mode
  ; trust : command_trust
  }

type routed_result =
  { status : Unix.process_status
  ; output : string
  ; via : string
  ; backend_error : string option
  }

type route =
  | Host
  | Sandbox_backend

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

let strip_trailing_slashes = Env_config_core.strip_trailing_slashes

let normalize p =
  Keeper_alerting_path.normalize_path_for_check p
  |> strip_trailing_slashes

let in_playground ~config ~meta ~cwd =
  let host_root =
    Keeper_sandbox.host_root_abs_of_meta ~config meta
    |> normalize
  in
  let cwd = normalize cwd in
  String.equal cwd host_root
  || String.starts_with ~prefix:(host_root ^ "/") cwd

let uses_backend ~config:_ ~meta ~cwd:_ =
  match effective_sandbox_profile ~meta with
  | Keeper_types_profile_sandbox.Docker, _ -> true
  | Keeper_types_profile_sandbox.Local, _ -> false

let route_for ~config ~meta ~cwd =
  if uses_backend ~config ~meta ~cwd then Sandbox_backend else Host

let route_label = function
  | Host -> "host"
  | Sandbox_backend -> "docker"

let route_via ~config ~meta ~cwd =
  route_for ~config ~meta ~cwd |> route_label

let run_host_command ~timeout_sec (host : host_command) =
  let status, output =
    Masc_exec.Exec_gate.run_argv_with_status
      ~actor:host.actor
      ~raw_source:host.raw_source
      ~summary:host.summary
      ~timeout_sec
      ?env:host.env
      ?cwd:host.cwd
      host.argv
  in
  { status; output; via = route_label Host; backend_error = None }

let run_backend_command ~config ~meta ~timeout_sec (backend : backend_command) =
  let cwd = backend.cwd () in
  let runner =
    match backend.trust with
    | User_shell -> run_shell_command_with_status
    | Trusted_tool -> run_trusted_shell_command_with_status
  in
  match
    runner
      ~config ~meta
      ~cwd
      ~timeout_sec
      ~cmd:backend.command_text
      ~network_mode:backend.network_mode
  with
  | Ok result ->
    { status = result.status
    ; output = result.output
    ; via = route_label Sandbox_backend
    ; backend_error = None
    }
  | Error msg ->
    { status = Unix.WEXITED 127
    ; output = msg
    ; via = route_label Sandbox_backend
    ; backend_error = Some msg
    }

let run_command_with_status ~config ~meta ~timeout_sec ~host ~backend =
  match route_for ~config ~meta ~cwd:backend.route_cwd with
  | Sandbox_backend -> run_backend_command ~config ~meta ~timeout_sec backend
  | Host -> run_host_command ~timeout_sec host
