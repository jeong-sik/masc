(** [Keeper_sandbox_cwd] — unified playground root interface.

    Consolidates five ad-hoc playground_root functions scattered across
    [Keeper_alerting_path], [Keeper_sandbox_containment],
    [Keeper_tool_shared_runtime], [Keeper_sandbox_read_backend], and
    [Keeper_tool_execute_path] into one canonical module.

    Phase B (task-658): single source of truth for host↔container path
    resolution and playground root queries. *)

(** {1 Types} *)

type playground_resolved = {
  host_abs : string;
  (** Absolute host-side path, e.g. [/Users/foo/.masc/playground/KEEPER]. *)
  container_abs : string option;
  (** Absolute container-side path when running inside Docker,
      e.g. [/home/keeper/playground/KEEPER]. [None] for Local profile. *)
}

(** {1 Core} *)

val playground_root_abs :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  string
(** Canonical absolute playground root. Replaces:
    - [Keeper_sandbox_containment.playground_root_abs]
    - [Keeper_sandbox_read_backend.host_playground_root]
    - [Keeper_tool_execute_path.playground_root] *)

val resolve_playground :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  playground_resolved
(** Returns both host and container paths. [container_abs] is [Some]
    when [meta.sandbox_profile = Docker]. *)

val container_path_of_host :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  host_path:string ->
  string
(** Convert a host absolute path to the corresponding container path.
    Raises [Invalid_argument] if the path is outside the playground. *)

val host_path_of_container :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  container_path:string ->
  string
(** Convert a container absolute path back to host path.
    Raises [Invalid_argument] if the path is outside the playground. *)

(** {1 Derived}

    Convenience wrappers that combine playground root with a sub-path. *)

val repos_dir :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  string
(** [playground_root_abs ^ "/repos"]. *)

val worktree_dir :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  repo:string ->
  branch:string ->
  string
(** [repos_dir ^ "/" ^ repo ^ "/.worktrees/" ^ branch]. *)