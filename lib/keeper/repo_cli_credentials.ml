(** Keeper-scoped repo CLI credential isolation.

    SSOT for [GH_CONFIG_DIR] handling. It scopes [gh] subprocess
    invocations to the selected keeper/root identity bundle instead of
    the operator's ambient credentials.

    Extracted to its own module to avoid circular dependencies
    (repo_cli_credentials is a shared SSOT for repo CLI credential handling)
    and to keep agent_tool_shared_runtime's interface stable (adding functions
    to it
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

let repo_cli_config_dir_of_bundle bundle_root =
  Filename.concat bundle_root "gh"

let root_repo_cli_config_dir config =
  repo_cli_config_dir_of_bundle (root_bundle_root config)

let git_config_env_entries =
  [
    "GIT_CONFIG_COUNT=4";
    "GIT_CONFIG_KEY_0=safe.directory";
    "GIT_CONFIG_VALUE_0=*";
    "GIT_CONFIG_KEY_1=credential.helper";
    "GIT_CONFIG_VALUE_1=";
    "GIT_CONFIG_KEY_2=credential.https://github.com.helper";
    "GIT_CONFIG_VALUE_2=!gh auth git-credential";
    "GIT_CONFIG_KEY_3=credential.useHttpPath";
    "GIT_CONFIG_VALUE_3=true";
  ]

let git_config_env_pairs =
  List.filter_map
    (fun entry ->
      match String.index_opt entry '=' with
      | None -> None
      | Some idx ->
          Some
            ( String.sub entry 0 idx,
              String.sub entry (idx + 1) (String.length entry - idx - 1) ))
    git_config_env_entries

let repo_cli_config_dir_exists dir =
  Sys.file_exists dir && Sys.is_directory dir

let root_repo_cli_config_dir_exists config =
  repo_cli_config_dir_exists (root_repo_cli_config_dir config)

(** Root fallback is MASC-owned under the active base path.  Keeper
    execution never falls back to ambient operator GH config. *)
let config_dir (config : Coord.config) : string option =
  let dir = root_repo_cli_config_dir config in
  if repo_cli_config_dir_exists dir then Some dir else None

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

let repo_cli_config_dir_matches_identity ~expected gh_config_dir =
  String.equal (Filename.basename gh_config_dir) "gh"
  && String.equal (Filename.basename (Filename.dirname gh_config_dir)) expected

let credential_matches_explicit_github_identity ~expected
    (cred : Repo_manager_types.credential) =
  let expected = String.trim expected in
  expected <> ""
  && (String.equal cred.id expected
      || String.equal cred.username expected
      ||
      match cred.gh_config_dir with
      | Some gh_config_dir ->
          repo_cli_config_dir_matches_identity ~expected (String.trim gh_config_dir)
      | None -> false)

let binding_of_mapped_credential
    ~(keeper_name : string)
    ~(defaults : Keeper_types_profile.keeper_profile_defaults)
    (cred : Repo_manager_types.credential) =
  match defaults.github_identity, defaults.git_identity_mode with
  | Some expected, Some "github_identity"
    when not (credential_matches_explicit_github_identity ~expected cred) ->
      let gh_config_dir =
        Option.value ~default:"<none>" cred.Repo_manager_types.gh_config_dir
      in
      Error
        (Printf.sprintf
           "keeper %s declares github_identity %s but credential mapping selected credential_id=%s username=%s gh_config_dir=%s. Update keeper_repo_mappings.toml or the keeper TOML so both credential SSOTs agree."
           keeper_name expected cred.id cred.username gh_config_dir)
  | _ -> (
      match cred.gh_config_dir with
      | None ->
          Error
            (Printf.sprintf
               "credential %s selected for keeper %s has no gh_config_dir"
               cred.id keeper_name)
      | Some raw_gh_config_dir ->
          let gh_config_dir = String.trim raw_gh_config_dir in
          if gh_config_dir = "" then
            Error
              (Printf.sprintf
                 "credential %s selected for keeper %s has empty gh_config_dir"
                 cred.id keeper_name)
          else if not (repo_cli_config_dir_exists gh_config_dir) then
            Error
              (Printf.sprintf
                 "credential %s selected for keeper %s points at missing GH config dir %s"
                 cred.id keeper_name gh_config_dir)
          else
            let git_identity_mode =
              match defaults.git_identity_mode with
              | Some "keeper_alias" -> "keeper_alias"
              | _ -> "github_identity"
            in
            Ok
              (binding_of_identity
                 ~configured_github_identity:(Some cred.username)
                 ~effective_github_identity:cred.username
                 ~credential_scope:Keeper_identity
                 ~git_identity_mode
                 ~bundle_root:(Filename.dirname gh_config_dir)
                 ~gh_config_dir))

let mapped_keeper_binding ~(config : Coord.config) ~keeper_name ~defaults =
  match
    Keeper_repo_mapping.credentials_for_keeper
      ~base_path:config.Coord.base_path ~keeper_id:keeper_name
  with
  | Error reason ->
      Error
        (Printf.sprintf
           "keeper_repo_mappings.toml load error for keeper %s: %s"
           keeper_name reason)
  | Ok [] ->
      Error
        (Printf.sprintf
           "keeper %s has no credential mapping in %s. Add a [mapping.%s] entry \
            with credential_id or repositories; keeper GH subprocesses do not \
            fall back to profile/root credentials."
           keeper_name
           (Config_dir_resolver.keeper_repo_mappings_toml_path
              ~base_path:config.Coord.base_path)
           keeper_name)
  | Ok [ credential ] ->
      binding_of_mapped_credential ~keeper_name ~defaults credential
  | Ok credentials ->
      Error
        (Printf.sprintf
           "keeper %s maps to %d repo CLI credentials; exactly one is required"
           keeper_name (List.length credentials))

let keeper_binding (config : Coord.config) ~(keeper_name : string) :
    (keeper_binding, string) result =
  match Keeper_types_profile.load_keeper_profile_defaults_result keeper_name with
  | Error reason -> Error reason
  | Ok defaults -> mapped_keeper_binding ~config ~keeper_name ~defaults

let keeper_config_dir (config : Coord.config) ~(keeper_name : string) :
    (string, string) result =
  keeper_binding config ~keeper_name
  |> Result.map (fun binding -> binding.gh_config_dir)

(** Prepend [GH_CONFIG_DIR=<dir>] to a gh shell command when a
    keeper-scoped config exists. Scoped to the single subprocess
    invocation — the operator's terminal is unaffected. *)
let with_env (config : Coord.config) (repo_cli_cmd : string) : string =
  let bundle_root = root_bundle_root config in
  Printf.sprintf
    "GH_TOKEN= GITHUB_TOKEN= SSH_AUTH_SOCK= HOME=%s GH_CONFIG_DIR=%s \
     GIT_CONFIG_GLOBAL=%s GIT_CONFIG_COUNT=4 \
     GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*' \
     GIT_CONFIG_KEY_1=credential.helper GIT_CONFIG_VALUE_1= \
     GIT_CONFIG_KEY_2=credential.https://github.com.helper \
     GIT_CONFIG_VALUE_2='!gh auth git-credential' \
     GIT_CONFIG_KEY_3=credential.useHttpPath GIT_CONFIG_VALUE_3=true %s"
    (Filename.quote bundle_root)
    (Filename.quote (root_repo_cli_config_dir config))
    (Filename.quote (Filename.concat bundle_root "gitconfig"))
    repo_cli_cmd

(* Compose base env for a repo CLI/git subprocess.

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
let compose_base_with_repo_cli_config ~dir =
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
    ]
    @ git_config_env_entries
  in
  Array.of_list (scoped @ without_existing_config)

let process_env (config : Coord.config) : string array option =
  Some (compose_base_with_repo_cli_config ~dir:(root_repo_cli_config_dir config))

let keeper_process_env (config : Coord.config) ~(keeper_name : string) :
    (string array option, string) result =
  keeper_config_dir config ~keeper_name
  |> Result.map (fun dir -> Some (compose_base_with_repo_cli_config ~dir))
