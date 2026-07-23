type t =
  { docker_args : string list
  ; cleanup : unit -> unit
  }

type secret_root_info =
  { root : string
  ; source : string
  }

type secret_scope =
  | Shared_secret
  | Keeper_secret

val secret_root_info : base_path:string -> keeper_name:string -> secret_root_info

val secret_root : base_path:string -> keeper_name:string -> string

val secret_roots : base_path:string -> keeper_name:string -> secret_root_info list
(** Effective secret roots in projection order. The workspace-level
    [secrets/base] root is loaded first and [secrets/<keeper>] overlays it.
    For the literal [base] keeper, the root is returned once. *)

val local_env_for_keeper :
  ?host_env:string array ->
  base_path:string ->
  keeper_name:string ->
  unit ->
  (string array option, string) result
(** Build the child-process environment for local Keeper execution from
    [secrets/base/env] overlaid by [secrets/<keeper>/env]. The host
    environment is Keeper-scrubbed even when both secret roots are absent; a
    missing root only means there are no env/file overlays from that scope.
    Secret names and values are projected without interpreting a provider,
    product, CLI, or credential format. *)

val docker_args_for_keeper :
  base_path:string ->
  keeper_name:string ->
  container_name:string ->
  unit ->
  (t, string) result
(** Build Docker secret projection arguments. Every configured env/file entry
    follows the same projection contract; this layer does not recognize or
    transform product-specific credentials. *)

val secret_scope_of_string : string -> secret_scope option

val set_env_entry :
  base_path:string ->
  keeper_name:string ->
  scope:secret_scope ->
  name:string ->
  value:string ->
  (unit, string) result
(** Persist one projected env secret under [secrets/base/env] or
    [secrets/<keeper>/env]. The value is validated with the same single-line
    rules used by local and docker projection. *)

val delete_env_entry :
  base_path:string ->
  keeper_name:string ->
  scope:secret_scope ->
  name:string ->
  (unit, string) result
(** Remove one projected env secret. Missing files are treated as a no-op;
    symlinks and non-regular entries are rejected. *)

val set_file_entry :
  base_path:string ->
  keeper_name:string ->
  scope:secret_scope ->
  container_path:string ->
  value:string ->
  (unit, string) result
(** Persist one projected file secret under [secrets/base/files] or
    [secrets/<keeper>/files]. [container_path] must be an absolute container
    path; traversal components and symlink targets are rejected. *)

val delete_file_entry :
  base_path:string ->
  keeper_name:string ->
  scope:secret_scope ->
  container_path:string ->
  (unit, string) result
(** Remove one projected file secret. Missing files are treated as a no-op;
    symlinks and non-regular entries are rejected. *)

val dashboard_status_json :
  base_path:string -> keeper_name:string -> Yojson.Safe.t
