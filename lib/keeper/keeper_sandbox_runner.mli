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

(** The ["via"] value a write reports when the turn's sandbox runtime runs
    it. *)
val sandbox_backend_via : string
