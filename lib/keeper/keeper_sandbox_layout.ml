(** Keeper_sandbox_layout — Sandbox directory layout SSOT.

    All sandbox-relative path conventions are defined here. No other module
    should contain literal ["repos"] or ["mind"] directory names.

    RFC-0218: This module is the single source of truth for sandbox layout
    knowledge. Keeper runtime, tool dispatch, and repo mapping modules
    reference these constants instead of hardcoding directory names. *)

let repos_subdir = "repos"
let mind_subdir = "mind"

(** [repos_dir ~sandbox_root] returns the absolute path to the repos
    directory inside a sandbox root. *)
let repos_dir ~sandbox_root =
  Filename.concat sandbox_root repos_subdir

(** [mind_dir ~sandbox_root] returns the absolute path to the mind
    directory inside a sandbox root. *)
let mind_dir ~sandbox_root =
  Filename.concat sandbox_root mind_subdir

(** [repo_display_path repo_id] returns the sandbox-relative display path
    for a repository, suitable for LLM-facing messages and tool cwd hints.
    Example: [repo_display_path "masc-mcp" = "repos/masc-mcp"] *)
let repo_display_path repo_id =
  Filename.concat repos_subdir repo_id

(** [repo_physical_path ~sandbox_root repo_id] returns the absolute
    filesystem path to a cloned repository inside a sandbox.
    Example: [repo_physical_path ~sandbox_root:"/x" "masc-mcp"
              = "/x/repos/masc-mcp"] *)
let repo_physical_path ~sandbox_root repo_id =
  Filename.concat (repos_dir ~sandbox_root) repo_id

(** [allowed_roots ~sandbox_root] returns the list of sandbox-relative
    paths that are valid top-level entry points for path resolution. *)
let allowed_roots ~sandbox_root =
  [ sandbox_root ^ "/"
  ; mind_dir ~sandbox_root ^ "/"
  ; repos_dir ~sandbox_root ^ "/"
  ]

(** [path_segments path] splits a path into non-empty segments. *)
let path_segments path =
  String.split_on_char '/' path
  |> List.filter (fun s -> not (String.equal s ""))

(** [parse_repo_segment segments] extracts the repo name from the
    beginning of a path segment list that starts with [repos_subdir].
    Returns [Some (repo_name, remaining_segments)] or [None]. *)
let parse_repo_segment = function
  | hd :: repo_name :: rest when String.equal hd repos_subdir && repo_name <> "" ->
    Some (repo_name, rest)
  | _ -> None
