(** Coord Worktree - Sandbox clone lifecycle.

    Inspect / repair / auto-provision the per-keeper sandbox clone under
    [<base_path>/repos/<keeper>/<repo_name>/].  The clone is what
    [worktree_create_r] roots [.worktrees/<task_id>] inside.

    Destructive cleanup on failure is delegated to
    [Coord_worktree_destructive_ops.rm_rf]; cloning itself shells out via
    {!Coord_worktree_exec.run_argv_with_status}.

    Stage 06, godfile decomposition plan 2026-05-18. *)

open Masc_domain
open Coord_utils

type sandbox_clone_state =
  | Ready
  | Needs_checkout of string
  | Broken_git of string

let inspect_sandbox_clone candidate =
  let inside_status, inside_output =
    Coord_worktree_paths.run_git_in_clone candidate
      [ "rev-parse"; "--is-inside-work-tree" ]
  in
  if inside_status <> Unix.WEXITED 0 then
    Broken_git
      (Printf.sprintf "git rev-parse failed: %s"
         (Coord_worktree_paths.trim_output_detail inside_output))
  else
    let top_status, top_output =
      Coord_worktree_paths.run_git_in_clone candidate
        [ "rev-parse"; "--show-toplevel" ]
    in
    if top_status <> Unix.WEXITED 0 then
      Broken_git
        (Printf.sprintf "git rev-parse --show-toplevel failed: %s"
           (Coord_worktree_paths.trim_output_detail top_output))
    else
      match Coord_worktree_exec.first_nonempty_line top_output with
      | Some top ->
          if not (Coord_worktree_paths.same_realpath top candidate) then
            Broken_git
              (Printf.sprintf
                 "git top-level mismatch: expected sandbox clone root %s but \
                  git resolved %s"
                 candidate top)
          else
            let tracked_status, tracked_output =
              Coord_worktree_paths.run_git_in_clone candidate
                [ "ls-files"; "-z" ]
            in
            if tracked_status <> Unix.WEXITED 0 then
              Broken_git
                (Printf.sprintf "git ls-files failed: %s"
                   (Coord_worktree_paths.trim_output_detail tracked_output))
            else
              (match Coord_worktree_paths.first_nul_field tracked_output with
              | None -> Ready
              | Some relpath ->
                  if Coord_worktree_paths.safe_file_exists
                       (Filename.concat candidate relpath)
                  then Ready
                  else Needs_checkout relpath)
      | None ->
          Broken_git "git rev-parse --show-toplevel returned no path"

let restore_sandbox_clone_checkout candidate =
  let checkout_status, checkout_output =
    Coord_worktree_paths.run_git_in_clone candidate
      [ "checkout"; "-f"; "HEAD"; "--"; "." ]
  in
  if checkout_status <> Unix.WEXITED 0 then
    Error
      (System (System_error.IoError
         (Printf.sprintf
            "sandbox_clone_checkout_restore_failed: could not restore tracked \
             files in %s: %s"
            candidate (Coord_worktree_paths.trim_output_detail checkout_output))))
  else
    match inspect_sandbox_clone candidate with
    | Ready ->
        Ok
          (Some
             "Existing sandbox clone checkout was restored from HEAD before \
              worktree creation.")
    | Needs_checkout relpath ->
        Error
          (System (System_error.IoError
             (Printf.sprintf
                "sandbox_clone_checkout_restore_failed: %s is still missing \
                 tracked path %s after checkout."
                candidate relpath)))
    | Broken_git detail ->
        Error
          (System (System_error.IoError
             (Printf.sprintf
                "sandbox_clone_checkout_restore_failed: %s is still not a \
                 usable git clone after checkout: %s"
                candidate detail)))

let ensure_sandbox_clone_ready candidate =
  match inspect_sandbox_clone candidate with
  | Ready -> Ok None
  | Needs_checkout _ -> restore_sandbox_clone_checkout candidate
  | Broken_git detail ->
      Error
        (System (System_error.IoError
           (Printf.sprintf
              "sandbox_clone_invalid: %s has a .git marker but is not a usable git clone: %s"
              candidate detail)))

let missing_sandbox_clone_error ~agent_name ~repos_dir ~repo_name =
  let rel_target, clone_hint =
    match repo_name with
    | Some name when String.trim name <> "" ->
      let rel = Printf.sprintf "repos/%s" name in
      ( rel,
        Printf.sprintf
          "use the visible clone/worktree tool to clone https://github.com/<org>/%s.git into %s"
          name rel )
    | _ ->
      ( "repos/<repo>",
        "use the visible clone/worktree tool to clone https://github.com/<org>/<repo>.git into repos/<repo>" )
  in
  System (System_error.IoError
    (Printf.sprintf
       "missing_sandbox_clone: no sandbox git clone found for agent %s under %s \
        (expected %s). Recovery: %s"
       agent_name repos_dir rel_target clone_hint))

let workspace_repo_not_found_error ~agent_name ~repos_dir ~repo_name
    ~search_root =
  System (System_error.IoError
    (Printf.sprintf
       "missing_sandbox_clone: no sandbox git clone found for agent %s under %s \
        and no workspace git repo named %s was found under %s. Recovery: \
        use the visible clone/worktree tool to clone https://github.com/<org>/%s.git \
        into repos/%s"
       agent_name repos_dir repo_name search_root repo_name repo_name))

let workspace_repo_ambiguous_error ~repo_name ~search_root ~matches =
  System (System_error.IoError
    (Printf.sprintf
       "ambiguous_workspace_repo: found multiple git repos named %s under %s: \
        [%s]. Auto-provision is blocked until the repo is disambiguated; use \
        the visible clone/worktree tool explicitly."
       repo_name search_root (String.concat ", " matches)))

let partial_clone_error ~clone_path ~msg =
  Coord_worktree_destructive_ops.rm_rf clone_path;
  System (System_error.IoError msg)

let normalize_origin_remote_to_https root =
  match Coord_worktree_repo_discovery.git_origin_url root with
  | None -> None
  | Some origin_url ->
      let normalized = Coord_worktree_policy.normalize_github_clone_url origin_url in
      if String.equal origin_url normalized then None
      else
        match
          Coord_worktree_exec.run_argv_with_status
            [ "git"; "-C"; root; "remote"; "set-url"; "origin"; normalized ]
        with
        | Unix.WEXITED 0, _ -> Some normalized
        | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _ -> None

let auto_provision_sandbox_clone ~config ~agent_name ~repos_dir ~repo_name =
  let search_root = Coord_worktree_paths.project_root config in
  match
    Coord_worktree_repo_discovery.workspace_repo_matches ~search_root
      ~repo_name ()
  with
  | [] ->
      Error
        (workspace_repo_not_found_error ~agent_name ~repos_dir ~repo_name
           ~search_root)
  | [ source_root ] ->
      Fs_compat.mkdir_p repos_dir;
      let clone_path = Filename.concat repos_dir repo_name in
      if Coord_worktree_paths.safe_file_exists clone_path then
        if Coord_worktree_paths.is_git_clone clone_path then
          ensure_sandbox_clone_ready clone_path
          |> Result.map (fun repair_note -> (clone_path, repair_note))
        else
          Error
            (System (System_error.IoError
               (Printf.sprintf
                  "sandbox_clone_conflict: %s already exists under %s but is not \
                   a git clone. Remove or repair it, or use keeper_shell \
                   op=git_clone explicitly."
                  repo_name repos_dir)))
      else
        (match Coord_worktree_repo_discovery.git_origin_url source_root with
         | None ->
             Error
               (System (System_error.IoError
                  (Printf.sprintf
                     "auto_provision_clone_failed: workspace repo %s has no origin remote. \
                      Sandbox auto-provision requires cloning from origin, not from the local checkout."
                     source_root)))
         | Some origin_url -> (
             match
               Coord_worktree_policy.validate_clone_origin_url
                 ~base_path:config.base_path origin_url
             with
             | Error err ->
                 Error
                   (System (System_error.IoError
                      (Printf.sprintf
                         "auto_provision_clone_failed: origin %s rejected by clone policy: %s"
                         origin_url err)))
             | Ok () ->
                 let origin_url =
                   Coord_worktree_policy.normalize_github_clone_url origin_url
                 in
                 (* Network-bound clone: default local_op_timeout_sec (30s)
                    aborts at ~25% on 6464-file repos (#9587 same root).
                    Use the longer git_fetch_timeout_sec budget. *)
                 let status, output =
                   Coord_worktree_exec.run_argv_with_status
                     ~timeout_sec:(Env_config_core.git_fetch_timeout_sec ())
                     [ "git"; "clone"; origin_url; clone_path ]
                 in
                 if status <> Unix.WEXITED 0 then
                   Error
                     (partial_clone_error ~clone_path
                        ~msg:
                          (Printf.sprintf
                             "auto_provision_clone_failed: git clone from origin %s \
                              into %s failed: %s"
                             origin_url clone_path
                             (let detail = String.trim output in
                              if detail = "" then "(no output)" else detail)))
                 else
                   Ok
                     ( clone_path,
                       Some
                         (Printf.sprintf
                            "Sandbox clone auto-provisioned from %s."
                            (match
                               Coord_worktree_policy.extract_github_org_repo
                                 origin_url
                             with
                             | Some org_repo ->
                                 "https://github.com/" ^ org_repo ^ ".git"
                             | None -> "a validated local workspace origin")) )))
  | matches ->
      Error
        (workspace_repo_ambiguous_error ~repo_name ~search_root ~matches)
