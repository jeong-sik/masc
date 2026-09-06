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

let inspection_timeout_sec = 5.0

type origin_lookup_error =
  | Origin_missing
  | Origin_lookup_timed_out of string
  | Origin_lookup_failed of string

let origin_lookup_error_to_string = function
  | Origin_missing -> "origin remote is not configured"
  | Origin_lookup_timed_out detail -> detail
  | Origin_lookup_failed detail -> detail
;;

module Inspection_budget = struct
  type t =
    { started_at : Mtime.t
    ; timeout_sec : float
    }

  let create ?(timeout_sec = inspection_timeout_sec) () =
    if not (Float.is_finite timeout_sec && Float.compare timeout_sec 0.0 > 0)
    then invalid_arg "Repo_git.Inspection_budget.create: timeout_sec must be finite and positive";
    { started_at = Mtime_clock.now (); timeout_sec }
  ;;

  let elapsed_sec budget =
    Mtime.Span.to_float_ns (Mtime.span budget.started_at (Mtime_clock.now ())) /. 1e9
  ;;

  (* [open Repo_manager_types] above brings [repository_status]'s [Error of
     string] into scope, shadowing the result constructor. This budget answers
     with a result, so name the type and qualify the constructors. *)
  let remaining_timeout budget : (float, string) Stdlib.result =
    let remaining = budget.timeout_sec -. elapsed_sec budget in
    if Float.compare remaining 0.0 <= 0
    then Stdlib.Error "git inspection request budget exhausted"
    else Stdlib.Ok (min inspection_timeout_sec remaining)
  ;;

  let is_exhausted budget = Result.is_error (remaining_timeout budget)
end

let split_lines text =
  if text = "" then []
  else String.split_on_char '\n' text |> List.filter (fun line -> line <> "")

let git_failure_detail args status stdout stderr =
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
  Printf.sprintf "git %s failed: %s" (String.concat " " args) detail
;;

type status_summary = {
  changed_files : int;
  staged_files : int;
  unstaged_files : int;
  untracked_files : int;
  conflicted_files : int;
}

type status_file = {
  path : string;
  staged : bool;
  unstaged : bool;
  untracked : bool;
  conflicted : bool;
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

let run_git_raw ~cwd ?(env = []) ?timeout_sec args : (string, string) result =
  let argv = "git" :: "-C" :: cwd :: args in
  let envp = merge_env env in
  let status, stdout, stderr =
    Process_eio.run_argv_with_status_split
      ~env:envp ?timeout_sec argv
  in
  match status with
  | Unix.WEXITED 0 -> Ok stdout
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
    Error (git_failure_detail args status stdout stderr)

let run_git ~cwd ?(env = []) ?timeout_sec args : (string list, string) result =
  Result.map split_lines (run_git_raw ~cwd ~env ?timeout_sec args)

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

(* Bounded and read-only, matching [worktree_root] below. Reading a remote URL
   is a config lookup, but [run_git] defaults to no timeout, so a git index
   lock held by another process — or a stalled filesystem — would block the
   caller indefinitely. Both callers sit on request paths: repository checkout
   inspection renders a dashboard response, and write attribution is about to
   move onto the tool post-hook (RFC-keeper-workspace-root-only §5.1).

   [read_only_git_env] adds GIT_OPTIONAL_LOCKS=0 so an inspection never takes
   a lock that a keeper's own git command then waits on. *)
let get_origin_url ?(timeout_sec = inspection_timeout_sec) ~local_path () =
  let args = [ "remote"; "get-url"; "origin" ] in
  let argv = "git" :: "-C" :: local_path :: args in
  let status, stdout, stderr =
    Process_eio.run_argv_with_status_split
      ~env:(merge_env read_only_git_env)
      ~timeout_sec
      argv
  in
  match status, split_lines stdout with
  | Unix.WEXITED 0, url :: _ -> Ok url
  | Unix.WEXITED 0, [] ->
    Error (Origin_lookup_failed "git remote get-url origin returned no output")
  (* Git gives a missing remote a distinct exit status, so absence stays typed
     without inspecting mutable stderr text. *)
  | Unix.WEXITED 2, _ -> Error Origin_missing
  (* Process_eio owns what a timeout looks like; reading its number here made
     the two modules agree by coincidence (#28651). *)
  | status', _ when Process_eio.exit_reason_of_status status' = Process_eio.Timed_out ->
    Error (Origin_lookup_timed_out (git_failure_detail args status stdout stderr))
  | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _ ->
    Error (Origin_lookup_failed (git_failure_detail args status stdout stderr))

type checkout_identity = {
  toplevel : string;
  git_common_dir : string;
}

let checkout_identity ~local_path =
  (* Outputs arrive in argument order; [--path-format=absolute] pins
     both lines to absolute paths regardless of the cwd (git >= 2.31,
     far below any environment this runs in). *)
  match
    run_git
      ~cwd:local_path
      ~env:read_only_git_env
      ~timeout_sec:inspection_timeout_sec
      [ "rev-parse"
      ; "--path-format=absolute"
      ; "--show-toplevel"
      ; "--git-common-dir"
      ]
  with
  | Ok (toplevel :: git_common_dir :: _) ->
    let toplevel = String.trim toplevel in
    let git_common_dir = String.trim git_common_dir in
    if String.equal toplevel "" || String.equal git_common_dir ""
    then Stdlib.Error "git rev-parse checkout identity returned blank output"
    else Stdlib.Ok { toplevel; git_common_dir }
  | Ok _ ->
    Stdlib.Error "git rev-parse checkout identity returned too few lines"
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
      ~timeout_sec:inspection_timeout_sec
      [ "symbolic-ref"; "-q"; "refs/remotes/origin/HEAD" ]
  with
  | Ok (refname :: _) -> branch_of_origin_head_ref refname
  | Ok [] -> Stdlib.Error "git symbolic-ref refs/remotes/origin/HEAD returned no output"
  | Error msg -> Stdlib.Error msg

let current_branch ?(timeout_sec = inspection_timeout_sec) ~repository () =
  match
    run_git ~cwd:repository.local_path ~env:read_only_git_env
      ~timeout_sec
      [ "rev-parse"; "--abbrev-ref"; "HEAD" ]
  with
  | Ok (name :: _) -> Ok name
  | Ok [] -> Error "git rev-parse --abbrev-ref HEAD returned no output"
  | Error msg -> Error msg

let ahead_behind
    ?(timeout_sec = inspection_timeout_sec)
    ~repository
    ~target_ref
    ()
    : (int * int, string) result
  =
  match
    run_git ~cwd:repository.local_path ~env:read_only_git_env
      ~timeout_sec
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

let status_summary ?(timeout_sec = inspection_timeout_sec) ~repository () =
  match
    run_git ~cwd:repository.local_path ~env:read_only_git_env
      ~timeout_sec
      ["--no-optional-locks"; "status"; "--porcelain=v1"; "--untracked-files=normal"]
  with
  | Stdlib.Error msg -> Stdlib.Error msg
  | Stdlib.Ok lines -> status_summary_of_porcelain_lines lines

let status_file_of_porcelain_record record =
  if String.length record < 4 || not (Char.equal record.[2] ' ')
  then Stdlib.Error "git status --porcelain=v1 -z returned a malformed status row"
  else
    let x = record.[0] in
    let y = record.[1] in
    let path = String.sub record 3 (String.length record - 3) in
    if not (is_porcelain_status_char x && is_porcelain_status_char y)
    then
      Stdlib.Error
        (Printf.sprintf
           "git status --porcelain=v1 -z returned unknown status row %S"
           record)
    else if String.equal path ""
    then Stdlib.Error "git status --porcelain=v1 -z returned a status row without a path"
    else
      let untracked = Char.equal x '?' && Char.equal y '?' in
      let ignored = Char.equal x '!' && Char.equal y '!' in
      let conflicted = is_unmerged_status x y in
      if ignored
      then Stdlib.Ok None
      else if
        ((Char.equal x '?' || Char.equal y '?') && not untracked)
        || ((Char.equal x '!' || Char.equal y '!') && not ignored)
        || ((Char.equal x 'U' || Char.equal y 'U') && not conflicted)
      then
        Stdlib.Error
          (Printf.sprintf
             "git status --porcelain=v1 -z returned unknown status row %S"
             record)
      else
        Stdlib.Ok
          (Some
             { path
             ; staged = not conflicted && not untracked && not (Char.equal x ' ')
             ; unstaged = not conflicted && not untracked && not (Char.equal y ' ')
             ; untracked
             ; conflicted
             })

let status_files_of_porcelain_z output =
  let records = String.split_on_char '\000' output in
  let records =
    match List.rev records with
    | "" :: rest -> List.rev rest
    | _ -> records
  in
  let ( let* ) = Result.bind in
  List.fold_left
    (fun result record ->
      let* files = result in
      let* file = status_file_of_porcelain_record record in
      Stdlib.Ok (Option.fold ~none:files ~some:(fun row -> row :: files) file))
    (Stdlib.Ok []) records
  |> Result.map List.rev

let status_files_at ?(timeout_sec = inspection_timeout_sec) ~local_path () =
  match
    run_git_raw ~cwd:local_path ~env:read_only_git_env ~timeout_sec
      [ "--no-optional-locks"; "status"; "--porcelain=v1"; "-z"
      ; "--no-renames"; "--untracked-files=normal"
      ]
  with
  | Stdlib.Error msg -> Stdlib.Error msg
  | Stdlib.Ok output -> status_files_of_porcelain_z output

let status_files ?timeout_sec ~repository () =
  status_files_at ?timeout_sec ~local_path:repository.local_path ()
