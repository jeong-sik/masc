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

let root_credential_identity = "root"

let credential_scope_to_string = function
  | Keeper_identity -> "keeper_identity"
  | Root_fallback -> "root_fallback"

type keeper_binding = {
  credential_identity : string;
  credential_scope : credential_scope;
  bundle_root : string;
  gh_config_dir : string;
}

let bundle_root (config : Workspace.config) ~(credential_identity : string) =
  Filename.concat
    (Filename.concat (Workspace.masc_dir config) "repo-cli-identities")
    credential_identity

let root_bundle_root config =
  bundle_root config ~credential_identity:root_credential_identity

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
let config_dir (config : Workspace.config) : string option =
  let dir = root_repo_cli_config_dir config in
  if repo_cli_config_dir_exists dir then Some dir else None

let binding_of_credential_identity
    ~(credential_identity : string)
    ~(credential_scope : credential_scope)
    ~(bundle_root : string)
    ~(gh_config_dir : string) =
  {
    credential_identity;
    credential_scope;
    bundle_root;
    gh_config_dir;
  }

let binding_of_mapped_credential
    ~(keeper_name : string)
    (cred : Repo_manager_types.credential) =
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
        Ok
          (binding_of_credential_identity
             ~credential_identity:cred.username
             ~credential_scope:Keeper_identity
             ~bundle_root:(Filename.dirname gh_config_dir)
             ~gh_config_dir)

let mapped_keeper_binding ~(config : Workspace.config) ~keeper_name =
  match
    Keeper_repo_mapping.credentials_for_keeper
      ~base_path:config.Workspace.base_path ~keeper_id:keeper_name
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
              ~base_path:config.Workspace.base_path)
           keeper_name)
  | Ok [ credential ] ->
      binding_of_mapped_credential ~keeper_name credential
  | Ok credentials ->
      Error
        (Printf.sprintf
           "keeper %s maps to %d repo CLI credentials; exactly one is required"
           keeper_name (List.length credentials))

let keeper_binding (config : Workspace.config) ~(keeper_name : string) :
    (keeper_binding, string) result =
  mapped_keeper_binding ~config ~keeper_name

let keeper_config_dir (config : Workspace.config) ~(keeper_name : string) :
    (string, string) result =
  keeper_binding config ~keeper_name
  |> Result.map (fun binding -> binding.gh_config_dir)

(** Prepend [GH_CONFIG_DIR=<dir>] to a gh shell command when a
    keeper-scoped config exists. Scoped to the single subprocess
    invocation — the operator's terminal is unaffected. *)
let with_env (config : Workspace.config) (repo_cli_cmd : string) : string =
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

let process_env (config : Workspace.config) : string array option =
  Some (compose_base_with_repo_cli_config ~dir:(root_repo_cli_config_dir config))

let keeper_process_env (config : Workspace.config) ~(keeper_name : string) :
    (string array option, string) result =
  keeper_config_dir config ~keeper_name
  |> Result.map (fun dir -> Some (compose_base_with_repo_cli_config ~dir))
