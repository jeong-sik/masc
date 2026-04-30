(** Keeper-scoped GH credential isolation.

    SSOT for [GH_CONFIG_DIR] handling. It scopes [gh] subprocess
    invocations to the selected keeper/root identity bundle instead of
    the operator's ambient GitHub credentials.

    Extracted to its own module to avoid circular dependencies
    (keeper_gh_env is a shared SSOT for GH credential handling) and to keep
    keeper_exec_shared's interface stable (adding functions to it
    causes dune interface mismatch errors in the test suite). *)

type credential_scope =
  | Keeper_identity
  | Root_fallback

let root_github_identity = "root"

let credential_scope_to_string = function
  | Keeper_identity -> "keeper_identity"
  | Root_fallback -> "root_fallback"

type keeper_binding = {
  github_identity : string option;
  effective_github_identity : string;
  credential_scope : credential_scope;
  git_identity_mode : string;
  bundle_root : string;
  gh_config_dir : string;
}

let bundle_root (config : Coord.config) ~(github_identity : string) =
  Filename.concat
    (Filename.concat (Coord.masc_dir config) "github-identities")
    github_identity

let root_bundle_root config =
  bundle_root config ~github_identity:root_github_identity

let gh_config_dir_of_bundle bundle_root =
  Filename.concat bundle_root "gh"

let root_gh_config_dir config =
  gh_config_dir_of_bundle (root_bundle_root config)

let gh_config_dir_exists dir =
  Sys.file_exists dir && Sys.is_directory dir

let root_gh_config_dir_exists config =
  gh_config_dir_exists (root_gh_config_dir config)

(** Root fallback is MASC-owned under the active base path.  Keeper
    execution never falls back to ambient operator GH config. *)
let config_dir (config : Coord.config) : string option =
  let dir = root_gh_config_dir config in
  if gh_config_dir_exists dir then Some dir else None

let binding_of_identity
    ~(configured_github_identity : string option)
    ~(effective_github_identity : string)
    ~(credential_scope : credential_scope)
    ~(git_identity_mode : string)
    ~(bundle_root : string)
    ~(gh_config_dir : string) =
  {
    github_identity = configured_github_identity;
    effective_github_identity;
    credential_scope;
    git_identity_mode;
    bundle_root;
    gh_config_dir;
  }

let keeper_binding (config : Coord.config) ~(keeper_name : string) :
    (keeper_binding, string) result =
  let defaults = Keeper_types_profile.load_keeper_profile_defaults keeper_name in
  let git_identity_mode =
    Option.value ~default:"keeper_alias" defaults.git_identity_mode
  in
  match defaults.github_identity with
  | None ->
      let bundle_root = root_bundle_root config in
      let gh_config_dir = gh_config_dir_of_bundle bundle_root in
      if gh_config_dir_exists gh_config_dir then
        Ok
          (binding_of_identity
             ~configured_github_identity:None
             ~effective_github_identity:root_github_identity
             ~credential_scope:Root_fallback
             ~git_identity_mode ~bundle_root ~gh_config_dir)
      else
        Error
          (Printf.sprintf
             "keeper %s has no github_identity configured and root GitHub identity bundle is missing at %s. Configure github_identity or run the root GitHub identity login flow first."
             keeper_name gh_config_dir)
  | Some github_identity ->
      let bundle_root = bundle_root config ~github_identity in
      let gh_config_dir = gh_config_dir_of_bundle bundle_root in
      if gh_config_dir_exists gh_config_dir then
        Ok
          (binding_of_identity
             ~configured_github_identity:(Some github_identity)
             ~effective_github_identity:github_identity
             ~credential_scope:Keeper_identity
             ~git_identity_mode ~bundle_root ~gh_config_dir)
      else
        Error
          (Printf.sprintf
             "keeper %s is bound to github_identity %s but GH config dir %s is missing. Run the operator GitHub identity login flow first."
             keeper_name github_identity gh_config_dir)

let keeper_config_dir (config : Coord.config) ~(keeper_name : string) :
    (string, string) result =
  keeper_binding config ~keeper_name
  |> Result.map (fun binding -> binding.gh_config_dir)

(** Prepend [GH_CONFIG_DIR=<dir>] to a gh shell command when a
    keeper-scoped config exists. Scoped to the single subprocess
    invocation — the operator's terminal is unaffected. *)
let with_env (config : Coord.config) (gh_cmd : string) : string =
  let bundle_root = root_bundle_root config in
  Printf.sprintf
    "GH_TOKEN= GITHUB_TOKEN= SSH_AUTH_SOCK= HOME=%s GH_CONFIG_DIR=%s \
     GIT_CONFIG_GLOBAL=%s GIT_CONFIG_COUNT=1 \
     GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*' %s"
    (Filename.quote bundle_root)
    (Filename.quote (root_gh_config_dir config))
    (Filename.quote (Filename.concat bundle_root "gitconfig"))
    gh_cmd

(* Compose base env for a gh/git subprocess.

   Order of operations (inside-out):
     1. Start from [Unix.environment ()].
     2. Scrub long-lived host credentials that are consumed by MASC
        in-process and MUST NOT cross into a keeper subprocess or
        sandboxed container.
     3. Prepend the non-interactive git constants so credential prompts
        cannot hang the subprocess on a missing tty.
     4. Strip ambient GH/Git config env and prepend bundle-local
        [HOME], [GH_CONFIG_DIR], [GIT_CONFIG_GLOBAL], and safe.directory
        env so the selected identity bundle wins over operator config.

   See [Env_keeper_scrub] and [Env_git_noninteractive] for the
   canonical lists and their rationale. *)
let compose_base_with_gh_config ~dir =
  let bundle_root = Filename.dirname dir in
  let scrubbed = Env_keeper_scrub.filter_environment (Unix.environment ()) in
  let with_noprompt = Env_git_noninteractive.inject_into_environment scrubbed in
  let without_existing_config =
    Array.to_list with_noprompt
    |> List.filter (fun entry ->
         not
           (String.starts_with ~prefix:"HOME=" entry
           || String.starts_with ~prefix:"GH_CONFIG_DIR=" entry
           || String.starts_with ~prefix:"GIT_CONFIG_GLOBAL=" entry
           || String.starts_with ~prefix:"GIT_CONFIG_COUNT=" entry
           || String.starts_with ~prefix:"GIT_CONFIG_KEY_" entry
           || String.starts_with ~prefix:"GIT_CONFIG_VALUE_" entry))
  in
  let scoped =
    [
      "HOME=" ^ bundle_root;
      "GH_CONFIG_DIR=" ^ dir;
      "GIT_CONFIG_GLOBAL=" ^ Filename.concat bundle_root "gitconfig";
      "GIT_CONFIG_COUNT=1";
      "GIT_CONFIG_KEY_0=safe.directory";
      "GIT_CONFIG_VALUE_0=*";
    ]
  in
  Array.of_list (scoped @ without_existing_config)

let process_env (config : Coord.config) : string array option =
  Some (compose_base_with_gh_config ~dir:(root_gh_config_dir config))

let keeper_process_env (config : Coord.config) ~(keeper_name : string) :
    (string array option, string) result =
  keeper_config_dir config ~keeper_name
  |> Result.map (fun dir -> Some (compose_base_with_gh_config ~dir))
