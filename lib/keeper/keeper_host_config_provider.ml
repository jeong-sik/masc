(** See {!Keeper_host_config_provider} interface. *)

(* RFC-0084 host-config-cleanup-A — credential root migration.
   Was: ad-hoc literal string for the credential root.  Now delegates
   to the typed [Host_config.host] surface so the
   constant has a single source of truth.  Behaviour is byte-identical
   today (the field's value matches the previous literal at PR-1
   author time); a future PR can flip [host] to a
   [resolve ~base_path]-relative value without touching this module. *)
let cred_root = (Host_config.host ()).cred_root
let explicit_ssh_key_container_path =
  Filename.concat (Filename.concat cred_root ".ssh") "id_credential"

let mount_if_present ~host ~container : Keeper_credential_provider.ro_mount list =
  if host = "" then []
  else if not (Sys.file_exists host) then []
  else [ { host; container } ]

(* ── Skipped credential mount warnings ─────────────────────────

   [mount_if_present] silently drops mounts whose host path is empty
   or missing.  The selected credential bundle is a required credential
   mount, so the composition layer reports that absence as an explicit
   error before docker dispatch.

   Fires at [compose_ro_mounts_result] (one observation point per keeper
   sandbox launch), not inside [mount_if_present] which is exposed
   via [For_testing] and must stay pure. *)
type mount_attempt = {
  label : string;
  host : string;
  status : [ `Mounted | `Empty | `Not_found ];
}

let classify_mount_attempt ~label ~host : mount_attempt =
  let status =
    if host = "" then `Empty
    else if not (Sys.file_exists host) then `Not_found
    else `Mounted
  in
  { label; host; status }

let warn_mount_skips_if_any ~keeper_name (attempts : mount_attempt list) =
  let skipped =
    List.filter
      (fun a -> match a.status with `Mounted -> false | _ -> true)
      attempts
  in
  if skipped = [] then ()
  else begin
    List.iter
      (fun a ->
        let reason =
          match a.status with
          | `Empty -> "empty"
          | `Not_found -> "not_found"
          | `Mounted -> "mounted"
        in
        Prometheus.inc_counter
          "masc_keeper_credential_mount_skipped_total"
          ~labels:[ ("keeper", keeper_name); ("mount", a.label);
                    ("reason", reason) ]
          ())
      skipped;
    let pp_skip a =
      let r = match a.status with
        | `Empty -> "empty"
        | `Not_found -> "not_found"
        | `Mounted -> "mounted"
      in
      Printf.sprintf "%s(%s)" a.label r
    in
    Log.Keeper.warn
      "%s: sandbox credential mount(s) skipped; keeper docker dispatch \
       will fail before credentials are projected. Skipped: [%s]. \
       Resolution: materialize the selected credential bundle under \
       $base_path/.masc/credentials. See \
       [host_config_provider.ml compose_ro_mounts_result]."
      keeper_name
      (String.concat "; " (List.map pp_skip skipped))
  end

(* Env composition for the selected credential bundle inside the docker
   credential dispatch container.  Ambient operator credential env is
   scrubbed before callers reach this provider; this block exposes only
   container-local GH/Git paths plus non-interactive git guards. *)
let compose_env ?ssh_key_container ~git_author_name ~git_author_email () =
  let ssh_env =
    match ssh_key_container with
    | None -> []
    | Some key ->
        [
          ( "GIT_SSH_COMMAND",
            Printf.sprintf
              "ssh -i %s -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
              (Filename.quote key) );
        ]
  in
  [
    "HOME", cred_root;
    "GH_CONFIG_DIR", Filename.concat cred_root ".config/gh";
    "GIT_CONFIG_GLOBAL", Filename.concat cred_root ".gitconfig";
    "GIT_AUTHOR_NAME", git_author_name;
    "GIT_AUTHOR_EMAIL", git_author_email;
    "GIT_COMMITTER_NAME", git_author_name;
    "GIT_COMMITTER_EMAIL", git_author_email;
  ]
  @ Credential_bundle.git_config_env_pairs
  @ ssh_env
  @ Env_git_noninteractive.env

let required_mount_result (attempt : mount_attempt) ~container =
  match attempt.status with
  | `Mounted -> Ok Keeper_credential_provider.{ host = attempt.host; container }
  | `Empty ->
      Error
        (Printf.sprintf
           "required credential mount %s has an empty host path"
           attempt.label)
  | `Not_found ->
      Error
        (Printf.sprintf
           "required credential mount %s host path is missing"
           attempt.label)

let compose_ro_mounts_result ?keeper_name
    (kb : Credential_bundle.keeper_binding) =
  let credential_bundle_dir = kb.credential_bundle_dir in
  let identity_gitconfig = Filename.concat kb.bundle_root "gitconfig" in
  let identity_ssh_dir = Filename.concat kb.bundle_root "ssh" in
  let gitconfig =
    if Sys.file_exists identity_gitconfig then identity_gitconfig else ""
  in
  let ssh_dir =
    if Sys.file_exists identity_ssh_dir && Sys.is_directory identity_ssh_dir then
      identity_ssh_dir
    else ""
  in
  let credential_bundle_attempt =
    classify_mount_attempt ~label:"credential_bundle" ~host:credential_bundle_dir
  in
  let attempts = [ credential_bundle_attempt ] in
  Option.iter
    (fun name -> warn_mount_skips_if_any ~keeper_name:name attempts)
    keeper_name;
  match
    required_mount_result credential_bundle_attempt
      ~container:(Filename.concat cred_root ".config/gh")
  with
  | Error _ as err -> err
  | Ok credential_bundle_mount ->
      Ok
        (credential_bundle_mount
         :: (mount_if_present ~host:gitconfig
               ~container:(Filename.concat cred_root ".gitconfig")
            @ mount_if_present ~host:ssh_dir
                ~container:(Filename.concat cred_root ".ssh")))

let resolve_git_identity (kb : Credential_bundle.keeper_binding) ~keeper_name =
  ignore keeper_name;
  ( kb.credential_identity,
    kb.credential_identity ^ "@users.noreply.github.com" )

let metadata_of_binding (kb : Credential_bundle.keeper_binding) =
  [ "source", "host_config";
    "credential_identity", kb.credential_identity;
    "credential_scope",
    Credential_bundle.credential_scope_to_string kb.credential_scope;
    "bundle_root", kb.bundle_root;
  ]

(* RFC-0019 bridge to the multi-repo credential store.  A keeper must have a
   [Keeper_repo_mapping] entry that resolves to exactly one
   [Credential_store] credential.  The old host-config resolver fallback is
   intentionally gone: a missing or unreadable mapping is a configuration
   error, not permission to infer an identity from legacy keeper profile
   fields. *)
let count_resolve_outcome ~keeper_name ~source ~reason =
  Prometheus.inc_counter
    "keeper_credential_provider_resolve_total"
    ~labels:
      [ ("keeper", keeper_name); ("source", source); ("reason", reason) ]
    ()

let bind_from_keeper_binding ?ssh_key_path ~keeper_name
    (kb : Credential_bundle.keeper_binding) ~extra_metadata =
  let git_author_name, git_author_email =
    resolve_git_identity kb ~keeper_name
  in
  let ssh_key_container =
    Option.map (fun _ -> explicit_ssh_key_container_path) ssh_key_path
  in
  let env =
    compose_env ?ssh_key_container ~git_author_name ~git_author_email ()
  in
  match compose_ro_mounts_result ~keeper_name kb with
  | Error reason ->
      Error
        (Keeper_credential_provider.Missing_bundle
           { identity = keeper_name; path = reason })
  | Ok bundle_mounts ->
    let ro_mounts =
      bundle_mounts
      @
      match ssh_key_path with
      | None -> []
      | Some host ->
          [
            Keeper_credential_provider.
              { host; container = explicit_ssh_key_container_path };
          ]
    in
    (* Deterministic credential preflight.

       Keeper credential is selected by keeper_repo_mappings.toml and
       credentials.toml.  Do not probe [gh auth status] here: stale or
       rejected tokens should surface on the first real scoped gh/git
       operation, not through a separate identity check that can drift from
       the configured provider path.  We only require a projectable
       hosts.yml token because keyring-only host auth cannot be mounted into
       Docker. *)
    (match
       Credential_materializer.compute_token_sha256_prefix
         ~credential_bundle_dir:kb.credential_bundle_dir
     with
     | Some _ ->
         let metadata = metadata_of_binding kb @ extra_metadata in
         Ok
           Keeper_credential_provider.
             {
               identity = kb.credential_identity;
               env;
               ro_mounts;
               bootstrap = None;
               metadata;
             }
     | None ->
        Error
          (Keeper_credential_provider.Missing_bundle
             { identity = keeper_name
             ; path =
                 Printf.sprintf
                   "credential bundle %s has no projectable hosts.yml \
                    oauth_token. Resolution: materialize via dashboard or \
                    gh auth login --with-token into the bundle."
                   kb.credential_bundle_dir
             }))

(* Synthesise a [Credential_bundle.keeper_binding] from a credential store
   record.  PR-A convention: [bundle_root = dirname credential_bundle_dir].  This
   matches the existing host bundle layout
   (<base>/.masc/credentials/<id>/gh) but tolerates operator-set
   custom paths — sibling files (gitconfig, ssh) that happen to live next
   to [credential_bundle_dir] are picked up by [compose_ro_mounts_result] via
   [mount_if_present]; absent siblings are optional. *)
let binding_of_credential (cred : Repo_manager_types.credential)
    : (Credential_bundle.keeper_binding, string) result =
  match cred.credential_bundle_dir with
  | None ->
      Error
        (Printf.sprintf
           "credential %s has no credential_bundle_dir; the PR-A bridge cannot \
            materialise an unmaterialised credential. Resolution: \
            populate credential_bundle_dir via dashboard or `gh auth login` \
            into the bundle path, then retry."
           cred.id)
  | Some "" ->
      Error
        (Printf.sprintf
           "credential %s has empty credential_bundle_dir" cred.id)
  | Some credential_bundle_dir ->
      (* Local name [synth_bundle_root] avoids field punning collision
         with the [Credential_bundle.bundle_root] function that the
         [Credential_bundle.{ ... }] qualified record syntax brings into
         scope. *)
      let synth_bundle_root = Filename.dirname credential_bundle_dir in
      Ok
        Credential_bundle.
          {
            credential_identity = cred.username;
            credential_scope = Keeper_identity;
            bundle_root = synth_bundle_root;
            credential_bundle_dir;
          }

let bind_from_credential ~keeper_name (cred : Repo_manager_types.credential) =
  match binding_of_credential cred with
  | Error reason ->
      Error
        (Keeper_credential_provider.Missing_bundle
           { identity = keeper_name; path = reason })
  | Ok kb ->
      let ssh_key_path =
        match cred.ssh_key_path with
        | Some path ->
            let trimmed = String.trim path in
            if trimmed <> "" then Some trimmed else None
        | None -> None
      in
      (match ssh_key_path with
      | Some path when not (Sys.file_exists path) ->
          Error
            (Keeper_credential_provider.Missing_bundle
               { identity = keeper_name
               ; path =
                   Printf.sprintf
                     "credential %s ssh_key_path %S does not exist"
                     cred.id path
               })
      | Some path when Sys.is_directory path ->
          Error
            (Keeper_credential_provider.Missing_bundle
               { identity = keeper_name
               ; path =
                   Printf.sprintf
                     "credential %s ssh_key_path %S is a directory; \
                      expected a private key file"
                     cred.id path
               })
      | _ ->
          bind_from_keeper_binding ?ssh_key_path ~keeper_name kb
            ~extra_metadata:
              ([ ("credential_source", "credential_store");
                 ("credential_id", cred.id) ]
              @
              match ssh_key_path with
              | None -> []
              | Some path -> [ ("ssh_key_path", path) ]))

let resolve ~config ~identity:keeper_name =
  match
    Keeper_repo_mapping.credentials_for_keeper
      ~base_path:config.Workspace.base_path ~keeper_id:keeper_name
  with
  | Error err ->
      count_resolve_outcome ~keeper_name ~source:"credential_store"
        ~reason:"mapping_load_error";
      Error
        (Keeper_credential_provider.Missing_bundle
           { identity = keeper_name
           ; path =
               Printf.sprintf
                 "keeper_repo_mappings.toml load error for keeper %s: %s. \
                  Credential-store mapping is required; fix the TOML instead \
                  of falling back to legacy host_config_provider identity."
                 keeper_name err
           })
  | Ok [] ->
      count_resolve_outcome ~keeper_name ~source:"credential_store"
        ~reason:"missing_mapping";
      Error
        (Keeper_credential_provider.Missing_bundle
           { identity = keeper_name
           ; path =
               Printf.sprintf
                 "keeper %s has no credential mapping in %s. Add a \
                  [mapping.%s] entry with credential_id or repositories; \
                  legacy host_config_provider fallback has been removed."
                 keeper_name
                 (Config_dir_resolver.keeper_repo_mappings_toml_path
                    ~base_path:config.Workspace.base_path)
                 keeper_name
           })
  | Ok [cred] ->
      count_resolve_outcome ~keeper_name ~source:"credential_store"
        ~reason:"single_mapping";
      bind_from_credential ~keeper_name cred
  | Ok many ->
      count_resolve_outcome ~keeper_name ~source:"ambiguous"
        ~reason:"multi_mapping";
      let ids =
        List.map (fun (c : Repo_manager_types.credential) -> c.id) many
      in
      Error
        (Keeper_credential_provider.Missing_bundle
           { identity = keeper_name
           ; path =
               Printf.sprintf
                 "keeper %s has %d credentials mapped (%s); RFC-0019 \
                  PR-A resolves only single-credential keepers. \
                  Per-repo dispatch is delivered in PR-B \
                  (resolve_for_repo)."
                 keeper_name (List.length many) (String.concat ", " ids)
           })

let finalize (_b : Keeper_credential_provider.binding) ~container_id:_ =
  (* PR-1: noop.  PR-3 will rewrite hosts.yml:user inside the
     container after `gh auth login --with-token` runs. *)
  Ok ()

let tear_down (_b : Keeper_credential_provider.binding) ~container_id:_ =
  (* PR-1: noop.  The RO mount lifetime equals the `docker run`
     lifetime; nothing to unmount. *)
  ()

module For_testing = struct
  let compose_env ?ssh_key_container ~git_author_name ~git_author_email () =
    compose_env ?ssh_key_container ~git_author_name ~git_author_email ()

  let mount_if_present = mount_if_present
  let compose_ro_mounts_result = compose_ro_mounts_result
end
