(** Keeper-scoped GitHub credential isolation.

    SSOT for [GH_CONFIG_DIR] handling. It scopes [gh] subprocess
    invocations to the selected credential bundle instead of
    the operator's ambient credentials.

    Extracted to its own module to avoid circular dependencies
    (credential_bundle is a shared SSOT for GitHub credential handling)
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
  credential_bundle_dir : string;
}

let bundle_root (config : Workspace.config) ~(credential_identity : string) =
  Filename.concat
    (Filename.concat (Workspace.masc_dir config) "credentials")
    credential_identity

let root_bundle_root config =
  bundle_root config ~credential_identity:root_credential_identity

let credential_bundle_dir_of_root bundle_root =
  Filename.concat bundle_root "gh"

let root_credential_bundle_dir config =
  credential_bundle_dir_of_root (root_bundle_root config)

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

let credential_bundle_dir_exists dir =
  Sys.file_exists dir && Sys.is_directory dir

let binding_of_credential_identity
    ~(credential_identity : string)
    ~(credential_scope : credential_scope)
    ~(bundle_root : string)
    ~(credential_bundle_dir : string) =
  {
    credential_identity;
    credential_scope;
    bundle_root;
    credential_bundle_dir;
  }

let binding_of_mapped_credential
    ~(keeper_name : string)
    (cred : Repo_manager_types.credential) =
  match cred.credential_bundle_dir with
  | None ->
      Error
        (Printf.sprintf
           "credential %s selected for keeper %s has no credential_bundle_dir"
           cred.id keeper_name)
  | Some raw_credential_bundle_dir ->
      let credential_bundle_dir = String.trim raw_credential_bundle_dir in
      if credential_bundle_dir = "" then
        Error
          (Printf.sprintf
             "credential %s selected for keeper %s has empty credential_bundle_dir"
             cred.id keeper_name)
      else if not (credential_bundle_dir_exists credential_bundle_dir) then
        Error
          (Printf.sprintf
             "credential %s selected for keeper %s points at missing credential bundle dir %s"
             cred.id keeper_name credential_bundle_dir)
      else
        Ok
          (binding_of_credential_identity
             ~credential_identity:cred.username
             ~credential_scope:Keeper_identity
             ~bundle_root:(Filename.dirname credential_bundle_dir)
             ~credential_bundle_dir)

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
            fall back to implicit credentials."
           keeper_name
           (Config_dir_resolver.keeper_repo_mappings_toml_path
              ~base_path:config.Workspace.base_path)
           keeper_name)
  | Ok [ credential ] ->
      binding_of_mapped_credential ~keeper_name credential
  | Ok credentials ->
      Error
        (Printf.sprintf
           "keeper %s maps to %d GitHub credentials; exactly one is required"
           keeper_name (List.length credentials))

let keeper_binding (config : Workspace.config) ~(keeper_name : string) :
    (keeper_binding, string) result =
  mapped_keeper_binding ~config ~keeper_name

(* Compose base env for a Git/GitHub subprocess.

   Order of operations (inside-out):
     1. Start from [Unix.environment ()].
     2. Scrub long-lived host credentials that are consumed by MASC
        in-process and MUST NOT cross into a keeper subprocess or
        sandboxed container.
     3. Prepend the non-interactive git constants so credential prompts
        cannot hang the subprocess on a missing tty.
     4. Strip ambient GH/Git config env and prepend bundle-local
        [HOME], [GH_CONFIG_DIR], [GIT_CONFIG_GLOBAL], and safe.directory
        env so the selected credential bundle wins over operator config.

   See [Env_keeper_scrub] and [Env_git_noninteractive] for the
   canonical lists and their rationale. *)
let compose_base_with_credential_bundle ~dir =
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
