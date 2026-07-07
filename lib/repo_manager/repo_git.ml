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

let ahead_behind ~repository ~target_ref =
  match
    run_git ~cwd:repository.local_path ~env:read_only_git_env
      ~timeout_sec:inspect_timeout_sec
      [ "rev-list"; "--left-right"; "--count"; target_ref ^ "...HEAD" ]
  with
  | Error msg -> Error msg
  | Ok [] -> Error "git rev-list --left-right --count returned no output"
  | Ok (line :: _) -> (
      match String.split_on_char '\t' (String.trim line) with
      | [ behind; ahead ] -> (
          match
            ( int_of_string_opt (String.trim behind),
              int_of_string_opt (String.trim ahead) )
          with
          | Some behind, Some ahead -> Ok (behind, ahead)
          | _ ->
              Error
                (Printf.sprintf
                   "git rev-list --left-right --count returned non-numeric output: %S"
                   line))
      | _ ->
          Error
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
  | Stdlib.Ok lines -> (
      match
        Masc_exec.Output_parse.summarize_git_status_porcelain
          (String.concat "\n" lines)
      with
      | Error msg -> Error msg
      | Ok summary ->
          Ok
            {
              changed_files = summary.changed_files;
              staged_files = summary.staged_files;
              unstaged_files = summary.unstaged_files;
              untracked_files = summary.untracked_files;
              conflicted_files = summary.conflicted_files;
            })
