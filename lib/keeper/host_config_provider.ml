(** See {!Host_config_provider} interface. *)

let cred_root = "/tmp/keeper-creds"
let explicit_ssh_key_container_path =
  Filename.concat (Filename.concat cred_root ".ssh") "id_credential"

let mount_if_present ~host ~container : Credential_provider.ro_mount list =
  if host = "" then []
  else if not (Sys.file_exists host) then []
  else [ { host; container } ]

(* ── Skipped credential mount warn dedup ───────────────────────

   [mount_if_present] silently drops mounts whose host path is empty
   or missing.  For the selected GH config bundle this would make a
   keeper git/gh dispatch fail later with an opaque CLI error, so the
   composition layer emits a single diagnostic and [resolve] fail-closes
   when no credential mount remains.

   Fires at [compose_ro_mounts] (one observation point per keeper
   sandbox launch), not inside [mount_if_present] which is exposed
   via [For_testing] and must stay pure. *)
let mount_skip_warn_emitted : (string, unit) Hashtbl.t = Hashtbl.create 16
let mount_skip_warn_mu = Eio.Mutex.create ()

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
    let should_emit =
      Eio.Mutex.use_rw ~protect:true mount_skip_warn_mu (fun () ->
        if Hashtbl.mem mount_skip_warn_emitted keeper_name then false
        else begin
          Hashtbl.add mount_skip_warn_emitted keeper_name ();
          true
        end)
    in
    if should_emit then begin
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
        Printf.sprintf "%s=%s(%s)" a.label
          (if a.host = "" then "<empty>" else a.host) r
      in
      Log.Keeper.warn
        "%s: sandbox credential mount(s) skipped — keeper inside docker \
         will be missing the corresponding host credential.  Skipped: \
         [%s].  Resolution: install the selected root/keeper GitHub \
         identity bundle under $base_path/.masc/github-identities.  See \
         [host_config_provider.ml compose_ro_mounts]."
        keeper_name
        (String.concat "; " (List.map pp_skip skipped))
    end
  end

(* Env composition for the selected identity bundle inside the docker
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
    "GIT_CONFIG_COUNT", "1";
    "GIT_CONFIG_KEY_0", "safe.directory";
    "GIT_CONFIG_VALUE_0", "*";
    "GIT_AUTHOR_NAME", git_author_name;
    "GIT_AUTHOR_EMAIL", git_author_email;
    "GIT_COMMITTER_NAME", git_author_name;
    "GIT_COMMITTER_EMAIL", git_author_email;
  ]
  @ ssh_env
  @ Env_git_noninteractive.env

let compose_ro_mounts ?keeper_name (kb : Keeper_gh_env.keeper_binding) =
  let gh_creds = kb.gh_config_dir in
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
  let attempts = [
    classify_mount_attempt ~label:"gh_creds" ~host:gh_creds;
  ] in
  Option.iter
    (fun name -> warn_mount_skips_if_any ~keeper_name:name attempts)
    keeper_name;
  mount_if_present ~host:gh_creds
    ~container:(Filename.concat cred_root ".config/gh")
  @ mount_if_present ~host:gitconfig
      ~container:(Filename.concat cred_root ".gitconfig")
  @ mount_if_present ~host:ssh_dir
      ~container:(Filename.concat cred_root ".ssh")

let resolve_git_identity (kb : Keeper_gh_env.keeper_binding) ~keeper_name =
  match kb.github_identity, kb.git_identity_mode with
  | Some id, "github_identity" ->
      id, id ^ "@users.noreply.github.com"
  | _ ->
      Keeper_identity.keeper_git_author ~keeper_name,
      Keeper_identity.keeper_git_email ~keeper_name

let metadata_of_binding (kb : Keeper_gh_env.keeper_binding) =
  let base =
    [ "source", "host_config";
      "git_identity_mode", kb.git_identity_mode;
      "effective_github_identity", kb.effective_github_identity;
      "credential_scope",
      Keeper_gh_env.credential_scope_to_string kb.credential_scope;
      "bundle_root", kb.bundle_root;
    ]
  in
  match kb.github_identity with
  | Some id -> base @ [ "github_identity", id ]
  | None -> base

(* RFC-0019 PR-A — bridge to the multi-repo credential store
   (#12304).  When a keeper has a [Keeper_repo_mapping] entry that
   resolves to exactly one [Credential_store] credential we synthesise
   a [Keeper_gh_env.keeper_binding] from that credential and reuse the
   existing [compose_env]/[compose_ro_mounts] flow verbatim, preserving
   every fail-closed semantics and warning the legacy path already
   carries.  Keepers with no mapping fall through to [legacy_resolve]
   exactly as before.

   See [docs/rfc/RFC-0019-keeper-credential-unification.md] §4.2 and §5
   (PR-A) for the rationale.  Per-repo dispatch for keepers with
   multiple mapped credentials is delivered in PR-B; PR-A reports
   such keepers as [Missing_bundle] with an actionable [path] field. *)
let count_resolve_outcome ~keeper_name ~source ~reason =
  Prometheus.inc_counter
    "keeper_credential_provider_resolve_total"
    ~labels:
      [ ("keeper", keeper_name); ("source", source); ("reason", reason) ]
    ()

let bind_from_keeper_binding ?ssh_key_path ~keeper_name
    (kb : Keeper_gh_env.keeper_binding) ~extra_metadata =
  let git_author_name, git_author_email =
    resolve_git_identity kb ~keeper_name
  in
  let ssh_key_container =
    Option.map (fun _ -> explicit_ssh_key_container_path) ssh_key_path
  in
  let env =
    compose_env ?ssh_key_container ~git_author_name ~git_author_email ()
  in
  let ro_mounts =
    compose_ro_mounts ~keeper_name kb
    @
    match ssh_key_path with
    | None -> []
    | Some host ->
        [
          Credential_provider.
            { host; container = explicit_ssh_key_container_path };
        ]
  in
  (* β7 fail-closed: resolve is called only when git_creds_enabled
     (caller at keeper_shell_docker.ml:398-400).  If ALL credential
     host paths are empty or missing, ro_mounts will be [].  Returning
     Ok with empty mounts lets the keeper start in Docker with no
     credential files — gh/git commands then fail with confusing 401
     or "permission denied" errors.  Return Error so the caller
     reports the real cause at sandbox creation time. *)
  if ro_mounts = [] then
    Error
      (Credential_provider.Missing_bundle
         { identity = keeper_name
         ; path = "all credential host paths empty or missing"
         })
  else
    let metadata = metadata_of_binding kb @ extra_metadata in
    Ok
      Credential_provider.
        {
          identity = kb.effective_github_identity;
          env;
          ro_mounts;
          bootstrap = None;
          metadata;
        }

let legacy_resolve ~config ~keeper_name =
  match Keeper_gh_env.keeper_binding config ~keeper_name with
  | Error reason ->
      Error
        (Credential_provider.Missing_bundle
           { identity = keeper_name; path = reason })
  | Ok kb -> bind_from_keeper_binding ~keeper_name kb ~extra_metadata:[]

(* Synthesise a [Keeper_gh_env.keeper_binding] from a credential store
   record.  PR-A convention: [bundle_root = dirname gh_config_dir].  This
   matches the existing host bundle layout
   (<base>/.masc/github-identities/<id>/gh) but tolerates operator-set
   custom paths — sibling files (gitconfig, ssh) that happen to live next
   to [gh_config_dir] are picked up by [compose_ro_mounts] via
   [mount_if_present]; absent siblings are silently skipped, just as in
   the legacy path. *)
let binding_of_credential (cred : Repo_manager_types.credential)
    : (Keeper_gh_env.keeper_binding, string) result =
  match cred.gh_config_dir with
  | None ->
      Error
        (Printf.sprintf
           "credential %s has no gh_config_dir; the PR-A bridge cannot \
            materialise an unmaterialised credential. Resolution: \
            populate gh_config_dir via dashboard or `gh auth login` \
            into the bundle path, then retry."
           cred.id)
  | Some "" ->
      Error
        (Printf.sprintf
           "credential %s has empty gh_config_dir" cred.id)
  | Some gh_config_dir ->
      (* Local name [synth_bundle_root] avoids field punning collision
         with the [Keeper_gh_env.bundle_root] function that the
         [Keeper_gh_env.{ ... }] qualified record syntax brings into
         scope. *)
      let synth_bundle_root = Filename.dirname gh_config_dir in
      Ok
        Keeper_gh_env.
          {
            github_identity = Some cred.username;
            effective_github_identity = cred.username;
            credential_scope = Keeper_identity;
            git_identity_mode = "github_identity";
            bundle_root = synth_bundle_root;
            gh_config_dir;
          }

let bind_from_credential ~keeper_name (cred : Repo_manager_types.credential) =
  match binding_of_credential cred with
  | Error reason ->
      Error
        (Credential_provider.Missing_bundle
           { identity = keeper_name; path = reason })
  | Ok kb ->
      let ssh_key_path =
        match cred.ssh_key_path with
        | Some path when String.trim path <> "" -> Some (String.trim path)
        | _ -> None
      in
      (match ssh_key_path with
      | Some path when not (Sys.file_exists path) ->
          Error
            (Credential_provider.Missing_bundle
               { identity = keeper_name
               ; path =
                   Printf.sprintf
                     "credential %s ssh_key_path %S does not exist"
                     cred.id path
               })
      | Some path when Sys.is_directory path ->
          Error
            (Credential_provider.Missing_bundle
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
      ~base_path:config.Coord.base_path ~keeper_id:keeper_name
  with
  | Error err ->
      (* Mapping store unreadable — treat as infra error, not absence.
         Fall through to legacy resolver so a corrupt
         [keeper_repo_mappings.toml] does not break previously-working
         keepers. *)
      count_resolve_outcome ~keeper_name ~source:"legacy"
        ~reason:"mapping_load_error";
      Log.Keeper.warn
        "%s: keeper_repo_mapping load error (%s); falling back to \
         legacy host_config_provider resolver"
        keeper_name err;
      legacy_resolve ~config ~keeper_name
  | Ok [] ->
      count_resolve_outcome ~keeper_name ~source:"legacy"
        ~reason:"no_mapping";
      legacy_resolve ~config ~keeper_name
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
        (Credential_provider.Missing_bundle
           { identity = keeper_name
           ; path =
               Printf.sprintf
                 "keeper %s has %d credentials mapped (%s); RFC-0019 \
                  PR-A resolves only single-credential keepers. \
                  Per-repo dispatch is delivered in PR-B \
                  (resolve_for_repo)."
                 keeper_name (List.length many) (String.concat ", " ids)
           })

let finalize (_b : Credential_provider.binding) ~container_id:_ =
  (* PR-1: noop.  PR-3 will rewrite hosts.yml:user inside the
     container after `gh auth login --with-token` runs. *)
  Ok ()

let tear_down (_b : Credential_provider.binding) ~container_id:_ =
  (* PR-1: noop.  The RO mount lifetime equals the `docker run`
     lifetime; nothing to unmount. *)
  ()

module For_testing = struct
  let compose_env ?ssh_key_container ~git_author_name ~git_author_email () =
    compose_env ?ssh_key_container ~git_author_name ~git_author_email ()

  let mount_if_present = mount_if_present
end
