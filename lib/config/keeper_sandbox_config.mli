(** Keeper sandbox configuration contract.

    Neutral config-layer boundary between persisted keeper TOML and
    subsystems that need sandbox storage shape. It does not execute tools
    and it does not start Docker. *)

type sandbox_profile =
  | Local
  | Docker
  | Micro_vm
  | Remote_ssh

exception Invalid_keeper_sandbox_config of string

val sandbox_profile_to_string : sandbox_profile -> string
val sandbox_profile_of_string : string -> sandbox_profile option
val valid_sandbox_profile_strings : string list
val default_sandbox_profile : sandbox_profile

val keeper_toml_path :
  base_path:string ->
  agent_name:string ->
  string

val sandbox_profile_of_agent :
  base_path:string ->
  agent_name:string ->
  sandbox_profile

val host_root_rel_of_profile :
  sandbox_profile ->
  string ->
  string

val host_root_rel_of_agent :
  base_path:string ->
  agent_name:string ->
  string

val host_root_abs_of_agent :
  base_path:string ->
  agent_name:string ->
  string

(** [container_root_of_agent ~agent_name] returns the sandbox-visible
    root used by Docker-backed keepers. This is a path projection only;
    it does not start or inspect Docker. *)
val container_root_of_agent :
  agent_name:string ->
  string

