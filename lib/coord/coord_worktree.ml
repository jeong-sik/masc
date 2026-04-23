(** Coord Worktree - Git Worktree Integration for Agent Isolation

    MASC v2 feature: Each agent works in isolated git worktrees
    to prevent file conflicts during parallel work.

    Extracted from room.ml for modularity.
*)

open Types
open Coord_utils

let exec_gate_raw_source argv =
  String.concat " " (List.map Filename.quote argv)

(** Run argv and get lines (Eio-native, no shell) *)
let run_argv_lines argv =
  Masc_exec.Exec_gate.run_argv
    ~actor:"coord/worktree"
    ~raw_source:(exec_gate_raw_source argv)
    ~summary:"coord_worktree argv"
    ~timeout_sec:30.0
    argv
  |> String.split_on_char '\n'
  |> List.filter (fun s -> s <> "")

(** Run argv and get process status + combined output. *)
let run_argv_with_status argv =
  Masc_exec.Exec_gate.run_argv_with_status
    ~actor:"coord/worktree"
    ~raw_source:(exec_gate_raw_source argv)
    ~summary:"coord_worktree argv"
    ~timeout_sec:30.0
    argv

(** Run argv and get exit code (Eio-native, no shell) *)
let run_argv_exit argv =
  match run_argv_with_status argv with
  | Unix.WEXITED n, _ -> n
  | Unix.WSIGNALED _, _ -> 128
  | Unix.WSTOPPED _, _ -> 128

let first_nonempty_line output =
  output
  |> String.split_on_char '\n'
  |> List.map String.trim
  |> List.find_opt (fun s -> s <> "")

(** Check if directory is a git repository - delegates to Coord_git *)
let is_git_repo config =
  Coord_git.is_git_repo ~base_path:config.base_path

(** Resolve the project root from config.base_path.
    If base_path ends with ".masc", use its parent; otherwise use base_path.
    Then walk parent directories until we find the owning repository root
    (.git directory). This keeps config.base_path as the anchor while still
    handling nested subdirectories and worktree roots (.git file).
    Inlined from Keeper_alerting_path to avoid room→keeper dependency. *)
let git_marker_kind path =
  match (try Some (Sys.is_directory path) with Sys_error _ -> None) with
  | Some true -> `Directory
  | Some false -> `File
  | None -> `Missing

let project_root config =
  let base = config.base_path in
  let candidate =
    if Filename.basename base = ".masc" then Filename.dirname base else base
  in
  let rec find_repo_root dir =
    let git_marker = Filename.concat dir ".git" in
    match git_marker_kind git_marker with
    | `Directory -> Some dir
    | `File | `Missing ->
        let parent = Filename.dirname dir in
        if String.equal parent dir then None else find_repo_root parent
  in
  match find_repo_root candidate with
  | Some root -> root
  | None -> candidate

let require_repository_root_with_git config =
  let root = project_root config in
  let git_marker = Filename.concat root ".git" in
  match git_marker_kind git_marker with
  | `Directory | `File ->
    Ok root
  | `Missing ->
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

let safe_file_exists path =
  try Sys.file_exists path with
  | Sys_error _ -> false

let safe_is_dir path =
  try Sys.file_exists path && Sys.is_directory path with
  | Sys_error _ -> false

let safe_repo_name name =
  name <> "" && name <> "." && name <> ".."
  && not (String.contains name '/')
  && not (String.contains name '\\')
  && not (String.contains name '\x00')
  && String.for_all
       (fun c ->
         (c >= 'A' && c <= 'Z')
         || (c >= 'a' && c <= 'z')
         || (c >= '0' && c <= '9')
         || c = '-'
         || c = '_'
         || c = '.')
       name

let is_git_clone candidate =
  safe_is_dir candidate
  &&
  match git_marker_kind (Filename.concat candidate ".git") with
  | `Directory | `File -> true
  | `Missing -> false

let run_git_in_clone clone_path args =
  run_argv_with_status ([ "git"; "-C"; clone_path; "--no-optional-locks" ] @ args)

let trim_output_detail output =
  let detail = String.trim output in
  if detail = "" then "(no output)" else detail

let first_nul_field output =
  match String.index_opt output '\x00' with
  | Some idx when idx > 0 -> Some (String.sub output 0 idx)
  | Some _ -> None
  | None ->
      let trimmed = String.trim output in
      if trimmed = "" then None else Some trimmed

type sandbox_clone_state =
  | Ready
  | Needs_checkout of string
  | Broken_git of string

let inspect_sandbox_clone candidate =
  let inside_status, inside_output =
    run_git_in_clone candidate [ "rev-parse"; "--is-inside-work-tree" ]
  in
  if inside_status <> Unix.WEXITED 0 then
    Broken_git
      (Printf.sprintf "git rev-parse failed: %s"
         (trim_output_detail inside_output))
  else
    let tracked_status, tracked_output =
      run_git_in_clone candidate [ "ls-files"; "-z" ]
    in
    if tracked_status <> Unix.WEXITED 0 then
      Broken_git
        (Printf.sprintf "git ls-files failed: %s"
           (trim_output_detail tracked_output))
    else
      match first_nul_field tracked_output with
      | None -> Ready
      | Some relpath ->
          if safe_file_exists (Filename.concat candidate relpath) then Ready
          else Needs_checkout relpath

let restore_sandbox_clone_checkout candidate =
  let checkout_status, checkout_output =
    run_git_in_clone candidate [ "checkout"; "-f"; "HEAD"; "--"; "." ]
  in
  if checkout_status <> Unix.WEXITED 0 then
    Error
      (IoError
         (Printf.sprintf
            "sandbox_clone_checkout_restore_failed: could not restore tracked \
             files in %s: %s"
            candidate (trim_output_detail checkout_output)))
  else
    match inspect_sandbox_clone candidate with
    | Ready ->
        Ok
          (Some
             "Existing sandbox clone checkout was restored from HEAD before \
              worktree creation.")
    | Needs_checkout relpath ->
        Error
          (IoError
             (Printf.sprintf
                "sandbox_clone_checkout_restore_failed: %s is still missing \
                 tracked path %s after checkout."
                candidate relpath))
    | Broken_git detail ->
        Error
          (IoError
             (Printf.sprintf
                "sandbox_clone_checkout_restore_failed: %s is still not a \
                 usable git clone after checkout: %s"
                candidate detail))

let ensure_sandbox_clone_ready candidate =
  match inspect_sandbox_clone candidate with
  | Ready -> Ok None
  | Needs_checkout _ -> restore_sandbox_clone_checkout candidate
  | Broken_git detail ->
      Error
        (IoError
           (Printf.sprintf
              "sandbox_clone_invalid: %s has a .git marker but is not a usable \
               git clone: %s"
              candidate detail))

let keeper_toml_path ~config ~agent_name =
  let keeper_name = Playground_paths.sanitize_keeper_name agent_name in
  Filename.concat
    (Filename.concat
       (Filename.concat
          (masc_dir_from_base_path ~base_path:config.base_path)
          "config")
       "keepers")
    (keeper_name ^ ".toml")

let strip_inline_comment line =
  match String.index_opt line '#' with
  | Some idx -> String.sub line 0 idx
  | None -> line

let unquote value =
  let len = String.length value in
  if len >= 2 && value.[0] = '"' && value.[len - 1] = '"'
  then String.sub value 1 (len - 2)
  else value

let keeper_uses_docker_sandbox ~config ~agent_name =
  let path = keeper_toml_path ~config ~agent_name in
  if not (safe_file_exists path) then false
  else
    try
      let lines =
        In_channel.with_open_text path In_channel.input_all
        |> String.split_on_char '\n'
      in
      let rec loop in_keeper = function
        | [] -> false
        | raw_line :: rest ->
            let line =
              raw_line |> strip_inline_comment |> String.trim
            in
            if line = "" then loop in_keeper rest
            else if String.length line > 0 && line.[0] = '[' then
              loop (String.equal line "[keeper]") rest
            else if
              in_keeper
              && String.starts_with ~prefix:"sandbox_profile" line
            then
              let value =
                match String.index_opt line '=' with
                | None -> ""
                | Some idx ->
                    String.sub line (idx + 1) (String.length line - idx - 1)
                    |> String.trim
                    |> unquote
                    |> String.lowercase_ascii
              in
              String.equal value "docker"
            else
              loop in_keeper rest
      in
      loop false lines
    with Sys_error _ -> false

let repos_dir_of_keeper config agent_name =
  let safe_name = Playground_paths.sanitize_keeper_name agent_name in
  let repos_rel =
    if keeper_uses_docker_sandbox ~config ~agent_name then
      Printf.sprintf "%s/docker/%s/repos/"
        Playground_paths.all_playgrounds_prefix safe_name
    else
      Playground_paths.repos_path agent_name
  in
  Filename.concat config.base_path repos_rel

let rec rm_rf path =
  if safe_file_exists path then
    if safe_is_dir path then begin
      (try Sys.readdir path with Sys_error _ -> [||])
      |> Array.iter (fun entry -> rm_rf (Filename.concat path entry));
      (try Unix.rmdir path with Unix.Unix_error _ -> ())
    end else
      try Unix.unlink path with Unix.Unix_error _ -> ()

let missing_sandbox_clone_error ~agent_name ~repos_dir ~repo_name =
  let rel_target, clone_hint =
    match repo_name with
    | Some name when String.trim name <> "" ->
      let rel = Printf.sprintf "repos/%s" name in
      ( rel,
        Printf.sprintf
          "keeper_shell op=git_clone url=\"https://github.com/<org>/%s.git\" path=\"%s\""
          name rel )
    | _ ->
      ( "repos/<repo>",
        "keeper_shell op=git_clone url=\"https://github.com/<org>/<repo>.git\" \
         path=\"repos/<repo>\"" )
  in
  IoError
    (Printf.sprintf
       "missing_sandbox_clone: no sandbox git clone found for agent %s under %s \
        (expected %s). Recovery: %s"
       agent_name repos_dir rel_target clone_hint)

let workspace_repo_not_found_error ~agent_name ~repos_dir ~repo_name
    ~search_root =
  IoError
    (Printf.sprintf
       "missing_sandbox_clone: no sandbox git clone found for agent %s under %s \
        and no workspace git repo named %s was found under %s. Recovery: \
        keeper_shell op=git_clone url=\"https://github.com/<org>/%s.git\" \
        path=\"repos/%s\""
       agent_name repos_dir repo_name search_root repo_name repo_name)

let workspace_repo_ambiguous_error ~repo_name ~search_root ~matches =
  IoError
    (Printf.sprintf
       "ambiguous_workspace_repo: found multiple git repos named %s under %s: \
        [%s]. Auto-provision is blocked until the repo is disambiguated; use \
        keeper_shell op=git_clone explicitly."
       repo_name search_root (String.concat ", " matches))

let partial_clone_error ~clone_path ~msg =
  rm_rf clone_path;
  IoError msg

let workspace_repo_matches ~search_root ~repo_name =
  let max_dirs = 4000 in
  let max_matches = 8 in
  let preferred_dir_name = function
    | "workspace" | "workspaces" | "repos" | "projects" | "src" -> true
    | _ -> false
  in
  let entry_priority entry =
    if entry = repo_name then 0
    else if preferred_dir_name entry then 1
    else if String.length entry > 0 && entry.[0] = '.' then 3
    else 2
  in
  let skip_dir_name = function
    | ".git" | ".hg" | ".svn" | ".masc" | ".worktrees" | "_build"
    | "node_modules" ->
        true
    | _ -> false
  in
  let matches =
    if Filename.basename search_root = repo_name && is_git_clone search_root
    then ref [ search_root ]
    else ref []
  in
  let queue = Queue.create () in
  Queue.add search_root queue;
  let dirs_seen = ref 0 in
  while
    !dirs_seen < max_dirs
    && Queue.length queue > 0
    && List.length !matches < max_matches
  do
    let dir = Queue.take queue in
    incr dirs_seen;
    let entries =
      try Sys.readdir dir with Sys_error _ -> [||]
    in
    Array.sort
      (fun a b ->
         match compare (entry_priority a) (entry_priority b) with
         | 0 -> compare a b
         | n -> n)
      entries;
    Array.iter
      (fun entry ->
         if List.length !matches < max_matches then
           let path = Filename.concat dir entry in
           if entry = repo_name && is_git_clone path then
             matches := path :: !matches;
           if safe_is_dir path && not (skip_dir_name entry) then
             Queue.add path queue)
      entries
  done;
  List.sort_uniq String.compare !matches

let git_origin_url root =
  match run_argv_with_status [ "git"; "-C"; root; "remote"; "get-url"; "origin" ] with
  | Unix.WEXITED 0, output -> first_nonempty_line output
  | _ -> None

let auto_provision_sandbox_clone ~config ~agent_name ~repos_dir ~repo_name =
  let search_root = project_root config in
  match workspace_repo_matches ~search_root ~repo_name with
  | [] ->
      Error
        (workspace_repo_not_found_error ~agent_name ~repos_dir ~repo_name
           ~search_root)
  | [ source_root ] ->
      Fs_compat.mkdir_p repos_dir;
      let clone_path = Filename.concat repos_dir repo_name in
      if safe_file_exists clone_path then
        if is_git_clone clone_path then
          ensure_sandbox_clone_ready clone_path
          |> Result.map (fun repair_note -> (clone_path, repair_note))
        else
          Error
            (IoError
               (Printf.sprintf
                  "sandbox_clone_conflict: %s already exists under %s but is not \
                   a git clone. Remove or repair it, or use keeper_shell \
                   op=git_clone explicitly."
                  repo_name repos_dir))
      else
        let status, output =
          run_argv_with_status [ "git"; "clone"; source_root; clone_path ]
        in
        if status <> Unix.WEXITED 0 then
          Error
            (partial_clone_error ~clone_path
               ~msg:
                 (Printf.sprintf
                    "auto_provision_clone_failed: git clone from workspace repo %s \
                     into %s failed: %s"
                    source_root clone_path
                    (let detail = String.trim output in
                     if detail = "" then "(no output)" else detail)))
        else (
          match git_origin_url source_root with
          | Some origin_url ->
              let set_status, set_output =
                run_argv_with_status
                  [ "git"; "-C"; clone_path; "remote"; "set-url"; "origin";
                    origin_url ]
              in
              if set_status <> Unix.WEXITED 0 then
                Error
                  (partial_clone_error ~clone_path
                     ~msg:
                       (Printf.sprintf
                          "auto_provision_clone_failed: cloned %s into %s but \
                           could not restore origin %s: %s"
                          source_root clone_path origin_url
                          (let detail = String.trim set_output in
                           if detail = "" then "(no output)" else detail)))
              else
                Ok
                  ( clone_path,
                    Some
                      (Printf.sprintf
                         "Sandbox clone auto-provisioned from workspace repo %s."
                         source_root) )
          | None ->
              Ok
                ( clone_path,
                  Some
                    (Printf.sprintf
                       "Sandbox clone auto-provisioned from workspace repo %s \
                        (origin remote unavailable on source clone)."
                       source_root) ))
  | matches ->
      Error
        (workspace_repo_ambiguous_error ~repo_name ~search_root ~matches)

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
    @param link_task If true, links worktree info to the task in backlog (default: true)
    @param repo_name If set, target the keeper's sandbox repo clone at
           [.masc/playground/<agent>/repos/<repo_name>/] directly. If
           unset, scan [repos/] and use the first git clone found
           (alphabetical). A sandbox repo clone is required. *)
let worktree_create_r ?(link_task=true) ?repo_name config ~agent_name ~task_id ~base_branch : string masc_result =
  if not (is_initialized config) then
    Error NotInitialized
  else if not (is_git_repo config) then
    Error (IoError "Not a git repository. MASC v2 requires .git directory for worktree isolation.")
  else match validate_agent_name_r agent_name, validate_task_id_r task_id with
  | Error e, _ -> Error e
  | _, Error e -> Error e
  | Ok _, Ok _ ->
    (* Prefer a keeper's sandbox repo clone under
       the keeper's backend-specific sandbox repo lane. If [repo_name]
       is supplied, target that clone directly; otherwise scan the
       directory and pick the first git clone (alphabetical). Keepers
       may work on any repo their [tool_policy.toml] allows, but the
       worktree root must come from a sandbox repo clone. *)
    let resolve_keeper_repo_root () =
      let repos_dir = repos_dir_of_keeper config agent_name in
      let explicit_repo =
        match repo_name with
        | None | Some "" -> None
        | Some name when not (safe_repo_name name) -> None
        | Some name ->
          let candidate = Filename.concat repos_dir name in
          if is_git_clone candidate
          then Some (ensure_sandbox_clone_ready candidate |> Result.map (fun note -> (candidate, note)))
          else None
      in
      let scan_first_git_repo dir =
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
              if is_git_clone candidate
              then
                Some
                  (ensure_sandbox_clone_ready candidate
                   |> Result.map (fun note -> (candidate, note)))
              else find (i + 1)
          in
          find 0
      in
      match repo_name with
      | Some name when String.trim name <> "" && safe_repo_name name -> (
          match explicit_repo with
          | Some result -> result
          | None ->
              auto_provision_sandbox_clone ~config ~agent_name ~repos_dir
                ~repo_name:name)
      | _ -> (
          match scan_first_git_repo repos_dir with
          | Some result -> result
          | None ->
              Error
                (missing_sandbox_clone_error ~agent_name ~repos_dir ~repo_name))
    in
    match resolve_keeper_repo_root () with
    | Error e -> Error e
    | Ok (root, provision_note) -> begin
        let worktree_name = Playground_paths.worktree_dir_name agent_name task_id in
        match ensure_worktree_path root worktree_name with
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
            (* Fetch origin first; stale remotes must be explicit, not hidden. *)
            let fetch_exit = run_argv_exit ["git"; "-C"; root; "fetch"; "origin"] in
            if fetch_exit <> 0 then
              Error
                (IoError
                   "Failed to fetch origin before worktree creation. Verify network/auth and retry so the task starts from the latest remote ref.")
            else match Coord_git.resolve_base_branch root base_branch with
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
                    ~actor:"coord/worktree"
                    ~raw_source:(exec_gate_raw_source argv)
                    ~summary:"coord_worktree worktree add"
                    ~timeout_sec:30.0
                    argv
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
                      worktree_path branch_name repo_name note
                      (provision_note ^ link_note) worktree_path)
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
    let resolve_existing_worktree_root () =
      let repos_dir = repos_dir_of_keeper config agent_name in
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
        Error
          (IoError
             (Printf.sprintf
                "Worktree %s not found under sandbox repo clones in %s"
                worktree_name repos_dir))
    in
    match resolve_existing_worktree_root () with
    | Error e -> Error e
    | Ok root ->
        let worktree_name = Playground_paths.worktree_dir_name agent_name task_id in
        match ensure_worktree_path root worktree_name with
        | Error e -> Error e
        | Ok (worktree_path, _) -> begin
            let branch_name = Playground_paths.worktree_branch_name agent_name task_id in

            if not (Sys.file_exists worktree_path) then
              Error (IoError (Printf.sprintf "Worktree not found: %s" worktree_path))
            else begin
              (* Remove worktree *)
              let exit_code = run_argv_exit ["git"; "-C"; root; "worktree"; "remove"; worktree_path] in

              if exit_code = 0 then begin
                (* Delete the branch — use -D to force-delete unmerged branches *)
                let branch_exit = run_argv_exit ["git"; "-C"; root; "branch"; "-D"; branch_name] in

                (* Prune stale worktrees *)
                let prune_exit = run_argv_exit ["git"; "-C"; root; "worktree"; "prune"] in

                (* Log event with post-processing status *)
                let branch_status = if branch_exit = 0 then "ok" else "warn:branch_delete_failed" in
                let prune_status = if prune_exit = 0 then "ok" else "warn:prune_failed" in
                let event = Printf.sprintf
                  "{\"type\":\"worktree_remove\",\"agent\":\"%s\",\"branch\":\"%s\",\"branch_delete\":\"%s\",\"prune\":\"%s\",\"ts\":\"%s\"}"
                  agent_name branch_name branch_status prune_status (now_iso ()) in
                log_event config event;

                (* Return result with post-processing status *)
                let msg = Printf.sprintf "✅ Worktree removed: %s\n   Branch: %s (delete: %s)\n   Prune: %s"
                  worktree_path branch_name branch_status prune_status in
                if branch_exit <> 0 || prune_exit <> 0 then
                  Error (IoError (msg ^ "\n   ⚠️ Post-processing had failures"))
                else
                  Ok msg
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
    Coord_git.list ~base_path:config.base_path
