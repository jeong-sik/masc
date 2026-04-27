(** Keeper-scoped GH credential isolation.

    SSOT for [GH_CONFIG_DIR] handling. Scopes [gh] subprocess
    invocations to the keeper identity (e.g. [anyang-keepers]) instead
    of the operator's personal [~/.config/gh] credentials. *)

type keeper_binding = {
  github_identity : string option;
  git_identity_mode : string;
  bundle_root : string option;
  gh_config_dir : string option;
}

(** Resolve legacy [$base_path/.masc/gh-auth/] if it exists. *)
val config_dir : Coord.config -> string option

(** [bundle_root config ~github_identity] is the on-disk root of the
    GitHub identity bundle: [$base_path/.masc/github-identities/<id>]. *)
val bundle_root : Coord.config -> github_identity:string -> string

(** [gh_config_dir_of_bundle bundle_root] is the [gh/] subdir of a
    GitHub identity bundle. *)
val gh_config_dir_of_bundle : string -> string

(** Resolve the keeper's GitHub identity binding, or an error string
    explaining why the binding cannot be established (missing identity
    in profile defaults, missing GH config dir on disk, etc.). *)
val keeper_binding :
  Coord.config -> keeper_name:string -> (keeper_binding, string) result

(** Convenience: extract just the [gh_config_dir] from the binding. *)
val keeper_config_dir :
  Coord.config -> keeper_name:string -> (string option, string) result

(** Prepend [GH_CONFIG_DIR=<dir>] to a gh shell command when a
    keeper-scoped config exists. Scoped to the single subprocess
    invocation — the operator's terminal is unaffected. *)
val with_env : Coord.config -> string -> string

(** Compose the base environment for a gh/git subprocess: scrub
    long-lived host credentials, inject non-interactive git constants,
    and prepend the keeper-scoped [GH_CONFIG_DIR]. RFC-0007 PR-1.

    See [Env_keeper_scrub] and [Env_git_noninteractive] for the
    canonical lists. *)
val compose_base_with_gh_config : dir:string -> string array

(** [process_env config] returns the composed env for the operator's
    GH config dir, or [None] when no [gh-auth/] exists. *)
val process_env : Coord.config -> string array option

(** [keeper_process_env config ~keeper_name] returns the composed env
    for a specific keeper's GH identity, or an error if the binding
    cannot be resolved. *)
val keeper_process_env :
  Coord.config -> keeper_name:string -> (string array option, string) result
