(** Room Worktree - Git Worktree Integration for Agent Isolation

    MASC v2 feature: Each agent works in isolated git worktrees
    to prevent file conflicts during parallel work.

    Extracted from room.ml for modularity.
*)

open Types
open Room_utils

(** Run argv and get lines (Eio-native, no shell) *)
let run_argv_lines argv =
  Process_eio.run_argv ~timeout_sec:30.0 argv
  |> String.split_on_char '\n'
  |> List.filter (fun s -> s <> "")

(** Run argv and get exit code (Eio-native, no shell) *)
let run_argv_exit argv =
  match Process_eio.run_argv_with_status ~timeout_sec:30.0 argv with
  | Unix.WEXITED n, _ -> n
  | Unix.WSIGNALED _, _ -> 128
  | Unix.WSTOPPED _, _ -> 128

(** Get git root directory - delegates to Room_git *)
let git_root config =
  Room_git.git_root ~base_path:config.base_path

(** Check if directory is a git repository - delegates to Room_git *)
let is_git_repo config =
  Room_git.is_git_repo ~base_path:config.base_path

let require_repository_root_with_git config =
  match git_root config with
  | None -> Error (IoError "Cannot determine git root")
  | Some root ->
      let git_marker = Filename.concat root ".git" in
      if Sys.file_exists git_marker then
        Ok root
      else
        Error
          (IoError
             (Printf.sprintf
                "Worktree isolation requires repository root with .git: %s (current base path: %s)"
                root config.base_path))

let ensure_worktree_path root worktree_name =
  let worktrees_dir = Filename.concat root ".worktrees" in
  let worktree_path = Filename.concat worktrees_dir worktree_name in
  if Filename.dirname worktree_path = worktrees_dir then
    Ok (worktree_path, worktrees_dir)
  else
    Error (IoError "Invalid worktree path: must be created under .worktrees/")

(** Link worktree info to a task in backlog.
    Uses read_json/write_json to handle Backend ZSTD compression transparently. *)
let link_worktree_to_task config ~task_id ~worktree_info =
  let backlog_file = Filename.concat (tasks_dir config) "backlog.json" in
  let json = read_json config backlog_file in
  match backlog_of_yojson json with
  | Error e -> Error (IoError e)
  | Ok backlog ->
      if backlog.tasks = [] then
        Error (IoError "Backlog not found")
      else
        let found = ref false in
        let new_tasks = List.map (fun task ->
          if task.id = task_id then begin
            found := true;
            { task with worktree = Some worktree_info }
          end else task
        ) backlog.tasks in
        if not !found then
          Error (TaskNotFound task_id)
        else begin
          let new_backlog = { backlog with tasks = new_tasks; last_updated = now_iso () } in
          write_json config backlog_file (backlog_to_yojson new_backlog);
          Ok ()
        end

(** Create worktree for agent - Result version
    @param link_task If true, links worktree info to the task in backlog (default: true) *)
let worktree_create_r ?(link_task=true) config ~agent_name ~task_id ~base_branch : string masc_result =
  if not (is_initialized config) then
    Error NotInitialized
  else if not (is_git_repo config) then
    Error (IoError "Not a git repository. MASC v2 requires .git directory for worktree isolation.")
  else match validate_agent_name_r agent_name, validate_task_id_r task_id with
  | Error e, _ -> Error e
  | _, Error e -> Error e
  | Ok _, Ok _ ->
    (* Prefer the keeper's playground clone. If it is missing, fall back
       to the configured repository root so explicit repo-worktree flows
       still work instead of failing with a missing-clone error. *)
    let resolve_keeper_repo_root () =
      let playground_repo =
        Filename.concat config.base_path
          (Printf.sprintf ".masc/playground/%s/repos/masc-mcp"
             (safe_filename agent_name))
      in
      if Sys.file_exists playground_repo
         && Sys.file_exists (Filename.concat playground_repo ".git")
      then Ok playground_repo
      else
        match require_repository_root_with_git config with
        | Ok root -> Ok root
        | Error e -> Error e
    in
    match resolve_keeper_repo_root () with
    | Error e -> Error e
    | Ok root -> begin
        let worktree_name = Printf.sprintf "%s-%s" agent_name task_id in
        match ensure_worktree_path root worktree_name with
        | Error e -> Error e
        | Ok (worktree_path, worktrees_dir) ->
          let branch_name = Printf.sprintf "%s/%s" agent_name task_id in
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
            let json = read_json config agent_file in
            match agent_of_yojson json with
            | Ok agent ->
                let updated_agent = { agent with current_task = Some worktree_name } in
                write_json config agent_file (agent_to_yojson updated_agent)
            | Error msg -> Log.Misc.info "agent state read: %s" msg
          in

          (* Link worktree to task in backlog *)
          let maybe_link_task () =
            if link_task then begin
              match link_worktree_to_task config ~task_id ~worktree_info:wt_info with
              | Ok () -> ""
              | Error (TaskNotFound _) -> "\n  Note: Task not found in backlog, worktree not linked"
              | Error _ -> "\n  Note: Could not link worktree to task"
            end else ""
          in

          (* Create .worktrees directory if not exists *)
          Fs_compat.mkdir_p worktrees_dir;

          (* Check if worktree already exists *)
          if Sys.file_exists worktree_path then begin
            update_agent_current_task ();
            let link_note = maybe_link_task () in
            Ok (Printf.sprintf "✅ Worktree already exists:\n  Path: %s\n  Branch: %s\n  Repo: %s%s\n\nNext: cd %s"
                worktree_path branch_name repo_name link_note worktree_path)
          end else begin
            (* Fetch origin first *)
            let _ = run_argv_exit ["git"; "-C"; root; "fetch"; "origin"] in

            match Room_git.resolve_base_branch root base_branch with
            | Error e -> Error e
            | Ok (resolved_base, fallback_from) ->
                let note = match fallback_from with
                  | None -> ""
                  | Some missing ->
                      Printf.sprintf "\n  Note: origin/%s not found; used origin/%s" missing resolved_base
                in
                (* Create worktree with force-branch (-B) from base.
                   -B resets the branch if it already exists (stale from a
                   previous session), avoiding the TOCTOU race of
                   check-delete-create and the permanent failure when keeper
                   branches are not cleaned up after worktree removal. *)
                let exit_code, git_output =
                  Process_eio.run_argv_with_status ~timeout_sec:30.0
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

                if exit_code = Unix.WEXITED 0 then begin
                  (* Update agent's current_worktree in state *)
                  update_agent_current_task ();

                  (* Link to task *)
                  let link_note = maybe_link_task () in

                  (* Log event with worktree info *)
                  let event = Printf.sprintf
                    "{\"type\":\"worktree_create\",\"agent\":\"%s\",\"branch\":\"%s\",\"path\":\"%s\",\"repo\":\"%s\",\"task_id\":\"%s\",\"ts\":\"%s\"}"
                    agent_name branch_name worktree_path repo_name task_id (now_iso ()) in
                  log_event config event;

                  Ok (Printf.sprintf "✅ Worktree created:\n  Path: %s\n  Branch: %s\n  Repo: %s%s%s\n\nNext: cd %s && work && gh pr create --draft"
                      worktree_path branch_name repo_name note link_note worktree_path)
                end
                else
                  let detail = String.trim git_output in
                  Error (IoError (Printf.sprintf "Failed to create worktree from origin/%s: %s"
                    resolved_base (if detail = "" then "(no output)" else detail)))
          end
  end

(** Remove worktree - Result version *)
let worktree_remove_r config ~agent_name ~task_id : string masc_result =
  if not (is_initialized config) then
    Error NotInitialized
  else match validate_agent_name_r agent_name, validate_task_id_r task_id with
  | Error e, _ -> Error e
  | _, Error e -> Error e
  | Ok _, Ok _ ->
    match require_repository_root_with_git config with
    | Error e -> Error e
    | Ok root ->
        let worktree_name = Printf.sprintf "%s-%s" agent_name task_id in
        match ensure_worktree_path root worktree_name with
        | Error e -> Error e
        | Ok (worktree_path, _) -> begin
            let branch_name = Printf.sprintf "%s/%s" agent_name task_id in

            if not (Sys.file_exists worktree_path) then
              Error (IoError (Printf.sprintf "Worktree not found: %s" worktree_path))
            else begin
              (* Remove worktree *)
              let exit_code = run_argv_exit ["git"; "-C"; root; "worktree"; "remove"; worktree_path] in

              if exit_code = 0 then begin
                (* Try to delete the branch (may fail if not merged, which is ok) *)
                let _ = run_argv_exit ["git"; "-C"; root; "branch"; "-d"; branch_name] in

                (* Prune stale worktrees *)
                let _ = run_argv_exit ["git"; "-C"; root; "worktree"; "prune"] in

                (* Log event *)
                let event = Printf.sprintf
                  "{\"type\":\"worktree_remove\",\"agent\":\"%s\",\"branch\":\"%s\",\"ts\":\"%s\"}"
                  agent_name branch_name (now_iso ()) in
                log_event config event;

                Ok (Printf.sprintf "✅ Worktree removed: %s\n   Branch: %s" worktree_path branch_name)
              end
              else
                Error (IoError "Failed to remove worktree. It may have uncommitted changes.")
	    end
    end

(** List all worktrees *)
let worktree_list config =
  if not (is_initialized config) then
    `Assoc [("error", `String "MASC not initialized")]
  else
    Room_git.list ~base_path:config.base_path
