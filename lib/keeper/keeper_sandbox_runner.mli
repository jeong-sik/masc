(** Backend-neutral keeper sandbox command runner.

    Tool modules should depend on this module instead of concrete
    sandbox backends. The production backend is currently Docker, but
    that choice is intentionally hidden behind this facade. *)

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
  { cwd : string
  ; command_text : string
  ; git_creds_enabled : bool
  ; network_mode : Keeper_types.network_mode
  ; trust : command_trust
  }

type routed_result =
  { status : Unix.process_status
  ; output : string
  ; via : string
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

module Make (Backend : Backend) : sig
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

val uses_backend :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  cwd:string ->
  bool

val run_command_with_status :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  timeout_sec:float ->
  host:host_command ->
  backend:backend_command ->
  routed_result
