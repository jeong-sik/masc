(** See {!Host_config_provider} interface. *)

let cred_root = "/tmp/keeper-creds"

let mount_if_present ~host ~container : Credential_provider.ro_mount list =
  if host = ""
  then []
  else if not (Sys.file_exists host)
  then []
  else [ { host; container } ]
;;

(* RFC-0008 PR-1: env composition mirrors the inline block at
   keeper_shell_docker.ml:271-329 (pre-extraction).  No new env keys
   are introduced; this is the same surface, concentrated. *)
let compose_env ~git_author_name ~git_author_email =
  [ "HOME", cred_root
  ; "GH_CONFIG_DIR", Filename.concat cred_root ".config/gh"
  ; "GIT_CONFIG_GLOBAL", Filename.concat cred_root ".gitconfig"
  ; "GIT_CONFIG_COUNT", "1"
  ; "GIT_CONFIG_KEY_0", "safe.directory"
  ; "GIT_CONFIG_VALUE_0", "*"
  ; "GIT_AUTHOR_NAME", git_author_name
  ; "GIT_AUTHOR_EMAIL", git_author_email
  ; "GIT_COMMITTER_NAME", git_author_name
  ; "GIT_COMMITTER_EMAIL", git_author_email
  ]
  @ Env_git_noninteractive.env
;;

let compose_ro_mounts (kb : Keeper_gh_env.keeper_binding) =
  let gh_creds =
    match kb.gh_config_dir with
    | Some dir -> dir
    | None -> Env_config_sandbox.Auth_paths.gh_creds ()
  in
  let gitconfig = Env_config_sandbox.Auth_paths.gitconfig () in
  let ssh_dir = Env_config_sandbox.Auth_paths.ssh_dir () in
  mount_if_present ~host:gh_creds ~container:(Filename.concat cred_root ".config/gh")
  @ mount_if_present ~host:gitconfig ~container:(Filename.concat cred_root ".gitconfig")
  @ mount_if_present ~host:ssh_dir ~container:(Filename.concat cred_root ".ssh")
;;

let resolve_git_identity (kb : Keeper_gh_env.keeper_binding) ~keeper_name =
  match kb.github_identity, kb.git_identity_mode with
  | Some id, "github_identity" -> id, id ^ "@users.noreply.github.com"
  | _ ->
    ( Keeper_identity.keeper_git_author ~keeper_name
    , Keeper_identity.keeper_git_email ~keeper_name )
;;

let metadata_of_binding (kb : Keeper_gh_env.keeper_binding) =
  let base = [ "source", "host_config"; "git_identity_mode", kb.git_identity_mode ] in
  match kb.github_identity with
  | Some id -> base @ [ "github_identity", id ]
  | None -> base
;;

let resolve ~config ~identity:keeper_name =
  match Keeper_gh_env.keeper_binding config ~keeper_name with
  | Error reason ->
    Error (Credential_provider.Missing_bundle { identity = keeper_name; path = reason })
  | Ok kb ->
    let git_author_name, git_author_email = resolve_git_identity kb ~keeper_name in
    let env = compose_env ~git_author_name ~git_author_email in
    let ro_mounts = compose_ro_mounts kb in
    let metadata = metadata_of_binding kb in
    Ok
      Credential_provider.
        { identity = keeper_name; env; ro_mounts; bootstrap = None; metadata }
;;

let finalize (_b : Credential_provider.binding) ~container_id:_ =
  (* PR-1: noop.  PR-3 will rewrite hosts.yml:user inside the
     container after `gh auth login --with-token` runs. *)
  Ok ()
;;

let tear_down (_b : Credential_provider.binding) ~container_id:_ =
  (* PR-1: noop.  The RO mount lifetime equals the `docker run`
     lifetime; nothing to unmount. *)
  ()
;;

module For_testing = struct
  let compose_env = compose_env
  let mount_if_present = mount_if_present
end
