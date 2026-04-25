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
  let dir = Filename.concat (Coord.masc_dir config) "gh-auth" in
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
      if Env_config_keeper.KeeperSandbox.hard_mode () then
        Error
          (Printf.sprintf
             "keeper %s has no github_identity configured; MASC_KEEPER_SANDBOX_HARD_MODE requires keeper-scoped GitHub identity"
             keeper_name)
      else
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

(* RFC-0007 PR-1: compose base env for a gh/git subprocess.

   Order of operations (inside-out):
     1. Start from [Unix.environment ()].
     2. Scrub long-lived host credentials that are consumed by MASC
        in-process and MUST NOT cross into a keeper subprocess or
        sandboxed container.
     3. Prepend the non-interactive git constants so credential prompts
        cannot hang the subprocess on a missing tty.
     4. Strip any pre-existing [GH_CONFIG_DIR=] entry and prepend the
        keeper-scoped value so the keeper's GH identity wins over any
        operator config present in the process env.

   See [Env_keeper_scrub] and [Env_git_noninteractive] for the
   canonical lists and their rationale. *)
let compose_base_with_gh_config ~dir =
  let scrubbed = Env_keeper_scrub.filter_environment (Unix.environment ()) in
  let with_noprompt = Env_git_noninteractive.inject_into_environment scrubbed in
  let without_existing_gh =
    Array.to_list with_noprompt
    |> List.filter (fun entry ->
         not (String.starts_with ~prefix:"GH_CONFIG_DIR=" entry))
  in
  let gh_config = "GH_CONFIG_DIR=" ^ dir in
  Array.of_list (gh_config :: without_existing_gh)

let process_env (config : Coord.config) : string array option =
  match config_dir config with
  | None -> None
  | Some dir -> Some (compose_base_with_gh_config ~dir)

let keeper_process_env (config : Coord.config) ~(keeper_name : string) :
    (string array option, string) result =
  keeper_config_dir config ~keeper_name
  |> Result.map (function
       | None -> None
       | Some dir -> Some (compose_base_with_gh_config ~dir))
