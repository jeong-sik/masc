(** Keeper-scoped GH credential isolation.

    SSOT for [GH_CONFIG_DIR] handling. Scopes [gh] subprocess
    invocations to the selected keeper/root identity bundle instead of
    the operator's ambient GitHub credentials. *)

type credential_scope =
  | Keeper_identity
  | Root_fallback

type keeper_binding = {
  github_identity : string option;
      (** Keeper-configured identity, if one was declared. *)
  effective_github_identity : string;
      (** Identity whose bundle will actually be used. *)
  credential_scope : credential_scope;
  git_identity_mode : string;
  bundle_root : string;
  gh_config_dir : string;
}

(** Reserved root fallback identity. *)
val root_github_identity : string

val credential_scope_to_string : credential_scope -> string

(** Resolve the root fallback GH config dir when it exists. *)
val config_dir : Coord.config -> string option

(** [bundle_root config ~github_identity] is the on-disk root of the
    GitHub identity bundle: [$base_path/.masc/github-identities/<id>]. *)
val bundle_root : Coord.config -> github_identity:string -> string

val root_bundle_root : Coord.config -> string

(** [gh_config_dir_of_bundle bundle_root] is the [gh/] subdir of a
    GitHub identity bundle. *)
val gh_config_dir_of_bundle : string -> string

val root_gh_config_dir : Coord.config -> string

val root_gh_config_dir_exists : Coord.config -> bool

(** Resolve the keeper's GitHub identity binding, or an error string
    explaining why the binding cannot be established (missing identity
    in profile defaults, missing GH config dir on disk, etc.). *)
val keeper_binding :
  Coord.config -> keeper_name:string -> (keeper_binding, string) result

(** Convenience: extract just the [gh_config_dir] from the binding. *)
val keeper_config_dir :
  Coord.config -> keeper_name:string -> (string, string) result

(** Prepend [GH_CONFIG_DIR=<dir>] to a gh shell command when a
    keeper-scoped config exists. Scoped to the single subprocess
    invocation — the operator's terminal is unaffected. *)
val with_env : Coord.config -> string -> string

(** Compose the base environment for a gh/git subprocess: scrub
    long-lived host credentials, inject non-interactive git constants,
    strip ambient GH/Git config env, and prepend bundle-local [HOME],
    [GH_CONFIG_DIR], [GIT_CONFIG_GLOBAL], and safe.directory settings.

    See [Env_keeper_scrub] and [Env_git_noninteractive] for the
    canonical lists. *)
val compose_base_with_gh_config : dir:string -> string array

(** [process_env config] returns the composed env for the root GH
    identity path. It never uses the operator's ambient GH config. *)
val process_env : Coord.config -> string array option

(** [keeper_process_env config ~keeper_name] returns the composed env
    for a specific keeper's GH identity, or an error if the binding
    cannot be resolved. *)
val keeper_process_env :
  Coord.config -> keeper_name:string -> (string array option, string) result
