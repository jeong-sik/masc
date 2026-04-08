(** Autoresearch_git — Git operations for autoresearch experiment loop.

    Provides commit, reset, tag, branch, and worktree management
    used during the experiment cycle.

    Uses Process_eio for non-blocking subprocess execution to avoid
    freezing the Eio event loop during git operations.

    @since 2.80.0 *)

(** Check if workdir is inside a git repository by walking parent directories.
    Returns true if .git exists at workdir or any ancestor.
    Fast-fail guard: avoids expensive subprocess timeouts in non-repo dirs. *)
let is_in_git_repo workdir =
  let rec walk dir =
    let git_marker = Filename.concat dir ".git" in
    if Sys.file_exists git_marker then true
    else
      let parent = Filename.dirname dir in
      if String.equal parent dir then false else walk parent
  in
  try walk workdir with Sys_error _ -> false

(** Run a shell command via Process_eio and capture stdout lines.
    Non-blocking: delegates to Eio.Process instead of Unix.open_process_in. *)
let run_capture_lines cmd =
  let status, raw_output =
    Process_eio.run_argv_with_status ~timeout_sec:30.0
      ["sh"; "-c"; cmd]
  in
  let lines =
    if String.length raw_output = 0 then []
    else String.split_on_char '\n' raw_output
         |> List.filter (fun s -> s <> "")
  in
  (status, lines)

(** Get current HEAD commit hash (short). *)
let git_head_short ~workdir =
  if not (is_in_git_repo workdir) then None
  else
  let cmd = Printf.sprintf "cd %s && git rev-parse --short HEAD 2>/dev/null"
    (Filename.quote workdir) in
  let status, raw_output =
    Process_eio.run_argv_with_status ~timeout_sec:10.0
      ["sh"; "-c"; cmd]
  in
  match status with
  | Unix.WEXITED 0 ->
    let trimmed = String.trim raw_output in
    if trimmed = "" then None else Some trimmed
  | _ -> None

(** Git commit result: Ok (Some hash) on success, Ok None when no diff,
    Error msg when git commit itself fails (e.g. missing identity, hooks). *)
let git_commit ~workdir ~message
  : (string option, string) Stdlib.result =
  if not (is_in_git_repo workdir) then
    Result.error "not inside a git repository"
  else
  let check_cmd = Printf.sprintf
    "cd %s && git add -A && git diff --cached --quiet"
    (Filename.quote workdir) in
  let check_status, _check_output =
    Process_eio.run_argv_with_status ~timeout_sec:30.0
      ["sh"; "-c"; check_cmd]
  in
  match check_status with
  | Unix.WEXITED 0 ->
    (* No staged changes -- nothing to commit *)
    Result.ok None
  | _ ->
    let commit_cmd = Printf.sprintf
      "cd %s && git commit -m %s 2>&1 && git rev-parse --short HEAD"
      (Filename.quote workdir) (Filename.quote message) in
    let status, raw_output =
      Process_eio.run_argv_with_status ~timeout_sec:30.0
        ["sh"; "-c"; commit_cmd]
    in
    let lines =
      String.split_on_char '\n' raw_output
      |> List.filter (fun s -> s <> "")
      |> List.rev
    in
    (match status with
    | Unix.WEXITED 0 ->
      (match lines with
       | hash :: _ -> Result.ok (Some (String.trim hash))
       | [] -> Result.error "git commit succeeded but no hash returned")
    | _ ->
      let output = String.concat "\n" (List.rev lines) in
      Result.error (Printf.sprintf "git commit failed: %s" output))

(** Restore worktree files to current HEAD without moving the branch. *)
let git_restore_head ~workdir =
  if not (is_in_git_repo workdir) then ()
  else
  let cmd = Printf.sprintf "cd %s && git reset --hard HEAD 2>/dev/null"
    (Filename.quote workdir) in
  (try
    let (status, _output) = Process_eio.run_argv_with_status ~timeout_sec:30.0
      ["sh"; "-c"; cmd] in
    match status with
    | Unix.WEXITED 0 -> ()
    | _ -> Log.Autoresearch.warn "git restore HEAD non-zero exit in %s" workdir
   with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Autoresearch.warn "git restore HEAD failed in %s: %s" workdir (Printexc.to_string exn))

(** Reset to HEAD~1, discarding the last commit. *)
let git_reset_last ~workdir =
  if not (is_in_git_repo workdir) then ()
  else
  let cmd = Printf.sprintf "cd %s && git reset --hard HEAD~1 2>/dev/null"
    (Filename.quote workdir) in
  (try
    let (status, _output) = Process_eio.run_argv_with_status ~timeout_sec:30.0
      ["sh"; "-c"; cmd] in
    match status with
    | Unix.WEXITED 0 -> ()
    | _ -> Log.Autoresearch.warn "git reset HEAD~1 non-zero exit in %s" workdir
   with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Autoresearch.warn "git reset HEAD~1 failed in %s: %s" workdir (Printexc.to_string exn))

(** Commit with autoresearch-formatted message. *)
let git_commit_cycle ~workdir ~cycle ~hypothesis ~baseline =
  (* Sanitize hypothesis: collapse newlines/control chars to single space *)
  let safe_hyp =
    String.to_seq hypothesis
    |> Seq.map (fun c -> if c < ' ' then ' ' else c)
    |> String.of_seq
    |> String.trim in
  let message = Printf.sprintf "[autoresearch] cycle %d: %s (baseline=%.4f)"
    cycle safe_hyp baseline in
  git_commit ~workdir ~message

(** Tag the current HEAD as the best result so far. *)
let git_tag_best ~workdir ~cycle ~score =
  if not (is_in_git_repo workdir) then ()
  else
  let tag = Printf.sprintf "ar-best-c%d-%.4f" cycle score in
  let cmd = Printf.sprintf "cd %s && git tag -f %s 2>/dev/null"
    (Filename.quote workdir) (Filename.quote tag) in
  (try ignore (Process_eio.run_argv_with_status ~timeout_sec:10.0
    ["sh"; "-c"; cmd])
   with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Autoresearch.warn "git tag failed in %s: %s" workdir (Printexc.to_string exn))

(** Get the git top-level directory for a workdir. *)
let git_top_level ~workdir =
  if not (is_in_git_repo workdir) then
    Result.error "workdir is not inside a git repository"
  else
  let cmd =
    Printf.sprintf "cd %s && git rev-parse --show-toplevel 2>/dev/null"
      (Filename.quote workdir)
  in
  match run_capture_lines cmd with
  | Unix.WEXITED 0, top :: _ ->
      let trimmed = String.trim top in
      if trimmed = "" then Result.error "git top-level was empty"
      else Result.ok trimmed
  | _ -> Result.error "workdir is not inside a git repository"

(** Get the current branch name. *)
let git_current_branch ~workdir =
  if not (is_in_git_repo workdir) then None
  else
  let cmd =
    Printf.sprintf "cd %s && git rev-parse --abbrev-ref HEAD 2>/dev/null"
      (Filename.quote workdir)
  in
  match run_capture_lines cmd with
  | Unix.WEXITED 0, branch :: _ ->
      let trimmed = String.trim branch in
      if trimmed = "" then None else Some trimmed
  | _ -> None

(** Check if the working tree has uncommitted changes. *)
let git_is_dirty ~workdir =
  if not (is_in_git_repo workdir) then false
  else
  let cmd =
    Printf.sprintf "cd %s && git status --porcelain 2>/dev/null"
      (Filename.quote workdir)
  in
  match run_capture_lines cmd with
  | Unix.WEXITED 0, lines -> List.exists (fun line -> String.trim line <> "") lines
  | _ -> false

let managed_branch_name loop_id =
  "autoresearch/" ^ loop_id

(** Create a managed git worktree for an autoresearch loop.
    Returns Ok (workdir, repo_root, warnings) or Error. *)
let prepare_managed_worktree ~base_path ~source_workdir ~loop_id =
  match git_top_level ~workdir:source_workdir with
  | Error _ as err -> err
  | Ok repo_root ->
      let warnings = ref [] in
      if git_is_dirty ~workdir:source_workdir then
        warnings := "source_workdir_dirty" :: !warnings;
      (match git_current_branch ~workdir:source_workdir with
      | Some branch when not (String.equal branch "main" || String.equal branch "master") ->
          warnings := ("source_branch:" ^ branch) :: !warnings
      | _ -> ());
      let workdir = Autoresearch_storage.managed_worktree_dir ~base_path loop_id in
      if Sys.file_exists workdir then
        Result.error (Printf.sprintf "managed worktree already exists: %s" workdir)
      else begin
        Autoresearch_storage.ensure_dir (Filename.dirname workdir);
        let branch = managed_branch_name loop_id in
        let cmd =
          Printf.sprintf
            "cd %s && git worktree add -b %s %s HEAD 2>&1"
            (Filename.quote repo_root)
            (Filename.quote branch)
            (Filename.quote workdir)
        in
        match run_capture_lines cmd with
        | Unix.WEXITED 0, _ ->
            Result.ok (workdir, repo_root, List.rev !warnings)
        | _, lines ->
            Result.error
              (Printf.sprintf "failed to create managed worktree: %s"
                 (String.concat "\n" lines))
      end
