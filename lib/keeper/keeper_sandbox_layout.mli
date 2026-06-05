(** Keeper_sandbox_layout — Sandbox directory layout SSOT.

    All sandbox-relative path conventions are defined here. No other module
    should contain literal ["repos"] or ["mind"] directory names.

    RFC-0218: Single source of truth for sandbox layout knowledge. *)

val repos_subdir : string
(** Directory name for cloned repositories inside a sandbox. *)

val mind_subdir : string
(** Directory name for the keeper mind/state directory inside a sandbox. *)

val repos_dir : sandbox_root:string -> string
(** Absolute path to the repos directory. *)

val mind_dir : sandbox_root:string -> string
(** Absolute path to the mind directory. *)

val repo_display_path : string -> string
(** Sandbox-relative display path for a repository (e.g., ["repos/masc-mcp"]).
    Suitable for LLM-facing messages and tool cwd hints. *)

val repo_physical_path : sandbox_root:string -> string -> string
(** Absolute filesystem path to a cloned repository. *)

val allowed_roots : sandbox_root:string -> string list
(** Valid top-level entry points for path resolution. *)

val path_segments : string -> string list
(** Split a path into non-empty segments. *)

val parse_repo_segment : string list -> (string * string list) option
(** Extract repo name from path segments starting with [repos_subdir]. *)
