(** Keeper shell tool handlers — command execution and structured shell ops.

    Handles [keeper_shell_ir] (arbitrary commands with blocklist) and
    [keeper_shell] (structured ops: ls, cat, find, rg, head, tail, wc, tree,
    git-log, git-diff, git-status, git-clone, git-worktree, gh).

    Both tools default to the keeper playground unless an explicit
    allowed [cwd] is provided. *)

(** Issue #8524: Variant SSOT for keeper_shell op.  Mirror in
    [Tool_shard.keeper_shell_op_enum_strings] (cycle-aware, sync test
    catches drift). Schema previously omitted git_worktree. *)
type shell_op =
  | Pwd | Ls | Cat | Rg | Git_status | Find | Head | Tail | Wc | Tree
  | Git_log | Git_diff | Git_worktree | Git_clone | Gh

val shell_op_to_string : shell_op -> string
val all_shell_ops : shell_op list
val valid_shell_op_strings : string list

val readonly_hint_of_category : string -> string
(** Return the Good:/Bad: rewrite hint shown in
    [command_blocked_readonly] errors. Exposed so unit tests can assert
    that each category carries a concrete example, not just a label. *)

val diagnosis_of_block_reason :
  Exec_policy.block_reason -> Exec_core.diagnosis option
(** Machine-parseable recovery diagnosis for a readonly/workflow block
    reason. Kept on the facade because the shell executor is the public
    entry point used by tests and callers; implementation lives in
    [Keeper_shell_shared]. *)

val gh_min_timeout_sec : float
(** Minimum timeout_sec floor applied to gh op. Exposed so regression
    tests can lock the floor against drift back to sub-network-latency
    values. See #8688. *)

val keeper_shell_ir_native_min_timeout_sec : float
(** Minimum timeout_sec floor applied to keeper_shell_ir on the *native*
    executor path. Exposed so regression tests can lock the floor
    against drift back to sub-I/O-latency values.  Container-backed
    dispatch paths re-clamp independently inside their backend. *)

val rewrite_turn_runtime_paths_to_host :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  string ->
  string
(** Rewrites occurrences of the keeper sandbox container root back to the
    corresponding host playground root in path-bearing output. Used by
    turn-scoped sandbox responses that must preserve host-path contracts
    for follow-up tool calls. *)

val rewrite_docker_host_paths_to_container :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  string ->
  string
(** Rewrites host playground root occurrences in keeper-issued Docker
    commands to the corresponding in-container playground root before
    execution. *)

val handle_keeper_shell_ir :
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  turn_sandbox_factory_git:Keeper_sandbox_factory.t option ->
  exec_cache:Masc_exec.Exec_cache.t option ->
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  unit ->
  string

module For_testing : sig
  val elapsed_duration_ms : start_time:float -> end_time:float -> int
end

val handle_keeper_shell :
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  exec_cache:Masc_exec.Exec_cache.t option ->
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  string
