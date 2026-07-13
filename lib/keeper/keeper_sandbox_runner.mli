(** Backend-neutral keeper sandbox command runner.

    Tool modules should depend on this module instead of concrete
    sandbox backends. The production backend is currently Docker, but
    that choice is intentionally hidden behind this facade. *)

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

module Make (Backend : Backend) : sig
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

val uses_backend :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  cwd:string ->
  bool

val route_for :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  cwd:string ->
  route

val route_label : route -> string

val route_via :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  cwd:string ->
  string

val run_command_with_status :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  timeout_sec:float ->
  host:host_command ->
  backend:backend_command ->
  routed_result
