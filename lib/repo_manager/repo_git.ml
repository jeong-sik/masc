open Repo_manager_types

let merge_env overrides =
  let keys = List.map fst overrides in
  let has_key entry =
    match String.index_opt entry '=' with
    | None -> false
    | Some idx ->
        let key = String.sub entry 0 idx in
        List.exists (String.equal key) keys
  in
  let inherited =
    Unix.environment ()
    |> Array.to_list
    |> List.filter (fun entry -> not (has_key entry))
  in
	Array.of_list
	  (List.map (fun (k, v) -> Printf.sprintf "%s=%s" k v) overrides
	   @ inherited)

let git_terminal_prompt_key = "GIT_" ^ "TERMINAL_PROMPT"
let git_askpass_key = "GIT_" ^ "ASKPASS"

let non_interactive_git_env =
  [
    (git_terminal_prompt_key, "0");
    (git_askpass_key, "");
    ("SSH_ASKPASS", "");
    ("GCM_INTERACTIVE", "Never");
  ]

let split_lines text =
  if text = "" then []
  else String.split_on_char '\n' text |> List.filter (fun line -> line <> "")

type status_summary = {
  changed_files : int;
  staged_files : int;
  unstaged_files : int;
  untracked_files : int;
  conflicted_files : int;
}

let run_git ~cwd ?(env = []) args : (string list, string) result =
  let argv = "git" :: "-C" :: cwd :: args in
  let envp = merge_env env in
  let raw_source = String.concat " " (List.map Filename.quote argv) in
  let status, stdout, stderr =
    Masc_exec.Exec_gate.run_argv_with_status_split
      ~actor:(Masc_exec.Agent_id.of_string "repo-manager/git") ~raw_source ~summary:"repo manager git"
 ~env:envp argv
  in
  match status with
  | Unix.WEXITED 0 -> Ok (split_lines stdout)
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
      let status_text =
        match status with
        | Unix.WEXITED code -> Printf.sprintf "exit %d" code
        | Unix.WSIGNALED signal -> Printf.sprintf "signal %d" signal
        | Unix.WSTOPPED signal -> Printf.sprintf "stopped %d" signal
      in
      let detail =
        let stderr = String.trim stderr in
        let stdout = String.trim stdout in
        if stderr <> "" then status_text ^ ": " ^ stderr
        else if stdout <> "" then status_text ^ ": " ^ stdout
        else status_text
      in
      Error (Printf.sprintf "git %s failed: %s" (String.concat " " args) detail)

let clone ~repository =
  let env = non_interactive_git_env in
  let parent_dir = Filename.dirname repository.local_path in
  Fs_compat.mkdir_p parent_dir;
  match
    run_git ~cwd:parent_dir ~env
      ["clone"; repository.url; repository.local_path]
  with
  | Ok _ -> Ok ()
  | Error msg -> Error msg

let fetch ~repository : (string list, string) result =
  let env = non_interactive_git_env in
  match run_git ~env ~cwd:repository.local_path ["fetch"; "--all"] with
  | Error msg -> Error msg
  | Ok _ -> (
      match
        run_git ~cwd:repository.local_path
          ["branch"; "-r"; "--format=%(refname:short)"]
      with
      | Ok lines -> Ok lines
      | Error msg -> Error msg)

(* [fast_forward ~repository ~target_ref] advances the current branch to
   [target_ref] with `git merge --ff-only`. git refuses (non-zero exit) unless
   the move is a pure fast-forward: it never creates a merge commit, rebases, or
   rewrites history, so it cannot drop, reorder, or overwrite commits. A
   non-fast-forward (divergent tree) is returned as [Error] and the caller must
   preserve the tree rather than force the move. No credential is needed (the
   merge is local; the ref must already be fetched). *)
let fast_forward ~repository ~target_ref : (unit, string) result =
  match
    run_git ~cwd:repository.local_path [ "merge"; "--ff-only"; target_ref ]
  with
  | Ok _ -> Ok ()
  | Error msg -> Error msg

let get_branches ~repository =
  match
    run_git ~cwd:repository.local_path
      ["branch"; "-a"; "--format=%(refname:short)"]
  with
  | Ok lines -> Ok lines
  | Error msg -> Error msg

let get_origin_url ~local_path =
  match run_git ~cwd:local_path [ "remote"; "get-url"; "origin" ] with
  | Ok (url :: _) -> Ok url
  | Ok [] -> Error "git remote get-url origin returned no output"
  | Error msg -> Error msg

let get_recent_commits ~repository ~branch ~limit =
  match
    run_git ~cwd:repository.local_path
      ["log"; branch; "-n"; string_of_int limit; "--oneline"]
  with
  | Ok lines -> Ok lines
  | Error msg -> Error msg

let porcelain_conflict x y =
  match (x, y) with
  | 'D', 'D'
  | 'A', 'U'
  | 'U', 'D'
  | 'U', 'A'
  | 'D', 'U'
  | 'A', 'A'
  | 'U', 'U' -> true
  | _ -> false

let count_porcelain_line summary line =
  if String.length line < 2 then
    Stdlib.Error "git status --porcelain=v1 returned a malformed status row"
  else
    let x = String.get line 0 in
    let y = String.get line 1 in
    let is_untracked = Char.equal x '?' && Char.equal y '?' in
    let is_ignored = Char.equal x '!' && Char.equal y '!' in
    if is_ignored then Stdlib.Ok summary
    else
      let conflicted = porcelain_conflict x y in
      let staged =
        (not conflicted) && (not is_untracked) && not (Char.equal x ' ')
      in
      let unstaged =
        (not conflicted) && (not is_untracked) && not (Char.equal y ' ')
      in
      Stdlib.Ok
        {
          changed_files = summary.changed_files + 1;
          staged_files = summary.staged_files + if staged then 1 else 0;
          unstaged_files = summary.unstaged_files + if unstaged then 1 else 0;
          untracked_files =
            summary.untracked_files + if is_untracked then 1 else 0;
          conflicted_files =
            summary.conflicted_files + if conflicted then 1 else 0;
        }

let summarize_porcelain_lines lines =
  let ( let* ) = Result.bind in
  let empty =
    {
      changed_files = 0;
      staged_files = 0;
      unstaged_files = 0;
      untracked_files = 0;
      conflicted_files = 0;
    }
  in
  List.fold_left
    (fun acc line ->
      let* summary = acc in
      count_porcelain_line summary line)
    (Stdlib.Ok empty) lines

let status_summary ~repository =
  match
    run_git ~cwd:repository.local_path
      ["status"; "--porcelain=v1"; "--untracked-files=normal"]
  with
  | Stdlib.Error msg -> Stdlib.Error msg
  | Stdlib.Ok lines -> summarize_porcelain_lines lines
