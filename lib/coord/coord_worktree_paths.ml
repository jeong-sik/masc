(** Coord Worktree - Path / filesystem-shape helpers.

    Pure path helpers and read-only shape checks used by the policy,
    discovery, sandbox-clone, and lifecycle layers.  No mutation, no
    process execution apart from a single [git rev-parse] in
    [is_usable_git_worktree] which is logically a read of the working
    tree state.

    Extracted from [coord_worktree.ml] (Stage 06, godfile decomposition
    plan 2026-05-18). *)

open Masc_domain
open Coord_utils

(** Check if directory is a git repository - delegates to Coord_git *)
let is_git_repo config =
  Coord_git.is_git_repo ~base_path:config.base_path

let git_marker_kind path =
  match (try Some (Sys.is_directory path) with Sys_error _ -> None) with
  | Some true -> `Directory
  | Some false -> `File
  | None -> `Missing

(** Resolve the project root from config.base_path.
    If base_path ends with ".masc", use its parent; otherwise use base_path.
    Then walk parent directories until we find the owning repository root
    (.git directory). This keeps config.base_path as the anchor while still
    handling nested subdirectories and worktree roots (.git file).
    Inlined from Keeper_alerting_path to avoid room→keeper dependency. *)
let project_root config =
  let base = config.base_path in
  let candidate =
    if Filename.basename base = Common.masc_dirname then Filename.dirname base else base
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
      (System (System_error.IoError
         (Printf.sprintf
            "Worktree isolation requires repository root with .git: %s (current base path: %s)"
            root config.base_path)))

let ensure_worktree_path root worktree_name =
  let worktrees_dir = Filename.concat root ".worktrees" in
  let worktree_path = Filename.concat worktrees_dir worktree_name in
  if Filename.dirname worktree_path = worktrees_dir then
    Ok (worktree_path, worktrees_dir)
  else
    Error (System (System_error.IoError "Invalid worktree path: must be created under .worktrees/"))

let safe_file_exists path =
  try Sys.file_exists path with
  | Sys_error _ -> false

let safe_is_dir path =
  try (Unix.stat path).st_kind = Unix.S_DIR with
  | Unix.Unix_error _ | Sys_error _ -> false

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

(* Git worktree mutations include Eio subprocess calls; use Eio.Mutex so
   same-domain fibers serialize without blocking the scheduler. *)
let worktree_mutation_mutex = Eio.Mutex.create ()

let with_worktree_mutation_lock f =
  Eio.Mutex.use_rw ~protect:true worktree_mutation_mutex f

let is_git_clone candidate =
  safe_is_dir candidate
  &&
  match git_marker_kind (Filename.concat candidate ".git") with
  | `Directory | `File -> true
  | `Missing -> false

let has_git_marker root =
  match git_marker_kind (Filename.concat root ".git") with
  | `Directory | `File -> true
  | `Missing -> false

let same_realpath a b =
  try String.equal (Unix.realpath a) (Unix.realpath b) with
  | Unix.Unix_error _ -> String.equal a b

let is_usable_git_worktree path =
  safe_is_dir path
  &&
  match Coord_worktree_exec.run_argv_with_status
          [ "git"; "-C"; path; "rev-parse"; "--show-toplevel" ]
  with
  | Unix.WEXITED 0, output -> (
      match Coord_worktree_exec.first_nonempty_line output with
      | Some top -> same_realpath top path
      | None -> false)
  | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _ -> false

let current_worktree_branch path =
  match
    Coord_worktree_exec.run_argv_with_status
      [ "git"; "-C"; path; "rev-parse"; "--abbrev-ref"; "HEAD" ]
  with
  | Unix.WEXITED 0, output -> Coord_worktree_exec.first_nonempty_line output
  | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _ -> None

let run_git_in_clone clone_path args =
  Coord_worktree_exec.run_argv_with_status
    ([ "git"; "-C"; clone_path; "--no-optional-locks" ] @ args)

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

let repos_dir_of_keeper config agent_name =
  let repos_rel =
    Filename.concat
      (Keeper_sandbox_config.host_root_rel_of_agent
         ~base_path:config.base_path
         ~agent_name)
      "repos"
  in
  Filename.concat config.base_path repos_rel

let strip_trailing_slashes path =
  let rec loop i =
    if i > 0 && path.[i - 1] = '/' then loop (i - 1) else i
  in
  let len = loop (String.length path) in
  if len = String.length path then path else String.sub path 0 len

let keeper_visible_worktree_path ~config ~agent_name ~host_path =
  Keeper_sandbox_config.visible_path_of_host_path
    ~base_path:config.base_path
    ~agent_name
    ~host_path

let worktree_next_step keeper_path =
  Printf.sprintf
    "Next: Bash cwd=%S command=\"git status -sb\"; after edits, git \
     add/commit/push. Use keeper_shell op=gh for GitHub PR work."
    keeper_path
