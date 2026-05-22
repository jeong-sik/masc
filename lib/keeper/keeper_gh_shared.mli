(** Shared GH primitives used by PR workflow handlers and keeper_shell op=gh.

    Contains the gh argv parser (simple-command shape) and repo-slug
    utilities. Extracted from keeper_exec_github.ml to break up the god
    file; consumers now import this module rather than each other. *)

(* ---- gh command parsers --------------------------------------- *)

type gh_command_parse_error =
  | Empty_command
  | Unsupported_shell_construct of string
  | Unsupported_command_shape of string

type gh_simple_command

(** Parse a single gh command shape into canonical argv (without the
    leading [gh] binary). Accepts both ["pr list"] and ["gh pr list"]
    input forms, but rejects pipelines, redirects, env prefixes, and
    other shell constructs outside the simple-command subset. *)
val parse_simple_gh_command :
  string -> (gh_simple_command, gh_command_parse_error) result

(** Build a simple gh command from already-tokenized argv. Accepts both
    [["pr"; "list"]] and [["gh"; "pr"; "list"]] forms, preserving each
    argument as a literal argv atom. *)
val gh_simple_command_of_argv :
  string list -> (gh_simple_command, gh_command_parse_error) result

val gh_simple_command_argv : gh_simple_command -> string list

val render_simple_gh_command : gh_simple_command -> string

val gh_simple_command_has_repo_flag : gh_simple_command -> bool

val gh_simple_command_with_repo_flag :
  repo_slug:string ->
  gh_simple_command ->
  gh_simple_command

(* ---- Repo slug + flag utilities ------------------------------- *)

val has_repo_flag : string -> bool

val is_valid_repo_segment : string -> bool

val validate_repo_slug : string -> (string, string) result

val strip_repo_flags_from_args : string list -> string list

val args_have_repo_flag : string list -> bool

val inject_repo_flag_args : repo_slug:string -> string list -> string list

val repo_slug_of_remote_url : string -> string option

val repo_slug_of_git_config : git_root:string -> string option

val repo_slug_of_task_worktree :
  git_root:string -> worktree_cwd:string -> string option

val repo_slug_of_git_root : git_root:string -> string option
