(** Keeper shell tool handlers — command execution and structured shell ops.

    Handles [keeper_bash] (arbitrary commands with blocklist) and
    [keeper_shell] (structured ops: ls, cat, find, rg, head, tail, wc, tree,
    git-log, git-diff, git-status, git-clone, git-worktree, gh).

    Both tools default to the keeper playground unless an explicit
    allowed [cwd] is provided. *)

val gh_min_timeout_sec : float
(** Minimum timeout_sec floor applied to gh op. Exposed so regression
    tests can lock the floor against drift back to sub-network-latency
    values. See #8688. *)

val keeper_bash_native_min_timeout_sec : float
(** Minimum timeout_sec floor applied to keeper_bash on the *native*
    (non-Docker) executor path. Exposed so regression tests can lock the
    floor against drift back to sub-I/O-latency values.  The Docker
    dispatch path re-clamps independently to
    {!Keeper_shell_docker.docker_run_min_timeout_sec}. *)

val handle_keeper_bash :
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

