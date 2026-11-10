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

(* A remote that accepts the connection and then sends nothing holds a fetch or
   clone forever, because git sets no deadline of its own. Over HTTP(S), curl
   ends a transfer that moves fewer than [network_stall_bytes_per_sec] bytes a
   second for [network_stall_sec] seconds. A slow transfer that keeps moving is
   not cut, so a large clone has no total-time limit. A git server sends a
   keepalive every few seconds while it builds a pack, so a quiet minute means
   the remote stopped. Other transports keep only their own timeouts. *)
let network_stall_bytes_per_sec = 1
let network_stall_sec = 60

let network_git_env =
  ("GIT_HTTP_LOW_SPEED_LIMIT", string_of_int network_stall_bytes_per_sec)
  :: ("GIT_HTTP_LOW_SPEED_TIME", string_of_int network_stall_sec)
  :: non_interactive_git_env

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
  let open Result.Syntax in
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

let run_git_read_only_raw ~cwd args = run_git_raw ~cwd ~env:read_only_git_env args

let clone ~repository =
  let env = network_git_env in
  let parent_dir = Filename.dirname repository.local_path in
  Fs_compat.mkdir_p parent_dir;
  match
    run_git ~cwd:parent_dir ~env
      ["clone"; repository.url; repository.local_path]
  with
  | Ok _ -> Ok ()
  | Error msg -> Error msg

(* FETCH_HEAD is used here only at the completion boundary of our own fetch.
   A later unrelated fetch can change its mtime or append old lines, so readers
   use the atomic receipt instead of treating FETCH_HEAD as a clock. *)
let record_target_fetch ~repository =
  let open Result.Syntax in
  let cwd = repository.local_path in
  let first args =
    match run_git ~cwd args with
    | Ok (line :: _) -> Ok line
    | Ok [] -> Error ("git " ^ String.concat " " args ^ " returned no output")
    | Error _ as error -> error
  in
  let* common_dir = first [ "rev-parse"; "--path-format=absolute"; "--git-common-dir" ] in
  let* origin_url = first [ "remote"; "get-url"; "origin" ] in
  let target_ref = "origin/" ^ repository.default_branch in
  let* oid = first [ "rev-parse"; target_ref ] in
  let fetch_head = Filename.concat common_dir "FETCH_HEAD" in
  let prefix = "branch '" ^ repository.default_branch ^ "' of " in
  let fetched =
    try
      In_channel.with_open_bin fetch_head (fun input ->
        let rec scan () =
          match input_line input with
          | line ->
            (match String.split_on_char '\t' line with
             | [ fetched_oid; _; description ]
               when String.equal fetched_oid oid
                    && String.equal description (prefix ^ origin_url) -> true
             | _ -> scan ())
          | exception End_of_file -> false
        in
        scan ())
    with Sys_error _ -> false
  in
  if not fetched then Ok ()
  else
    Repo_fetch_observation.write ~common_dir
      { common_dir
      ; origin_url
      ; target_ref
      ; oid
        (* DET-OK: recorded once after the named ref's successful fetch. *)
      ; observed_at_unix = int_of_float (Unix.gettimeofday ())
      }
;;

let fetch ~repository : (string list, string) result =
  let env = network_git_env in
  match run_git ~env ~cwd:repository.local_path
          [ "-c"; "fetch.append=false"; "fetch"; "--all" ] with
  | Error msg -> Error msg
  | Ok _ -> (
      (match record_target_fetch ~repository with
       | Ok () -> ()
       | Error message -> Log.Misc.warn "repo target fetch receipt: %s" message);
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
   inspection renders a dashboard response, and write attribution reads it on
   the tool post-hook (RFC-keeper-workspace-root-only §5.1).

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

let checkout_identity ?(timeout_sec = inspection_timeout_sec) ~local_path () =
  (* Outputs arrive in argument order; [--path-format=absolute] pins
     both lines to absolute paths regardless of the cwd (git >= 2.31,
     far below any environment this runs in). *)
  match
    run_git
      ~cwd:local_path
      ~env:read_only_git_env
      ~timeout_sec
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

let common_dir ?(timeout_sec = inspection_timeout_sec) ~local_path () =
  match run_git ~cwd:local_path ~env:read_only_git_env ~timeout_sec
          [ "rev-parse"; "--path-format=absolute"; "--git-common-dir" ] with
  | Ok [ path ] when not (String.equal path "") -> Stdlib.Ok path
  | Ok _ -> Stdlib.Error "git rev-parse common directory returned unexpected output"
  | Error detail -> Stdlib.Error detail
;;

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
  let open Result.Syntax in
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

type upstream_state =
  | No_upstream
  | Upstream_gone of string
  | Tracking of { upstream : string; ahead : int; behind : int }

type branch_status =
  | Detached
  | On_branch of { name : string; upstream : upstream_state }

(* Porcelain v2 prints "(detached)" as [branch.head] for a detached HEAD. A
   branch literally named "(detached)" is a legal ref name and would read as
   detached here; Git offers no other field in this output to tell them apart. *)
let detached_head_marker = "(detached)"

let parse_branch_ahead_behind value =
  match String.split_on_char ' ' value with
  | [ ahead; behind ]
    when String.length ahead > 1
         && ahead.[0] = '+'
         && String.length behind > 1
         && behind.[0] = '-' ->
      let count field =
        int_of_string_opt (String.sub field 1 (String.length field - 1))
      in
      (match count ahead, count behind with
       | Some ahead, Some behind -> Stdlib.Ok (ahead, behind)
       | _ ->
           Stdlib.Error
             (Printf.sprintf "git status branch.ab has non-numeric counts: %S" value))
  | _ ->
      Stdlib.Error
        (Printf.sprintf "git status branch.ab is malformed: %S" value)

let branch_status_of_porcelain_v2_z output =
  let header_value ~key record =
    let prefix = "# " ^ key ^ " " in
    if String.starts_with ~prefix record then
      Some
        (String.sub record (String.length prefix)
           (String.length record - String.length prefix))
    else None
  in
  (* Headers precede every entry record, so the first record that is not a
     "# " header ends them. *)
  let rec headers acc = function
    | record :: rest when String.starts_with ~prefix:"# " record ->
        headers (record :: acc) rest
    | _ -> List.rev acc
  in
  let records = headers [] (String.split_on_char '\000' output) in
  let find key = List.find_map (header_value ~key) records in
  match find "branch.head" with
  | None -> Stdlib.Error "git status --branch printed no branch.head header"
  | Some head when String.equal head detached_head_marker -> Stdlib.Ok Detached
  | Some name ->
      (match find "branch.upstream", find "branch.ab" with
       | None, _ -> Stdlib.Ok (On_branch { name; upstream = No_upstream })
       | Some upstream, None ->
           Stdlib.Ok (On_branch { name; upstream = Upstream_gone upstream })
       | Some upstream, Some counts ->
           (match parse_branch_ahead_behind counts with
            | Stdlib.Error msg -> Stdlib.Error msg
            | Stdlib.Ok (ahead, behind) ->
                Stdlib.Ok
                  (On_branch { name; upstream = Tracking { upstream; ahead; behind } })))

let branch_status_at ?(timeout_sec = inspection_timeout_sec) ~local_path () =
  match
    run_git_raw ~cwd:local_path ~env:read_only_git_env ~timeout_sec
      [ "--no-optional-locks"; "status"; "--porcelain=v2"; "--branch"; "-z"
      ; "--untracked-files=no"
      ]
  with
  | Stdlib.Error msg -> Stdlib.Error msg
  | Stdlib.Ok output -> branch_status_of_porcelain_v2_z output

type branch_entry = {
  be_name : string;
  be_current : bool;
  be_upstream : upstream_state;
  be_commit_epoch : int;
  be_subject : string;
}

type branch_list = {
  bl_entries : branch_entry list;
  bl_truncated : bool;
}

type branch_track =
  | Track_in_step
  | Track_gone
  | Track_counts of int * int

(* [%(upstream:track,nobracket)] is one of: empty (in step with the upstream),
   [gone], [ahead N], [behind M] or [ahead N, behind M]. Any other text is an
   error, never read as "in step". *)
let branch_track_of_field field =
  let count prefix part =
    let length = String.length prefix in
    if String.length part > length && String.equal (String.sub part 0 length) prefix then
      match int_of_string_opt (String.sub part length (String.length part - length)) with
      | Some n when n > 0 -> Some n
      | Some _ | None -> None
    else None
  in
  match String.split_on_char ',' field |> List.map String.trim with
  | [ "" ] -> Stdlib.Ok Track_in_step
  | [ "gone" ] -> Stdlib.Ok Track_gone
  | [ part ] ->
      (match count "ahead " part, count "behind " part with
       | Some ahead, None -> Stdlib.Ok (Track_counts (ahead, 0))
       | None, Some behind -> Stdlib.Ok (Track_counts (0, behind))
       | Some _, Some _ | None, None ->
           Stdlib.Error (Printf.sprintf "git branch has an unreadable track field: %S" field))
  | [ first; second ] ->
      (match count "ahead " first, count "behind " second with
       | Some ahead, Some behind -> Stdlib.Ok (Track_counts (ahead, behind))
       | Some _, None | None, Some _ | None, None ->
           Stdlib.Error (Printf.sprintf "git branch has an unreadable track field: %S" field))
  | _ ->
      Stdlib.Error (Printf.sprintf "git branch has an unreadable track field: %S" field)

(* One record of the [for-each-ref] format used by [branches_at]:
   [HEAD NUL name NUL upstream NUL track NUL epoch NUL subject]. A record is one
   line because a ref name and a subject hold no newline. *)
let branch_entry_of_record record =
  match String.split_on_char '\000' record with
  | [ head; name; upstream; track; epoch; subject ] ->
      let ( let* ) = Stdlib.Result.bind in
      let* be_current =
        match head with
        | "*" -> Stdlib.Ok true
        | " " -> Stdlib.Ok false
        | other -> Stdlib.Error (Printf.sprintf "git branch has an unreadable HEAD mark: %S" other)
      in
      let* be_commit_epoch =
        match int_of_string_opt epoch with
        | Some value when value >= 0 -> Stdlib.Ok value
        | Some _ | None ->
            Stdlib.Error (Printf.sprintf "git branch has an unreadable commit time: %S" epoch)
      in
      let* track = branch_track_of_field track in
      let* be_upstream =
        match upstream, track with
        | "", Track_in_step -> Stdlib.Ok No_upstream
        | "", (Track_gone | Track_counts (_, _)) ->
            Stdlib.Error "git branch reports tracking counts without an upstream"
        | upstream, Track_in_step ->
            Stdlib.Ok (Tracking { upstream; ahead = 0; behind = 0 })
        | upstream, Track_gone -> Stdlib.Ok (Upstream_gone upstream)
        | upstream, Track_counts (ahead, behind) ->
            Stdlib.Ok (Tracking { upstream; ahead; behind })
      in
      if String.equal name "" then Stdlib.Error "git branch row has an empty name"
      else Stdlib.Ok { be_name = name; be_current; be_upstream; be_commit_epoch; be_subject = subject }
  | fields ->
      Stdlib.Error
        (Printf.sprintf "git branch row has %d fields, expected 6" (List.length fields))

(* Keeps the first [max_entries] records. A record after that proves the list was
   cut. The checked-out branch among the cut records follows the kept ones, so
   a current branch whose tip is older than every kept tip stays listed and the
   newest-first order holds. A malformed record that is kept is an error, never
   a skipped one. *)
let branch_list_of_for_each_ref ~max_entries output =
  if max_entries < 1 then Stdlib.Error "git branch listing needs max_entries of at least 1"
  else
    let records =
      match List.rev (String.split_on_char '\n' output) with
      | "" :: rest -> List.rev rest
      | _ -> String.split_on_char '\n' output
    in
    let marks_head record =
      match String.split_on_char '\000' record with
      | "*" :: _ -> true
      | [] | _ :: _ -> false
    in
    let rec take acc count = function
      | [] -> Stdlib.Ok { bl_entries = List.rev acc; bl_truncated = false }
      | _ :: _ as cut when count >= max_entries ->
          (match List.find_opt marks_head cut with
           | None -> Stdlib.Ok { bl_entries = List.rev acc; bl_truncated = true }
           | Some record ->
               (match branch_entry_of_record record with
                | Stdlib.Error msg -> Stdlib.Error msg
                | Stdlib.Ok current ->
                    Stdlib.Ok
                      { bl_entries = List.rev_append acc [ current ]; bl_truncated = true }))
      | record :: rest ->
          (match branch_entry_of_record record with
           | Stdlib.Error msg -> Stdlib.Error msg
           | Stdlib.Ok entry -> take (entry :: acc) (count + 1) rest)
    in
    take [] 0 records

let branches_at ?(timeout_sec = inspection_timeout_sec) ~local_path ~max_entries () =
  match
    run_git_raw ~cwd:local_path ~env:read_only_git_env ~timeout_sec
      [ "--no-optional-locks"; "for-each-ref"; "--sort=-committerdate"
      ; "--format=%(HEAD)%00%(refname:lstrip=2)%00%(upstream:short)%00%(upstream:track,nobracket)%00%(committerdate:unix)%00%(contents:subject)"
      ; "refs/heads/"
      ]
  with
  | Stdlib.Error msg -> Stdlib.Error msg
  | Stdlib.Ok output -> branch_list_of_for_each_ref ~max_entries output

type worktree_state =
  | Worktree_branch of string
  | Worktree_detached
  | Worktree_bare

type worktree_entry = {
  wt_name : string;
  wt_main : bool;
  wt_head : string option;
  wt_state : worktree_state;
  wt_locked : bool;
  wt_prunable : bool;
}

type worktree_list = {
  wl_entries : worktree_entry list;
  wl_truncated : bool;
}

(* Fields of one [git worktree list --porcelain -z] record, filled as the
   attribute lines are read. [wf_state] is the one of branch, detached and bare
   that the record named. *)
type worktree_fields = {
  wf_head : string option;
  wf_state : worktree_state option;
  wf_locked : bool;
  wf_prunable : bool;
}

let worktree_value ~prefix field =
  let prefix_length = String.length prefix in
  if String.length field >= prefix_length
     && String.equal (String.sub field 0 prefix_length) prefix
  then Some (String.sub field prefix_length (String.length field - prefix_length))
  else None

(* [locked] and [prunable] carry an optional free-text reason after a space.
   The reason is dropped: only whether the worktree is flagged is kept. *)
let worktree_flag ~name field =
  String.equal field name || Option.is_some (worktree_value ~prefix:(name ^ " ") field)

let worktree_is_hex value =
  let hex = function '0' .. '9' | 'a' .. 'f' -> true | _ -> false in
  String.length value > 0 && String.for_all hex value

let rec worktree_read_fields acc = function
  | [] -> Stdlib.Ok acc
  | field :: rest ->
      let ( let* ) = Stdlib.Result.bind in
      let set_state state =
        match acc.wf_state with
        | None -> Stdlib.Ok { acc with wf_state = Some state }
        | Some _ -> Stdlib.Error "git worktree record names its checkout state twice"
      in
      let* acc =
        match worktree_value ~prefix:"HEAD " field with
        | Some head ->
            if not (worktree_is_hex head) then
              Stdlib.Error (Printf.sprintf "git worktree has an unreadable HEAD: %S" head)
            else (
              match acc.wf_head with
              | None -> Stdlib.Ok { acc with wf_head = Some head }
              | Some _ -> Stdlib.Error "git worktree record names HEAD twice")
        | None ->
            (match worktree_value ~prefix:"branch refs/heads/" field with
             | Some name when not (String.equal name "") -> set_state (Worktree_branch name)
             | Some _ -> Stdlib.Error "git worktree record has an empty branch name"
             | None ->
                 if String.equal field "detached" then set_state Worktree_detached
                 else if String.equal field "bare" then set_state Worktree_bare
                 else if worktree_flag ~name:"locked" field then
                   Stdlib.Ok { acc with wf_locked = true }
                 else if worktree_flag ~name:"prunable" field then
                   Stdlib.Ok { acc with wf_prunable = true }
                 else
                   Stdlib.Error
                     (Printf.sprintf "git worktree record has an unknown field: %S" field))
      in
      worktree_read_fields acc rest

(* One record: [worktree PATH] first, then attribute lines. Only the last path
   component is kept, because the list is served to clients that may not see
   the host's directory layout. *)
let worktree_entry_of_record ~main = function
  | [] -> Stdlib.Error "git worktree record is empty"
  | first :: rest ->
      let ( let* ) = Stdlib.Result.bind in
      let* path =
        match worktree_value ~prefix:"worktree " first with
        | Some path when not (String.equal path "") -> Stdlib.Ok path
        | Some _ | None ->
            Stdlib.Error (Printf.sprintf "git worktree record does not start with a path: %S" first)
      in
      let wt_name = Filename.basename path in
      let* () =
        if String.equal wt_name "" || String.equal wt_name "/" then
          Stdlib.Error (Printf.sprintf "git worktree path has no name: %S" path)
        else Stdlib.Ok ()
      in
      let* fields =
        worktree_read_fields
          { wf_head = None; wf_state = None; wf_locked = false; wf_prunable = false }
          rest
      in
      let* wt_state =
        match fields.wf_state with
        | Some state -> Stdlib.Ok state
        | None -> Stdlib.Error (Printf.sprintf "git worktree %S names no checkout state" wt_name)
      in
      (match wt_state, fields.wf_head with
       | Worktree_bare, (Some _ | None) | (Worktree_branch _ | Worktree_detached), Some _ ->
           Stdlib.Ok
             { wt_name; wt_main = main; wt_head = fields.wf_head; wt_state
             ; wt_locked = fields.wf_locked; wt_prunable = fields.wf_prunable }
       | (Worktree_branch _ | Worktree_detached), None ->
           Stdlib.Error (Printf.sprintf "git worktree %S has no HEAD" wt_name))

(* Splits the NUL stream into records. A field ends at a NUL and a record at an
   empty field, so a stream cut inside a record has a non-empty tail and is an
   error rather than a shorter list. *)
let worktree_records_of_output output =
  let fields = String.split_on_char '\000' output in
  let rec group current records = function
    | [] ->
        (match current with
         | [] -> Stdlib.Ok (List.rev records)
         | _ :: _ -> Stdlib.Error "git worktree list output ends inside a record")
    | "" :: rest ->
        (match current with
         | [] -> group [] records rest
         | _ :: _ -> group [] (List.rev current :: records) rest)
    | field :: rest -> group (field :: current) records rest
  in
  (* [split_on_char] yields a final "" for the closing NUL of a complete
     stream. Without a closing NUL the last field is non-empty and [group]
     reports the cut. *)
  group [] [] fields

let worktree_list_of_porcelain ~max_entries output =
  if max_entries < 1 then Stdlib.Error "git worktree listing needs max_entries of at least 1"
  else
    let ( let* ) = Stdlib.Result.bind in
    let* records = worktree_records_of_output output in
    let rec take acc count = function
      | [] -> Stdlib.Ok { wl_entries = List.rev acc; wl_truncated = false }
      | _ :: _ when count >= max_entries ->
          Stdlib.Ok { wl_entries = List.rev acc; wl_truncated = true }
      | record :: rest ->
          (match worktree_entry_of_record ~main:(count = 0) record with
           | Stdlib.Error msg -> Stdlib.Error msg
           | Stdlib.Ok entry -> take (entry :: acc) (count + 1) rest)
    in
    take [] 0 records

let worktrees_at ?(timeout_sec = inspection_timeout_sec) ~local_path ~max_entries () =
  match
    run_git_raw ~cwd:local_path ~env:read_only_git_env ~timeout_sec
      [ "--no-optional-locks"; "worktree"; "list"; "--porcelain"; "-z" ]
  with
  | Stdlib.Error msg -> Stdlib.Error msg
  | Stdlib.Ok output -> worktree_list_of_porcelain ~max_entries output

let file_paths_at ?(timeout_sec = inspection_timeout_sec) ~local_path () =
  match
    run_git_raw ~cwd:local_path ~env:read_only_git_env ~timeout_sec
      [ "--no-optional-locks"; "ls-files"; "--cached"; "--others"
      ; "--exclude-standard"; "--full-name"; "-z"; "--"
      ]
  with
  | Stdlib.Error detail -> Stdlib.Error detail
  | Stdlib.Ok "" -> Stdlib.Ok []
  | Stdlib.Ok output ->
      (match List.rev (String.split_on_char '\000' output) with
       | "" :: records when not (List.exists (String.equal "") records) ->
           Stdlib.Ok (List.sort_uniq String.compare records)
       | _ -> Stdlib.Error "git ls-files returned malformed NUL-delimited paths")

let status_snapshot_at ?timeout_sec ~local_path () =
  match
    ( status_files_at ?timeout_sec ~local_path ()
    , branch_status_at ?timeout_sec ~local_path () )
  with
  | Stdlib.Error msg, _ | _, Stdlib.Error msg -> Stdlib.Error msg
  | Stdlib.Ok files, Stdlib.Ok branch -> Stdlib.Ok (files, branch)

type grep_match = {
  gm_path : string;
  gm_line : int;
  gm_text : string;
}

type grep_result = {
  gr_matches : grep_match list;
  gr_truncated : bool;
}

(* Per file, so one generated file cannot fill the answer by itself. *)
let grep_max_matches_per_file = 20

(* One row of [git grep -n -z] starting at [pos]: [path NUL line NUL text LF].
   Git prints the path verbatim under [-z], so a path may hold a newline; only
   the text is a single source line. The row is therefore framed by its two NULs
   and ends at the first newline after the second one. Returns the row and the
   offset of the next one. *)
let grep_row_at output pos =
  let length = String.length output in
  let describe () = String.escaped (String.sub output pos (min 80 (length - pos))) in
  match String.index_from_opt output pos '\000' with
  | None ->
      Stdlib.Error (Printf.sprintf "git grep row has no path separator: %s" (describe ()))
  | Some first ->
      (match String.index_from_opt output (first + 1) '\000' with
       | None ->
           Stdlib.Error
             (Printf.sprintf "git grep row has no line separator: %s" (describe ()))
       | Some second ->
           let path = String.sub output pos (first - pos) in
           let line_field = String.sub output (first + 1) (second - first - 1) in
           let text_end =
             match String.index_from_opt output (second + 1) '\n' with
             | Some newline -> newline
             | None -> length
           in
           let text = String.sub output (second + 1) (text_end - second - 1) in
           (match int_of_string_opt line_field with
            | Some line when line > 0 && String.length path > 0 ->
                Stdlib.Ok
                  ({ gm_path = path; gm_line = line; gm_text = text }, min length (text_end + 1))
            | Some _ | None ->
                Stdlib.Error
                  (Printf.sprintf "git grep row has a bad line number: %S" line_field)))

(* Reads rows until [max_matches] are held. A row after that proves the answer
   was cut. So does a file that reached the per-file cap, since git stops
   reading it there. A malformed row is an error, never a skipped one: the
   captured output can carry a truncation marker when it exceeds the process
   capture, and a silent skip would present a partial list as the whole
   answer. *)
let grep_result_of_z_output ~max_matches output =
  let length = String.length output in
  let per_path = Hashtbl.create 16 in
  let rec take acc count capped pos =
    if pos >= length then Stdlib.Ok { gr_matches = List.rev acc; gr_truncated = capped }
    else if count >= max_matches then
      Stdlib.Ok { gr_matches = List.rev acc; gr_truncated = true }
    else
      match grep_row_at output pos with
      | Stdlib.Error msg -> Stdlib.Error msg
      | Stdlib.Ok (found, next) ->
          let seen =
            1 + Option.value ~default:0 (Hashtbl.find_opt per_path found.gm_path)
          in
          Hashtbl.replace per_path found.gm_path seen;
          take (found :: acc) (count + 1)
            (capped || seen >= grep_max_matches_per_file)
            next
  in
  if max_matches < 1 then Stdlib.Error "git grep needs max_matches of at least 1"
  else take [] 0 false 0

(* [--untracked] does not mean "also the untracked files" on every Git: on
   git 2.54 it applies the ignore rules to tracked paths too and drops a
   tracked file that a .gitignore pattern matches, which older Git kept. The
   tracked files are therefore read by a run without [--untracked], and the
   non-ignored untracked ones by a run with it. *)
type grep_scope = Tracked | Untracked_not_ignored

let grep_scope_args = function
  | Tracked -> []
  | Untracked_not_ignored -> [ "--untracked"; "--exclude-standard" ]

let grep_in_scope ~timeout_sec ~local_path ~pathspec ~pattern ~ignore_case ~max_matches scope =
  let args =
    [ "--no-optional-locks"; "--literal-pathspecs"; "grep"; "-n"; "-I"; "-z"
    ; "-F"; "--no-color" ]
    @ grep_scope_args scope
    @ [ "-m"; string_of_int grep_max_matches_per_file ]
    @ (if ignore_case then [ "-i" ] else [])
    @ [ "-e"; pattern ]
    @ (if String.equal pathspec "" then [] else [ "--"; pathspec ])
  in
  let status, stdout, stderr =
    Process_eio.run_argv_with_status_split
      ~env:(merge_env read_only_git_env)
      ~timeout_sec
      ("git" :: "-C" :: local_path :: args)
  in
  match status with
  | Unix.WEXITED 0 -> grep_result_of_z_output ~max_matches stdout
  | Unix.WEXITED 1 when String.equal (String.trim stderr) "" ->
      (* git grep exits 1 when nothing matched; that is an answer. *)
      Stdlib.Ok { gr_matches = []; gr_truncated = false }
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
      Stdlib.Error (git_failure_detail args status stdout stderr)

(* A tracked, non-ignored file is in both runs with the same rows; one copy of
   each path and line is kept. *)
let join_grep_results ~max_matches (tracked : grep_result) (untracked : grep_result) =
  let by_path_and_line left right =
    match String.compare left.gm_path right.gm_path with
    | 0 -> Int.compare left.gm_line right.gm_line
    | order -> order
  in
  let joined = List.sort_uniq by_path_and_line (tracked.gr_matches @ untracked.gr_matches) in
  { gr_matches = List.filteri (fun index _ -> index < max_matches) joined
  ; gr_truncated =
      tracked.gr_truncated || untracked.gr_truncated || List.length joined > max_matches
  }

let grep_at
    ?(timeout_sec = inspection_timeout_sec)
    ~local_path
    ~pathspec
    ~pattern
    ~ignore_case
    ~max_matches
    ()
  =
  if String.equal pattern "" then Stdlib.Error "git grep needs a non-empty pattern"
  else
    let search = grep_in_scope ~timeout_sec ~local_path ~pathspec ~pattern ~ignore_case ~max_matches in
    match search Tracked with
    | Stdlib.Error _ as failure -> failure
    | Stdlib.Ok tracked ->
        (match search Untracked_not_ignored with
         | Stdlib.Error _ as failure -> failure
         | Stdlib.Ok untracked -> Stdlib.Ok (join_grep_results ~max_matches tracked untracked))
