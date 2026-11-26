(* An official client reads instructions, skills and settings from its cwd.
   Codex reads AGENTS.md and repo [.agents/skills] up to the nearest project
   root (codex-rs/core/src/agents_md.rs, codex-rs/ext/skills/src/host_roots.rs),
   and [Runtime_codex_app_server.client_argv] sets [project_root_markers=[]] so
   that walk stops at the cwd. Vibe reads AGENTS.md, [.vibe/config.toml] and
   [.vibe/agents/] in a folder it trusts. Codex and Vibe also read inside the
   cwd without asking, and at [Native_full] write there
   (RFC-vibe-holds-the-native-posture-with-its-own-tool-allowlist). base_path
   is the operator's own checkout, with the operator's AGENTS.md and skills in
   it, so it is never the cwd (#39444). A Keeper whose sandbox mounts its host
   tree runs in that tree; every other Keeper runs in a private directory of
   its own under the MASC runtime root, one per client.
   HIGH-RISK-UNREVIEWED: this cwd is also the writable workspace root of the
   [:workspace] permission profile a Native_full Codex Keeper runs under, and
   the folder a Native_full ACP host writes in without asking. *)

type client =
  | Codex_app_server
  | Acp

let private_workspaces = function
  | Codex_app_server -> "codex-workspaces"
  | Acp -> "acp-workspaces"
;;

let client_label = function
  | Codex_app_server -> "Codex"
  | Acp -> "ACP"
;;

let resolve ~base_path ~keeper_name ~sandbox_profile client =
  let workspace_must rule =
    Error (Printf.sprintf "the Keeper %s workspace must %s" (client_label client) rule)
  in
  let workspaces = private_workspaces client in
  let located =
    Option.map
      (fun profile -> profile, Keeper_types_profile_sandbox.tree_location_of_profile profile)
      sandbox_profile
  in
  try
    match located with
    | Some (profile, Keeper_types_profile_sandbox.Shared_mount) ->
      ignore
        (Keeper_alerting_path.ensure_sandbox_bundle_for_profile
           ~config:(Workspace.default_config base_path) ~name:keeper_name
           ~sandbox_profile:profile
         : string list);
      let rel = Keeper_sandbox.host_root_rel_of_profile profile keeper_name in
      let expected = Filename.concat (Unix.realpath base_path) rel in
      let canonical = Unix.realpath (Filename.concat base_path rel) in
      if String.equal canonical (Env_config_core.strip_trailing_slashes expected)
      then Ok canonical
      else Error "the Keeper host tree must not traverse symbolic links"
    | Some (_, Keeper_types_profile_sandbox.Endpoint_owned) | None ->
      let canonical_base = Unix.realpath base_path in
      let identity = Agent_core_sha256.(to_hex (digest_string keeper_name)) in
      let segments = [ Common.masc_dirname; "official-clients"; workspaces; identity ] in
      let rec ensure_no_symlink_in_prefix current = function
        | [] -> Ok ()
        | segment :: rest ->
          let next = Filename.concat current segment in
          (match Unix.lstat next with
           | st ->
             if st.Unix.st_kind <> Unix.S_DIR
             then workspace_must "not traverse symbolic links"
             else ensure_no_symlink_in_prefix next rest
           | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ())
      in
      (match ensure_no_symlink_in_prefix canonical_base segments with
       | Error _ as err -> err
       | Ok () ->
         let dir =
           List.fold_left
             Filename.concat
             (Common.masc_dir_from_base_path ~base_path:canonical_base)
             [ "official-clients"; workspaces; identity ]
         in
         Fs_compat.mkdir_p dir;
         let st = Unix.lstat dir in
         if st.Unix.st_kind <> Unix.S_DIR
         then workspace_must "not traverse symbolic links"
         else if st.Unix.st_uid <> Unix.geteuid ()
         then workspace_must "be owned by the current user"
         else (
           let canonical = Unix.realpath dir in
           if not (String.equal canonical (Env_config_core.strip_trailing_slashes dir))
           then workspace_must "not traverse symbolic links"
           else (
             Unix.chmod canonical 0o700;
             Ok canonical)))
  with
  | Sys_error detail -> Error detail
  | Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)
;;
