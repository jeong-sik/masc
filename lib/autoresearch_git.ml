(** Autoresearch_git — Git operations for autoresearch experiment loop.

    Provides commit, reset, tag, branch, and worktree management
    used during the experiment cycle.

    @since 2.80.0 *)

(** Run a shell command and capture stdout lines. *)
let run_capture_lines cmd =
  let ic = Unix.open_process_in cmd in
  let lines = ref [] in
  (try
     while true do
       lines := input_line ic :: !lines
     done
   with End_of_file -> ());
  let status = Unix.close_process_in ic in
  (status, List.rev !lines)

(** Get current HEAD commit hash (short). *)
let git_head_short ~workdir =
  let cmd = Printf.sprintf "cd %s && git rev-parse --short HEAD 2>/dev/null"
    (Filename.quote workdir) in
  let ic = Unix.open_process_in cmd in
  Fun.protect ~finally:(fun () ->
    ignore (Unix.close_process_in ic)
  ) (fun () ->
    try Some (String.trim (input_line ic)) with End_of_file -> None
  )

(** Git commit result: Ok (Some hash) on success, Ok None when no diff,
    Error msg when git commit itself fails (e.g. missing identity, hooks). *)
let git_commit ~workdir ~message
  : (string option, string) Stdlib.result =
  let cmd = Printf.sprintf
    "cd %s && git add -A && git diff --cached --quiet"
    (Filename.quote workdir) in
  if Sys.command cmd = 0 then
    (* No staged changes -- nothing to commit *)
    Result.ok None
  else
    let commit_cmd = Printf.sprintf
      "cd %s && git commit -m %s 2>&1 && git rev-parse --short HEAD"
      (Filename.quote workdir) (Filename.quote message) in
    let ic = Unix.open_process_in commit_cmd in
    let lines = ref [] in
    (try while true do lines := input_line ic :: !lines done
     with End_of_file -> ());
    let status = Unix.close_process_in ic in
    match status with
    | Unix.WEXITED 0 ->
      (match !lines with
       | hash :: _ -> Result.ok (Some (String.trim hash))
       | [] -> Result.error "git commit succeeded but no hash returned")
    | _ ->
      let output = String.concat "\n" (List.rev !lines) in
      Result.error (Printf.sprintf "git commit failed: %s" output)

(** Restore worktree files to current HEAD without moving the branch. *)
let git_restore_head ~workdir =
  let cmd = Printf.sprintf "cd %s && git reset --hard HEAD 2>/dev/null"
    (Filename.quote workdir) in
  ignore (Sys.command cmd)

(** Reset to HEAD~1, discarding the last commit. *)
let git_reset_last ~workdir =
  let cmd = Printf.sprintf "cd %s && git reset --hard HEAD~1 2>/dev/null"
    (Filename.quote workdir) in
  ignore (Sys.command cmd)

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
  let tag = Printf.sprintf "ar-best-c%d-%.4f" cycle score in
  let cmd = Printf.sprintf "cd %s && git tag -f %s 2>/dev/null"
    (Filename.quote workdir) (Filename.quote tag) in
  ignore (Sys.command cmd)

(** Get the git top-level directory for a workdir. *)
let git_top_level ~workdir =
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
