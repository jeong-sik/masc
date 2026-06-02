(** Keeper sandbox configuration contract.

    Neutral config-layer boundary between persisted keeper TOML and
    subsystems that need sandbox storage shape. It does not execute tools
    and it does not start Docker. *)

type sandbox_profile =
  | Local
  | Docker

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

val is_docker :
  base_path:string ->
  agent_name:string ->
  bool

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

(** [visible_path_of_host_path ~base_path ~agent_name ~host_path]
    projects a backend host worktree path to the path the keeper should
    see. Local keepers receive [host_path]. Docker keepers receive the
    matching container path when [host_path] is under their configured
    repos root; paths outside that root are returned unchanged. *)
val visible_path_of_host_path :
  base_path:string ->
  agent_name:string ->
  host_path:string ->
  string
