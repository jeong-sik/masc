(** Coord Worktree - Lifecycle (create / remove / list / link).

    Public API of the [Coord_worktree] facade.  All filesystem
    destruction is routed through {!Coord_worktree_destructive_ops};
    sandbox-clone resolution through
    {!Coord_worktree_sandbox_clone}; repo discovery through
    {!Coord_worktree_repo_discovery}.

    Stage 06, godfile decomposition plan 2026-05-18. *)

open Masc_domain
open Coord_utils

(** Link worktree info to a task in backlog.
    Uses read_json/write_json to handle Backend ZSTD compression transparently. *)
let link_worktree_to_task config ~task_id ~worktree_info =
  let backlog_file = Filename.concat (tasks_dir config) "backlog.json" in
  let json = read_json config backlog_file in
  match backlog_of_yojson json with
  | Error e -> Error (System (System_error.IoError e))
  | Ok backlog ->
      if backlog.tasks = [] then
        Error (System (System_error.IoError "Backlog not found"))
      else
        let found = ref false in
        let new_tasks = List.map (fun (task : task) ->
          if task.id = task_id then begin
            found := true;
            { task with worktree = Some worktree_info }
          end else task
        ) backlog.tasks in
        if not !found then
          Error (Task (Task_error.NotFound task_id))
        else begin
          let new_backlog = { backlog with tasks = new_tasks; last_updated = now_iso () } in
          write_json config backlog_file (backlog_to_yojson new_backlog);
          Ok ()
        end

(** Create worktree for agent - Result version
    @param link_task If true, links worktree info to the task in backlog (default: true)
    @param repo_name If set, target the keeper's sandbox repo clone at
           [.masc/playground/<agent>/repos/<repo_name>/] directly. If
           unset, infer the repo from the task's repo/path evidence; only
           fall back to the sole clone when exactly one clone exists. A
           sandbox repo clone is required. *)
let worktree_create_r ?(link_task=true) ?repo_name config ~agent_name ~task_id ~base_branch : string masc_result =
  if not (is_initialized config) then
    Error (System System_error.NotInitialized)
  else if not (Coord_worktree_paths.is_git_repo config) then
    Error (System (System_error.IoError "Not a git repository. MASC v2 requires .git directory for worktree isolation."))
  else match validate_agent_name_r agent_name, validate_task_id_r task_id with
  | Error e, _ -> Error e
  | _, Error e -> Error e
  | Ok _, Ok _ ->
    Coord_worktree_paths.with_worktree_mutation_lock @@ fun () ->
    let repo_name =
      match repo_name with
      | Some name when String.trim name <> ""
                       && not (Coord_worktree_paths.safe_repo_name name) ->
          Error
            (System (System_error.IoError
               (Printf.sprintf
                  "invalid_repo_name: %S must be a single repo directory name under repos/"
                  name)))
      | Some name when String.trim name <> "" -> Ok (Some name)
      | _ ->
          Coord_worktree_repo_discovery.infer_task_repo_name config ~agent_name
            ~task_id
    in
    match repo_name with
    | Error e -> Error e
    | Ok repo_name ->
        (* Prefer a keeper's sandbox repo clone under the keeper's
           backend-specific sandbox repo lane. If [repo_name] is supplied,
           target that clone directly; otherwise use the repo inferred above.
           Keepers may work on any repo their [tool_policy.toml] allows, but
           the worktree root must come from a sandbox repo clone. *)
        let resolve_keeper_repo_root () =
          let repos_dir = Coord_worktree_paths.repos_dir_of_keeper config agent_name in
          let explicit_repo =
            match repo_name with
            | None | Some "" -> None
            | Some name when not (Coord_worktree_paths.safe_repo_name name) -> None
            | Some name ->
                let candidate = Filename.concat repos_dir name in
                if Coord_worktree_paths.is_git_clone candidate
                then
                  Some
                    (Coord_worktree_sandbox_clone.ensure_sandbox_clone_ready candidate
                     |> Result.map (fun note -> (candidate, note)))
                else None
          in
          match repo_name with
          | Some name when String.trim name <> ""
                           && Coord_worktree_paths.safe_repo_name name -> (
              match explicit_repo with
              | Some result -> result
              | None ->
                  Coord_worktree_sandbox_clone.auto_provision_sandbox_clone
                    ~config ~agent_name ~repos_dir ~repo_name:name)
          | _ ->
              Error
                (Coord_worktree_sandbox_clone.missing_sandbox_clone_error
                   ~agent_name ~repos_dir ~repo_name)
        in
        match resolve_keeper_repo_root () with
        | Error e -> Error e
        | Ok (root, provision_note) -> begin
        let worktree_name = Playground_paths.worktree_dir_name agent_name task_id in
        match Coord_worktree_paths.ensure_worktree_path root worktree_name with
        | Error e -> Error e
        | Ok (worktree_path, worktrees_dir) ->
          let branch_name = Playground_paths.worktree_branch_name agent_name task_id in
          let repo_name = Filename.basename root in

          (* Build worktree_info for task linking *)
          let wt_info : worktree_info = {
            branch = branch_name;
            path = Printf.sprintf ".worktrees/%s" worktree_name;
            git_root = root;
            repo_name = repo_name;
          } in

          let update_agent_current_task () =
            let agent_file = Filename.concat (agents_dir config) (safe_filename agent_name ^ ".json") in
            match read_agent_with_repair config agent_file with
            | Ok agent ->
                let updated_agent = { agent with current_task = Some worktree_name } in
                write_json config agent_file (agent_to_yojson updated_agent)
            | Error msg -> Log.Misc.info "agent state read: %s" msg
          in

          (* Link worktree to task in backlog *)
          (* WORKAROUND: Masc_error.t has 7 ctors with nested per-domain
             variants (Task_error has its own ctors). 정확한 enumeration은
             도메인 신규 ctor마다 무관한 caller가 churn 대상이 됨.
             근본 해결: per-domain error-to-string helper로 분류 일원화 (RFC 후보). *)
          let[@warning "-4"] maybe_link_task () =
            if link_task then begin
              match link_worktree_to_task config ~task_id ~worktree_info:wt_info with
              | Ok () -> ""
              | Error (Task (Task_error.NotFound _)) -> "\n  Note: Task not found in backlog, worktree not linked"
              | Error _ -> "\n  Note: Could not link worktree to task"
            end else ""
          in

          let existing_worktree_ok ?(created_concurrently=false) () =
            update_agent_current_task ();
            let keeper_path =
              Coord_worktree_paths.keeper_visible_worktree_path
                ~config ~agent_name ~host_path:worktree_path
            in
            let race_note =
              if created_concurrently then
                "\n  Note: Worktree was created concurrently by another worker."
              else ""
            in
            let link_note = maybe_link_task () in
            Ok
              (Printf.sprintf
                 "Worktree already exists:\n  Path: %s\n  Branch: %s\n  \
                  Repo: %s%s%s\n\n%s"
                 keeper_path branch_name repo_name race_note link_note
                 (Coord_worktree_paths.worktree_next_step keeper_path))
          in

          (* Create .worktrees directory if not exists *)
          Fs_compat.mkdir_p worktrees_dir;

          (* Check if worktree already exists *)
          if Coord_worktree_paths.safe_file_exists worktree_path then begin
            if Coord_worktree_paths.is_usable_git_worktree worktree_path then
              existing_worktree_ok ()
            else
              Error
                (System (System_error.IoError
                   (Printf.sprintf
                      "worktree_path_conflict: %s already exists but is not a \
                       usable git worktree. Remove or repair it before retrying."
                      worktree_path)))
          end else begin
            (* Fetch origin first; stale remotes must be explicit, not hidden.
               Use the longer git_fetch_timeout_sec budget — the default
               30s rejected legitimately slow Docker-bridge fetches and
               cold fetches on large remotes (#9587). *)
            ignore
              (Coord_worktree_sandbox_clone.normalize_origin_remote_to_https
                 root
               : string option);
            let fetch_exit =
              Coord_worktree_exec.run_argv_exit
                ~timeout_sec:(Env_config_core.git_fetch_timeout_sec ())
                ["git"; "-C"; root; "fetch"; "origin"]
            in
            if fetch_exit <> 0 then
              Error
                (System (System_error.IoError
                   "Failed to fetch origin before worktree creation. Verify network/auth and retry so the task starts from the latest remote ref."))
            else begin
              let playground_dir =
                Coord_worktree_paths.repos_dir_of_keeper config agent_name
                |> Coord_worktree_paths.strip_trailing_slashes
                |> Filename.dirname
              in
              Playground_repo_cache.update ~playground_dir ~repo_name
                ~repo_path:root ~action:"fetch"
                ~shallow:(Playground_repo_cache.is_shallow_repo root);
              match Coord_git.resolve_base_branch root base_branch with
            | Error e -> Error e
            | Ok (resolved_base, fallback_from) ->
                let note = match fallback_from with
                  | None -> ""
                  | Some missing ->
                      Printf.sprintf "\n  Note: origin/%s not found; used origin/%s" missing resolved_base
                in
                let provision_note =
                  match provision_note with
                  | None -> ""
                  | Some detail -> "\n  Note: " ^ detail
                in
                (* Create worktree with force-branch (-B) from base.
                   -B resets the branch if it already exists (stale from a
                   previous session), avoiding the TOCTOU race of
                   check-delete-create and the permanent failure when keeper
                   branches are not cleaned up after worktree removal. *)
                let exit_code, git_output =
                  let argv =
                    [
                      "git";
                      "-C";
                      root;
                      "worktree";
                      "add";
                      worktree_path;
                      "-B";
                      branch_name;
                      Printf.sprintf "origin/%s" resolved_base;
                    ]
                  in
                  Masc_exec.Exec_gate.run_argv_with_status
                    ~actor:(Masc_exec.Agent_id.of_string "coord/worktree")
                    ~raw_source:(Coord_worktree_exec.exec_gate_raw_source argv)
                    ~summary:"coord_worktree worktree add"
                    ~timeout_sec:Env_config_runtime.Coord_git.local_op_timeout_sec
                    argv
                in

                if exit_code = Unix.WEXITED 0 then begin
                  (* Update agent's current_worktree in state *)
                  update_agent_current_task ();
                  let keeper_path =
                    Coord_worktree_paths.keeper_visible_worktree_path
                      ~config ~agent_name ~host_path:worktree_path
                  in

                  (* Link to task *)
                  let link_note = maybe_link_task () in

                  (* Log event with worktree info *)
                  let event = Printf.sprintf
                    "{\"type\":\"worktree_create\",\"agent\":\"%s\",\"branch\":\"%s\",\"path\":\"%s\",\"repo\":\"%s\",\"task_id\":\"%s\",\"ts\":\"%s\"}"
                    agent_name branch_name worktree_path repo_name task_id (now_iso ()) in
                  log_event config (Yojson.Safe.from_string event);

                  Ok (Printf.sprintf "Worktree created:\n  Path: %s\n  Branch: %s\n  Repo: %s%s%s\n\n%s"
                      keeper_path branch_name repo_name note
                      (provision_note ^ link_note)
                      (Coord_worktree_paths.worktree_next_step keeper_path))
                end
                else if Coord_worktree_paths.is_usable_git_worktree worktree_path
                then
                  existing_worktree_ok ~created_concurrently:true ()
                else begin
                  Coord_worktree_destructive_ops.rm_rf worktree_path;
                  let detail = String.trim git_output in
                  Error (System (System_error.IoError (Printf.sprintf "Failed to create worktree from origin/%s: %s"
                    resolved_base (if detail = "" then "(no output)" else detail))))
                end
            end
          end
  end

(** Remove worktree - Result version *)
let worktree_remove_r config ~agent_name ~task_id : string masc_result =
  if not (is_initialized config) then
    Error (System System_error.NotInitialized)
  else match validate_agent_name_r agent_name, validate_task_id_r task_id with
  | Error e, _ -> Error e
  | _, Error e -> Error e
  | Ok _, Ok _ ->
    let resolve_existing_worktree_root () =
      let repos_dir = Coord_worktree_paths.repos_dir_of_keeper config agent_name in
      let worktree_name = Playground_paths.worktree_dir_name agent_name task_id in
      let safe_is_dir path =
        try Sys.file_exists path && Sys.is_directory path
        with Sys_error _ -> false
      in
      let is_git_clone candidate =
        safe_is_dir candidate
        && (try Sys.file_exists (Filename.concat candidate ".git")
            with Sys_error _ -> false)
      in
      let find_matching_clone dir =
        if not (safe_is_dir dir) then None
        else
          let entries =
            try Sys.readdir dir with Sys_error _ -> [||]
          in
          Array.sort compare entries;
          let rec find i =
            if i >= Array.length entries then None
            else
              let candidate = Filename.concat dir entries.(i) in
              let worktree_path =
                Filename.concat candidate (Filename.concat ".worktrees" worktree_name)
              in
              if is_git_clone candidate && Sys.file_exists worktree_path
              then Some candidate
              else find (i + 1)
          in
          find 0
      in
      match find_matching_clone repos_dir with
      | Some root -> Ok root
      | None ->
        (* #13302 P2-1 follow-up: typed variant replaces the previous
           [IoError "Worktree ... not found under ..."] string-formatted
           error.  #13304 demoted the WARN by matching that prefix in
           [coord_task.cleanup_worktree_for_transition]; the typed
           variant here lets the caller pattern-match safely so a future
           message-format change does not silently regress the demotion. *)
        Error
          (System (System_error.WorktreeNotFound
             { worktree = worktree_name; searched_in = repos_dir }))
    in
    match resolve_existing_worktree_root () with
    | Error e -> Error e
    | Ok root ->
        let worktree_name = Playground_paths.worktree_dir_name agent_name task_id in
        match Coord_worktree_paths.ensure_worktree_path root worktree_name with
        | Error e -> Error e
        | Ok (worktree_path, _) -> begin
            let branch_name = Playground_paths.worktree_branch_name agent_name task_id in

            if not (Sys.file_exists worktree_path) then
              Error (System (System_error.IoError (Printf.sprintf "Worktree not found: %s" worktree_path)))
            else begin
              (* Remove worktree (destructive — routed through
                 Coord_worktree_destructive_ops so all destructive entry
                 points stay grep-discoverable in one module). *)
              let exit_code =
                Coord_worktree_destructive_ops.git_worktree_remove
                  ~root ~worktree_path
              in

              if exit_code = 0 then begin
                (* Force-delete the branch (-D); leaves the keeper free
                   to re-create the same branch name on the next task. *)
                let branch_exit =
                  Coord_worktree_destructive_ops.git_branch_force_delete
                    ~root ~branch_name
                in

                (* Prune stale worktree metadata. *)
                let prune_exit =
                  Coord_worktree_destructive_ops.git_worktree_prune ~root
                in

                (* Log event with post-processing status *)
                let branch_status = if branch_exit = 0 then "ok" else "warn:branch_delete_failed" in
                let prune_status = if prune_exit = 0 then "ok" else "warn:prune_failed" in
                let event = Printf.sprintf
                  "{\"type\":\"worktree_remove\",\"agent\":\"%s\",\"branch\":\"%s\",\"branch_delete\":\"%s\",\"prune\":\"%s\",\"ts\":\"%s\"}"
                  agent_name branch_name branch_status prune_status (now_iso ()) in
                log_event config (Yojson.Safe.from_string event);

                (* Return result with post-processing status *)
                let msg = Printf.sprintf "Worktree removed: %s\n   Branch: %s (delete: %s)\n   Prune: %s"
                  worktree_path branch_name branch_status prune_status in
                if branch_exit <> 0 || prune_exit <> 0 then
                  Error (System (System_error.IoError (msg ^ "\n   ⚠️ Post-processing had failures")))
                else
                  Ok msg
              end
              else
                Error (System (System_error.IoError "Failed to remove worktree. It may have uncommitted changes."))
	    end
    end

(** List all worktrees *)
let worktree_list config =
  if not (is_initialized config) then
    `Assoc [("error", `String "MASC not initialized")]
  else
    Coord_git.list ~base_path:config.base_path
