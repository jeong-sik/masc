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

let read_only_git_env = ("GIT_OPTIONAL_LOCKS", "0") :: non_interactive_git_env

let status_summary_timeout_sec = 5.0

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

let empty_status_summary =
  { changed_files = 0
  ; staged_files = 0
  ; unstaged_files = 0
  ; untracked_files = 0
  ; conflicted_files = 0
  }
;;

let is_porcelain_status_char = function
  | ' ' | 'M' | 'A' | 'D' | 'R' | 'C' | 'T' | 'U' | '?' | '!' -> true
  | _ -> false
;;

let is_unmerged_status x y =
  match x, y with
  | ('D', 'D')
  | ('A', 'U')
  | ('U', 'D')
  | ('U', 'A')
  | ('D', 'U')
  | ('A', 'A')
  | ('U', 'U') -> true
  | _ -> false
;;

let update_status_summary summary line =
  if String.length line < 3
  then Stdlib.Error "git status --porcelain=v1 returned a malformed status row"
  else
    let x = line.[0] in
    let y = line.[1] in
    let path = String.sub line 2 (String.length line - 2) |> String.trim in
    if not (is_porcelain_status_char x && is_porcelain_status_char y)
    then Stdlib.Error (Printf.sprintf "git status --porcelain=v1 returned unknown status row %S" line)
    else if String.equal path ""
    then Stdlib.Error "git status --porcelain=v1 returned a status row without a path"
    else
      let untracked = Char.equal x '?' && Char.equal y '?' in
      let ignored = Char.equal x '!' && Char.equal y '!' in
      let conflicted = is_unmerged_status x y in
      if ignored
      then Stdlib.Ok summary
      else if
        ((Char.equal x '?' || Char.equal y '?') && not untracked)
        || ((Char.equal x '!' || Char.equal y '!') && not ignored)
        || ((Char.equal x 'U' || Char.equal y 'U') && not conflicted)
      then
        Stdlib.Error
          (Printf.sprintf
             "git status --porcelain=v1 returned unknown status row %S"
             line)
      else
        let staged = not conflicted && not untracked && not (Char.equal x ' ') in
        let unstaged = not conflicted && not untracked && not (Char.equal y ' ') in
        Stdlib.Ok
          { changed_files = summary.changed_files + 1
          ; staged_files = summary.staged_files + if staged then 1 else 0
          ; unstaged_files = summary.unstaged_files + if unstaged then 1 else 0
          ; untracked_files = summary.untracked_files + if untracked then 1 else 0
          ; conflicted_files = summary.conflicted_files + if conflicted then 1 else 0
          }
;;

let status_summary_of_porcelain_lines lines =
  let ( let* ) = Result.bind in
  List.fold_left
    (fun result line ->
       let* summary = result in
       update_status_summary summary line)
    (Stdlib.Ok empty_status_summary)
    lines
;;

let run_git ~cwd ?(env = []) ?timeout_sec args : (string list, string) result =
  let argv = "git" :: "-C" :: cwd :: args in
  let envp = merge_env env in
  let raw_source = String.concat " " (List.map Filename.quote argv) in
  let status, stdout, stderr =
    Masc_exec.Exec_gate.run_argv_with_status_split
      ~actor:(Masc_exec.Agent_id.of_string "repo-manager/git") ~raw_source ~summary:"repo manager git"
      ~env:envp ?timeout_sec argv
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
    run_git ~cwd:repository.local_path
      [ "-c"; "core.hooksPath=/dev/null"; "merge"; "--ff-only"; target_ref ]
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

let worktree_root ~local_path =
  match
    run_git
      ~cwd:local_path
      ~env:read_only_git_env
      ~timeout_sec:status_summary_timeout_sec
      [ "rev-parse"; "--show-toplevel" ]
  with
  | Ok (root :: _) ->
    let root = String.trim root in
    if String.equal root ""
    then Stdlib.Error "git rev-parse --show-toplevel returned blank"
    else Stdlib.Ok root
  | Ok [] -> Stdlib.Error "git rev-parse --show-toplevel returned no output"
  | Error msg -> Stdlib.Error msg

let branch_of_origin_head_ref refname =
  let refname = String.trim refname in
  let prefix = "refs/remotes/origin/" in
  if String.starts_with ~prefix refname
  then
    let branch =
      String.sub refname (String.length prefix) (String.length refname - String.length prefix)
      |> String.trim
    in
    if String.equal branch ""
    then
      Stdlib.Error
        (Printf.sprintf
           "git symbolic-ref refs/remotes/origin/HEAD returned invalid ref: %S"
           refname)
    else Stdlib.Ok branch
  else
    Stdlib.Error
      (Printf.sprintf
         "git symbolic-ref refs/remotes/origin/HEAD returned invalid ref: %S"
         refname)
;;

let origin_head_branch ~local_path =
  match
    run_git
      ~cwd:local_path
      ~env:read_only_git_env
      ~timeout_sec:status_summary_timeout_sec
      [ "symbolic-ref"; "-q"; "refs/remotes/origin/HEAD" ]
  with
  | Ok (refname :: _) -> branch_of_origin_head_ref refname
  | Ok [] -> Stdlib.Error "git symbolic-ref refs/remotes/origin/HEAD returned no output"
  | Error msg -> Stdlib.Error msg

let inspect_timeout_sec = status_summary_timeout_sec

let current_branch ~repository =
  match
    run_git ~cwd:repository.local_path ~env:read_only_git_env
      ~timeout_sec:inspect_timeout_sec
      [ "rev-parse"; "--abbrev-ref"; "HEAD" ]
  with
  | Ok (name :: _) -> Ok name
  | Ok [] -> Error "git rev-parse --abbrev-ref HEAD returned no output"
  | Error msg -> Error msg

let ahead_behind ~repository ~target_ref : (int * int, string) result =
  match
    run_git ~cwd:repository.local_path ~env:read_only_git_env
      ~timeout_sec:inspect_timeout_sec
      [ "rev-list"; "--left-right"; "--count"; target_ref ^ "...HEAD" ]
  with
  | Stdlib.Error msg -> Stdlib.Error msg
  | Stdlib.Ok [] -> Stdlib.Error "git rev-list --left-right --count returned no output"
  | Stdlib.Ok (line :: _) -> (
      match String.split_on_char '\t' (String.trim line) with
      | [ behind; ahead ] -> (
          match
            ( int_of_string_opt (String.trim behind),
              int_of_string_opt (String.trim ahead) )
          with
          | Some behind, Some ahead -> Stdlib.Ok (behind, ahead)
          | _ ->
              Stdlib.Error
                (Printf.sprintf
                   "git rev-list --left-right --count returned non-numeric output: %S"
                   line))
      | _ ->
          Stdlib.Error
            (Printf.sprintf
               "git rev-list --left-right --count returned malformed output: %S"
               line))

let get_recent_commits ~repository ~branch ~limit =
  match
    run_git ~cwd:repository.local_path
      ["log"; branch; "-n"; string_of_int limit; "--oneline"]
  with
  | Ok lines -> Ok lines
  | Error msg -> Error msg

let status_summary ~repository =
  match
    run_git ~cwd:repository.local_path ~env:read_only_git_env
      ~timeout_sec:status_summary_timeout_sec
      ["--no-optional-locks"; "status"; "--porcelain=v1"; "--untracked-files=normal"]
  with
  | Stdlib.Error msg -> Stdlib.Error msg
  | Stdlib.Ok lines -> status_summary_of_porcelain_lines lines
