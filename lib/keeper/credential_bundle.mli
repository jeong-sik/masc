(** Keeper-scoped GitHub credential isolation.

    SSOT for [GH_CONFIG_DIR] handling. Scopes [gh] subprocess
    invocations to the selected credential bundle instead of
    the operator's ambient credentials. *)

type credential_scope =
  | Keeper_identity
  | Root_fallback

type keeper_binding = {
  credential_identity : string;
      (** Identity whose bundle will actually be used. *)
  credential_scope : credential_scope;
  bundle_root : string;
  credential_bundle_dir : string;
}

(** Reserved default credential bundle id. *)
val root_credential_identity : string

val credential_scope_to_string : credential_scope -> string

(** [bundle_root config ~credential_identity] is the on-disk root of the
    credential bundle: [$base_path/.masc/credentials/<id>]. *)
val bundle_root : Workspace.config -> credential_identity:string -> string

val root_bundle_root : Workspace.config -> string

(** [credential_bundle_dir_of_root bundle_root] is the [gh/] subdir of a
    credential bundle. *)
val credential_bundle_dir_of_root : string -> string

val root_credential_bundle_dir : Workspace.config -> string

val git_config_env_entries : string list

val git_config_env_pairs : (string * string) list

(** Resolve the keeper's GitHub credential binding from
    [keeper_repo_mappings.toml], or return an error string explaining
    why the binding cannot be established. *)
val keeper_binding :
  Workspace.config -> keeper_name:string -> (keeper_binding, string) result

(** Compose the base environment for a Git/GitHub subprocess: scrub
    long-lived host credentials, inject non-interactive git constants,
    strip ambient GH/Git config env, and prepend bundle-local [HOME],
    [GH_CONFIG_DIR], [GIT_CONFIG_GLOBAL], and safe.directory settings.

    See [Env_keeper_scrub] and [Env_git_noninteractive] for the
    canonical lists. *)
val compose_base_with_credential_bundle : dir:string -> string array
