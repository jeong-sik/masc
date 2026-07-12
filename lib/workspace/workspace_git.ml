(** Bounded git metadata helpers.

    Implementation is argv-based (no shell) to avoid injection and quoting bugs.
*)

open Masc_domain

let exec_gate_raw_source argv =
  String.concat " " (List.map Filename.quote argv)

(* ============================================ *)
(* argv-based process helpers                   *)
(* ============================================ *)

(** Run argv and return first non-empty line. *)
let run_argv_line (argv : string list) : string option =
  let output =
    Masc_exec.Exec_gate.run_argv
      ~actor:(Masc_exec.Agent_id.of_string "workspace/git")
      ~raw_source:(exec_gate_raw_source argv)
      ~summary:"workspace_git argv"
      ~timeout_sec:Env_config_runtime.Workspace_git.local_op_timeout_sec
      argv
  in
  match String.split_on_char '\n' output |> List.map String.trim |> List.filter (fun s -> s <> "") with
      | [] -> None
      | h :: _ -> Some h

(** Run argv and return exit code.
    [timeout_sec] defaults to {!Env_config_runtime.Workspace_git.local_op_timeout_sec}
    for local-only operations.  Network-bound commands (git fetch /
    push) should pass an explicit longer budget — see
    {!Env_config_core.git_fetch_timeout_sec}. *)
let run_argv_exit
    ?(timeout_sec = Env_config_runtime.Workspace_git.local_op_timeout_sec)
    (argv : string list) : int =
  match
    Masc_exec.Exec_gate.run_argv_with_status
      ~actor:(Masc_exec.Agent_id.of_string "workspace/git")
      ~raw_source:(exec_gate_raw_source argv)
      ~summary:"workspace_git argv"
      ~timeout_sec
      argv
  with
  | Unix.WEXITED n, _ -> n
  | Unix.WSIGNALED _, _ -> 128
  | Unix.WSTOPPED _, _ -> 128

let git_first_line ~repo_path args =
  run_argv_line ("git" :: "-C" :: repo_path :: args)

(* ============================================ *)
(* Input Validation                             *)
(* ============================================ *)

(** Validate branch/path components — alphanumeric + /_-. only *)
let is_valid_branch_name s =
  String.length s > 0
  && String.length s < 256
  && s |> String.to_seq |> Seq.for_all (fun c ->
       (c >= 'a' && c <= 'z')
       || (c >= 'A' && c <= 'Z')
       || (c >= '0' && c <= '9')
       || c = '/'
       || c = '_'
       || c = '-'
       || c = '.')

(* ============================================ *)
(* Git Repository Utilities                     *)
(* ============================================ *)

(** Fast check for .git marker by walking parent directories.
    Avoids spawning a subprocess when clearly not in a git repo. *)
let has_git_marker path =
  let rec walk dir =
    let marker = Filename.concat dir ".git" in
    if Sys.file_exists marker then true
    else
      let parent = Filename.dirname dir in
      if String.equal parent dir then false else walk parent
  in
  try walk path with Sys_error _ -> false

(** Like {!has_git_marker} but also searches immediate child directories
    (e.g. [repos/]) for a [".git"] marker.  Needed when [base_path] is a
    sandbox root that contains git repos in sub-directories. *)
let has_git_marker_deep path =
  if has_git_marker path then true
  else
    let child_marker dir =
      let candidate = Filename.concat dir ".git" in
      Sys.file_exists candidate
    in
    let search_children () =
      let entries =
        try Sys.readdir path |> Array.to_list with Sys_error _ -> []
      in
      List.exists
        (fun entry ->
           let child = Filename.concat path entry in
           Sys.is_directory child && child_marker child)
        entries
    in
    search_children ()

(** Get git root directory.
    Falls back to scanning child directories when the base path itself
    is not a git repo — handles sandbox environments where repos live
    under a playground root. *)
let git_root ~base_path =
  if has_git_marker base_path then
    git_first_line ~repo_path:base_path [ "rev-parse"; "--show-toplevel" ]
  else if has_git_marker_deep base_path then
    (* One of the immediate children has .git — try each and use the first
       one that resolves via rev-parse. *)
    let entries =
      try Sys.readdir base_path |> Array.to_list with Sys_error _ -> []
    in
    let rec try_children = function
      | [] -> None
      | entry :: rest ->
        let child = Filename.concat base_path entry in
        if Sys.is_directory child && Sys.file_exists (Filename.concat child ".git")
        then
          match git_first_line ~repo_path:child [ "rev-parse"; "--show-toplevel" ] with
          | Some _ as ok -> ok
          | None -> try_children rest
        else try_children rest
    in
    try_children entries
  else
    None

(** Check if directory is a git repository *)
let is_git_repo ~base_path =
  has_git_marker base_path
  && match git_root ~base_path with
     | Some _ -> true
     | None -> false

let remote_branch_exists root branch =
  if not (is_valid_branch_name branch) then false
  else
    run_argv_exit
      [
        "git";
        "-C";
        root;
        "show-ref";
        "--verify";
        "--quiet";
        Printf.sprintf "refs/remotes/origin/%s" branch;
      ]
    = 0

let commit_exists ~root ~commit =
  run_argv_exit
    [ "git"; "-C"; root; "cat-file"; "-e"; commit ^ "^{commit}" ]
  = 0

let origin_head_branch root =
  let line = run_argv_line ["git"; "-C"; root; "symbolic-ref"; "-q"; "refs/remotes/origin/HEAD"] in
  match line with
  | None -> None
  | Some refname -> (
      match List.rev (String.split_on_char '/' refname) with
      | branch :: _ -> Some branch
      | [] -> None)

let unique_strings values =
  List.fold_left
    (fun acc value ->
      let value = String.trim value in
      if value = "" || List.mem value acc then acc else acc @ [ value ])
    [] values

let auto_base_branch_candidates root =
  unique_strings
    (match origin_head_branch root with
     | Some head -> [ head; "main"; "master"; "develop" ]
     | None -> [ "main"; "master"; "develop" ])

let resolve_base_branch root base_branch =
  let base_branch = String.trim base_branch in
  if base_branch = "" || String.equal base_branch "auto" then
    match List.find_opt (remote_branch_exists root) (auto_base_branch_candidates root) with
    | Some resolved -> Ok (resolved, None)
    | None ->
        Error
          (System (System_error.IoError
             "Base branch auto-detect failed: no origin/HEAD, origin/main, origin/master, or origin/develop found."))
  else if remote_branch_exists root base_branch then Ok (base_branch, None)
  else
    match List.find_opt (remote_branch_exists root) (auto_base_branch_candidates root) with
    | Some fallback -> Ok (fallback, Some base_branch)
    | None ->
        Error
          (System (System_error.IoError
             (Printf.sprintf
                "Base branch origin/%s not found and no origin/HEAD, origin/main, origin/master, or origin/develop fallback detected."
                base_branch)))
