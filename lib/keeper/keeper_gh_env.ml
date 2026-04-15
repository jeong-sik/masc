(** Keeper-scoped GH credential isolation.

    SSOT for [GH_CONFIG_DIR] handling. Used by the inlined GH cache in [Keeper_exec_github] and
    [Keeper_exec_github] to scope [gh] subprocess invocations to the
    keeper identity (e.g. [anyang-keepers]) instead of the operator's
    personal [~/.config/gh] credentials.

    Extracted to its own module to avoid circular dependencies
    (keeper_gh_env is a shared SSOT for GH credential handling) and to keep
    keeper_exec_shared's interface stable (adding functions to it
    causes dune interface mismatch errors in the test suite). *)

(** Resolve [$base_path/.masc/gh-auth/] if it exists. *)
let config_dir (config : Coord.config) : string option =
  let dir = Filename.concat config.Coord_utils.base_path ".masc/gh-auth" in
  if Sys.file_exists dir && Sys.is_directory dir then Some dir else None

(** Prepend [GH_CONFIG_DIR=<dir>] to a gh shell command when a
    keeper-scoped config exists. Scoped to the single subprocess
    invocation — the operator's terminal is unaffected. *)
let with_env (config : Coord.config) (gh_cmd : string) : string =
  match config_dir config with
  | None -> gh_cmd
  | Some dir ->
    Printf.sprintf "GH_CONFIG_DIR=%s %s" (Filename.quote dir) gh_cmd
