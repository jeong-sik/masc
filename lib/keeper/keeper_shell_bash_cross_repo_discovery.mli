(** P0-X: Typed redirect predicates for keeper repo-wide discovery shells.

    See [.ml] for design notes. Each predicate is pure: given a raw
    shell command, decide whether it matches one of three known
    [keeper_tool_policy_blocked] signatures that should be redirected
    to a typed MCP tool. *)

(** [find repos ... -name .worktrees]-shaped command. *)
val command_looks_like_worktree_discovery : string -> bool

(** [rg/grep ... repos/]-shaped command (cross-repo content scan). *)
val command_looks_like_cross_repo_grep : string -> bool

(** [find /home/... ...] or [find /Users/... ...]-shaped command
    (absolute host-path probe outside the keeper sandbox). *)
val command_looks_like_cross_host_probe : string -> bool

(** Disjunction of the three predicates. *)
val command_looks_like_repo_wide_discovery : string -> bool

(** Typed hint string (one paragraph) shown to the keeper when any of
    the three signatures matches. *)
val repo_wide_discovery_shell_hint : string

(** Tag for the matched sub-pattern of a discovery shell. *)
type discovery_sub_pattern =
  | Worktree_discovery
  | Cross_repo_grep
  | Cross_host_probe

(** Static [(sub_pattern, tool_name, args)] table consumed by the
    [Keeper_shell_bash_shape_messages] / [Keeper_shell_bash] dispatchers
    to render a structured rewrite plan. The third element is a flat
    [(key, placeholder)] list so the caller can choose how to wrap it
    (e.g. as [`Assoc] for Yojson, or as the [next_args] field on the
    existing [recovery_plan] record). *)
val repo_wide_discovery_alternatives :
  (discovery_sub_pattern * string * (string * string) list) list

(** Classify [cmd]. Returns [None] when no signature matches. The order
    is most-specific first: [Worktree_discovery] -> [Cross_repo_grep]
    -> [Cross_host_probe]. *)
val classify_repo_wide_discovery : string -> discovery_sub_pattern option
