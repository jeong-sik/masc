(** Keeper shell tool handlers — bash execution and structured shell ops.

    Handles [keeper_bash] (arbitrary commands with blocklist) and
    [keeper_shell] (structured ops: ls, cat, find, rg, head, tail, wc, tree,
    git-log, git-diff, git-status, git-clone, git-worktree, bash).

    Both tools default to the keeper playground unless an explicit
    allowed [cwd] is provided. *)

(** Issue #8524: Variant SSOT for keeper_shell op.  Mirror in
    [Tool_shard.keeper_shell_op_enum_strings] (cycle-aware, sync test
    catches drift). Schema previously omitted git_worktree. *)
type shell_op =
  | Pwd | Ls | Cat | Rg | Git_status | Find | Head | Tail | Wc | Tree
  | Git_log | Git_diff | Git_worktree | Bash | Git_clone | Gh

val shell_op_to_string : shell_op -> string
val all_shell_ops : shell_op list
val valid_shell_op_strings : string list

val gh_min_timeout_sec : float
(** Minimum timeout_sec floor applied to gh op. Exposed so regression
    tests can lock the floor against drift back to sub-network-latency
    values. See #8688. *)

val handle_keeper_bash :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  string

val handle_keeper_shell :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  string
