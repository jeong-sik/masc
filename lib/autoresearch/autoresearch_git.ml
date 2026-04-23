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

let exec_gate_raw_source argv =
  String.concat " " (List.map Filename.quote argv)

let run_git_with_status ?(timeout_sec = 30.0) ~workdir argv =
  let full_argv = "git" :: "-C" :: workdir :: argv in
  let raw_source = exec_gate_raw_source full_argv in
  Masc_exec.Exec_gate.run_argv_with_status
    ~actor:"autoresearch/git"
    ~raw_source
    ~summary:"autoresearch git"
    ~timeout_sec
    full_argv

let run_capture_lines ~workdir ?(timeout_sec = 30.0) argv =
  let status, raw_output = run_git_with_status ~timeout_sec ~workdir argv in
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
  let status, raw_output =
    run_git_with_status ~timeout_sec:10.0 ~workdir [ "rev-parse"; "--short"; "HEAD" ]
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
  let add_status, add_output =
    run_git_with_status ~timeout_sec:30.0 ~workdir [ "add"; "--update" ]
  in
  match add_status with
  | Unix.WEXITED 0 -> (
    let check_status, _check_output =
      run_git_with_status ~timeout_sec:30.0 ~workdir
        [ "diff"; "--cached"; "--quiet" ]
    in
    match check_status with
    | Unix.WEXITED 0 ->
    (* No staged changes -- nothing to commit *)
    Result.ok None
    | Unix.WEXITED 1 ->
    let status, raw_output =
      run_git_with_status ~timeout_sec:30.0 ~workdir [ "commit"; "-m"; message ]
    in
    (match status with
     | Unix.WEXITED 0 ->
       let hash_status, hash_output =
         run_git_with_status ~timeout_sec:10.0 ~workdir
           [ "rev-parse"; "--short"; "HEAD" ]
       in
       (match hash_status with
        | Unix.WEXITED 0 ->
          let trimmed = String.trim hash_output in
          if trimmed = "" then
            Result.error "git commit succeeded but no hash returned"
          else Result.ok (Some trimmed)
        | _ ->
          Result.error "git commit succeeded but rev-parse failed")
     | _ ->
       Result.error (Printf.sprintf "git commit failed: %s" raw_output))
    | Unix.WEXITED code ->
      Result.error (Printf.sprintf "git diff --cached --quiet exited %d" code)
    | _ ->
      Result.error "git diff --cached --quiet terminated abnormally")
  | _ ->
    Result.error (Printf.sprintf "git add failed: %s" add_output)

(** Restore worktree files to current HEAD without moving the branch. *)
let git_restore_head ~workdir =
  if not (is_in_git_repo workdir) then ()
  else
  (try
    let (status, _output) =
      run_git_with_status ~timeout_sec:30.0 ~workdir
        [ "restore"; "--source=HEAD"; "--worktree"; "--"; "." ]
    in
    match status with
    | Unix.WEXITED 0 -> ()
    | _ -> Log.Autoresearch.warn "git restore HEAD non-zero exit in %s" workdir
   with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Autoresearch.warn "git restore HEAD failed in %s: %s" workdir (Printexc.to_string exn))

(** Reset to HEAD~1, discarding the last commit. *)
let git_reset_last ~workdir =
  if not (is_in_git_repo workdir) then ()
  else
  (try
    let (status, _output) =
      run_git_with_status ~timeout_sec:30.0 ~workdir
        [ "reset"; "--soft"; "HEAD~1" ]
    in
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
  (try
     ignore
       (run_git_with_status ~timeout_sec:10.0 ~workdir
          [ "tag"; "-f"; tag ])
   with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Autoresearch.warn "git tag failed in %s: %s" workdir (Printexc.to_string exn))

(** Get the git top-level directory for a workdir. *)
let git_top_level ~workdir =
  if not (is_in_git_repo workdir) then
    Result.error "workdir is not inside a git repository"
  else
  match run_capture_lines ~workdir [ "rev-parse"; "--show-toplevel" ] with
  | Unix.WEXITED 0, top :: _ ->
      let trimmed = String.trim top in
      if trimmed = "" then Result.error "git top-level was empty"
      else Result.ok trimmed
  | _ -> Result.error "workdir is not inside a git repository"

(** Get the current branch name. *)
let git_current_branch ~workdir =
  if not (is_in_git_repo workdir) then None
  else
  match run_capture_lines ~workdir [ "rev-parse"; "--abbrev-ref"; "HEAD" ] with
  | Unix.WEXITED 0, branch :: _ ->
      let trimmed = String.trim branch in
      if trimmed = "" then None else Some trimmed
  | _ -> None

(** Check if the working tree has uncommitted changes. *)
let git_is_dirty ~workdir =
  if not (is_in_git_repo workdir) then false
  else
  match run_capture_lines ~workdir [ "status"; "--porcelain" ] with
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
      | Some _ | None -> ());
      let workdir = Autoresearch_storage.managed_worktree_dir ~base_path loop_id in
      if Sys.file_exists workdir then
        Result.error (Printf.sprintf "managed worktree already exists: %s" workdir)
      else begin
        Autoresearch_storage.ensure_dir (Filename.dirname workdir);
        let branch = managed_branch_name loop_id in
        match
          run_capture_lines ~workdir:repo_root
            [ "worktree"; "add"; "-b"; branch; workdir; "HEAD" ]
        with
        | Unix.WEXITED 0, _ ->
            Result.ok (workdir, repo_root, List.rev !warnings)
        | _, lines ->
            Result.error
              (Printf.sprintf "failed to create managed worktree: %s"
                 (String.concat "\n" lines))
      end
