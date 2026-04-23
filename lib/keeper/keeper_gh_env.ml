(** Keeper-scoped GH credential isolation.

    SSOT for [GH_CONFIG_DIR] handling. Used by the inlined GH cache in [Keeper_exec_github] and
    [Keeper_exec_github] to scope [gh] subprocess invocations to the
    keeper identity (e.g. [anyang-keepers]) instead of the operator's
    personal [~/.config/gh] credentials.

    Extracted to its own module to avoid circular dependencies
    (keeper_gh_env is a shared SSOT for GH credential handling) and to keep
    keeper_exec_shared's interface stable (adding functions to it
    causes dune interface mismatch errors in the test suite). *)

(** Resolve legacy [$base_path/.masc/gh-auth/] if it exists. *)
let config_dir (config : Coord.config) : string option =
  let dir = Filename.concat config.Coord_utils.base_path ".masc/gh-auth" in
  if Sys.file_exists dir && Sys.is_directory dir then Some dir else None

type keeper_binding = {
  github_identity : string option;
  git_identity_mode : string;
  bundle_root : string option;
  gh_config_dir : string option;
}

let bundle_root (config : Coord.config) ~(github_identity : string) =
  Filename.concat
    (Filename.concat (Coord.masc_dir config) "github-identities")
    github_identity

let gh_config_dir_of_bundle bundle_root =
  Filename.concat bundle_root "gh"

let keeper_binding (config : Coord.config) ~(keeper_name : string) :
    (keeper_binding, string) result =
  let defaults = Keeper_types_profile.load_keeper_profile_defaults keeper_name in
  let git_identity_mode =
    Option.value ~default:"keeper_alias" defaults.git_identity_mode
  in
  match defaults.github_identity with
  | None ->
      Ok
        {
          github_identity = None;
          git_identity_mode;
          bundle_root = None;
          gh_config_dir = config_dir config;
        }
  | Some github_identity ->
      let bundle_root = bundle_root config ~github_identity in
      let gh_config_dir = gh_config_dir_of_bundle bundle_root in
      if Sys.file_exists gh_config_dir && Sys.is_directory gh_config_dir then
        Ok
          {
            github_identity = Some github_identity;
            git_identity_mode;
            bundle_root = Some bundle_root;
            gh_config_dir = Some gh_config_dir;
          }
      else
        Error
          (Printf.sprintf
             "keeper %s is bound to github_identity %s but GH config dir %s is missing. Run the operator GitHub identity login flow first."
             keeper_name github_identity gh_config_dir)

let keeper_config_dir (config : Coord.config) ~(keeper_name : string) :
    (string option, string) result =
  keeper_binding config ~keeper_name
  |> Result.map (fun binding -> binding.gh_config_dir)

(** Prepend [GH_CONFIG_DIR=<dir>] to a gh shell command when a
    keeper-scoped config exists. Scoped to the single subprocess
    invocation — the operator's terminal is unaffected. *)
let with_env (config : Coord.config) (gh_cmd : string) : string =
  match config_dir config with
  | None -> gh_cmd
  | Some dir ->
    Printf.sprintf "GH_CONFIG_DIR=%s %s" (Filename.quote dir) gh_cmd

let process_env (config : Coord.config) : string array option =
  match config_dir config with
  | None -> None
  | Some dir ->
    let gh_config = "GH_CONFIG_DIR=" ^ dir in
    let base =
      Unix.environment ()
      |> Array.to_list
      |> List.filter (fun entry ->
        not (String.starts_with ~prefix:"GH_CONFIG_DIR=" entry))
    in
    Some (Array.of_list (gh_config :: base))

let keeper_process_env (config : Coord.config) ~(keeper_name : string) :
    (string array option, string) result =
  keeper_config_dir config ~keeper_name
  |> Result.map (function
       | None -> None
       | Some dir ->
           let gh_config = "GH_CONFIG_DIR=" ^ dir in
           let base =
             Unix.environment ()
             |> Array.to_list
             |> List.filter (fun entry ->
                  not (String.starts_with ~prefix:"GH_CONFIG_DIR=" entry))
           in
           Some (Array.of_list (gh_config :: base)))
