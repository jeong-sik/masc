type command_result =
  { status : Unix.process_status
  ; output : string
  ; image : string
  ; network_label : string
  ; cmd_stages : Keeper_shell_command_semantics.parsed_stage list
  ; cwd : string
  ; semantic_status : Exec_core.semantic_status option
  ; semantic_ok : bool
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
  ; git_creds_enabled : bool
  ; network_mode : Keeper_types.network_mode
  ; trust : command_trust
  }

type routed_result =
  { status : Unix.process_status
  ; output : string
  ; via : string
  ; backend_error : string option
  }

module type Backend = sig
  val egress_policy_path :
    config:Coord.config ->
    meta:Keeper_types.keeper_meta ->
    string

  val effective_sandbox_profile :
    meta:Keeper_types.keeper_meta ->
    in_playground:bool ->
    Keeper_types.sandbox_profile * Keeper_types.network_mode

  val ensure_runtime :
    timeout_sec:float -> (string list, string) result

  val command_uses_nested_runtime : string -> bool

  val private_workspace_cwd :
    config:Coord.config ->
    meta:Keeper_types.keeper_meta ->
    string ->
    string

  val run_shell_command_with_status :
    config:Coord.config ->
    meta:Keeper_types.keeper_meta ->
    cwd:string ->
    timeout_sec:float ->
    cmd:string ->
    git_creds_enabled:bool ->
    network_mode:Keeper_types.network_mode ->
    (command_result, string) result

  val run_trusted_shell_command_with_status :
    config:Coord.config ->
    meta:Keeper_types.keeper_meta ->
    cwd:string ->
    timeout_sec:float ->
    cmd:string ->
    git_creds_enabled:bool ->
    network_mode:Keeper_types.network_mode ->
    (command_result, string) result

  val run_credentialed_bash :
    turn_sandbox_runtime:Keeper_turn_sandbox_runtime.t option ->
    config:Coord.config ->
    meta:Keeper_types.keeper_meta ->
    cwd:string ->
    timeout_sec:float ->
    cmd:string ->
    unit ->
    string

  val run_bash :
    turn_sandbox_runtime:Keeper_turn_sandbox_runtime.t option ->
    config:Coord.config ->
    meta:Keeper_types.keeper_meta ->
    cwd:string ->
    timeout_sec:float ->
    cmd:string ->
    network_mode:Keeper_types.network_mode ->
    string
end

module Make (Backend : Backend) = struct
  let egress_policy_path = Backend.egress_policy_path
  let effective_sandbox_profile = Backend.effective_sandbox_profile
  let ensure_runtime = Backend.ensure_runtime
  let command_uses_nested_runtime = Backend.command_uses_nested_runtime
  let private_workspace_cwd = Backend.private_workspace_cwd
  let run_shell_command_with_status = Backend.run_shell_command_with_status
  let run_trusted_shell_command_with_status =
    Backend.run_trusted_shell_command_with_status
  let run_credentialed_bash = Backend.run_credentialed_bash
  let run_bash = Backend.run_bash
end

let of_docker_result
    (result : Keeper_sandbox_docker.docker_shell_result)
  : command_result =
  { status = result.status
  ; output = result.output
  ; image = result.image
  ; network_label = result.network_label
  ; cmd_stages = result.cmd_stages
  ; cwd = result.cwd
  ; semantic_status = result.semantic_status
  ; semantic_ok = result.semantic_ok
  }

module Docker_backend = struct
  let egress_policy_path = Keeper_sandbox_docker.egress_policy_path
  let effective_sandbox_profile = Keeper_sandbox_docker.effective_sandbox_profile
  let ensure_runtime = Keeper_sandbox_docker.ensure_keeper_sandbox_runtime
  let command_uses_nested_runtime =
    Keeper_sandbox_docker.command_uses_nested_container_runtime
  let private_workspace_cwd = Keeper_sandbox_docker.docker_private_workspace_cwd

  let run_shell_command_with_status ~config ~meta ~cwd ~timeout_sec ~cmd
      ~git_creds_enabled ~network_mode =
    Keeper_sandbox_docker.run_docker_shell_command_with_status
      ~config ~meta ~cwd ~timeout_sec ~cmd ~git_creds_enabled ~network_mode
    |> Result.map of_docker_result

  let run_trusted_shell_command_with_status ~config ~meta ~cwd ~timeout_sec ~cmd
      ~git_creds_enabled ~network_mode =
    Keeper_sandbox_docker.run_trusted_docker_shell_command_with_status
      ~config ~meta ~cwd ~timeout_sec ~cmd ~git_creds_enabled ~network_mode
    |> Result.map of_docker_result

  let run_credentialed_bash =
    Keeper_sandbox_docker.run_docker_credentialed_bash

  let run_bash = Keeper_sandbox_docker.run_docker_bash
end

include Make (Docker_backend)

let strip_trailing_slashes path =
  let rec loop i =
    if i > 0 && path.[i - 1] = '/' then loop (i - 1) else i
  in
  let len = loop (String.length path) in
  if len = String.length path then path else String.sub path 0 len

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

let uses_backend ~config ~meta ~cwd =
  let in_playground = in_playground ~config ~meta ~cwd in
  match effective_sandbox_profile ~meta ~in_playground with
  | Keeper_types.Docker, _ -> true
  | Keeper_types.Local, _ -> false

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
  { status; output; via = "host"; backend_error = None }

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
      ~git_creds_enabled:backend.git_creds_enabled
      ~network_mode:backend.network_mode
  with
  | Ok result ->
    { status = result.status
    ; output = result.output
    ; via = "docker"
    ; backend_error = None
    }
  | Error msg ->
    { status = Unix.WEXITED 127
    ; output = msg
    ; via = "docker"
    ; backend_error = Some msg
    }

let run_command_with_status ~config ~meta ~timeout_sec ~host ~backend =
  if uses_backend ~config ~meta ~cwd:backend.route_cwd then
    run_backend_command ~config ~meta ~timeout_sec backend
  else
    run_host_command ~timeout_sec host
