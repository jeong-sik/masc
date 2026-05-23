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

val stages_targets_git_or_gh :
  Keeper_shell_command_semantics.parsed_stage list -> bool
(** [true] when any effective stage's executable is [git] or [gh].
    Callers pre-parse with [Shell_command_gate.parse_to_ir_opt]
    and pass [effective_stages_of_ir]. Exposed for unit testing. *)

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

(** [ensure_keeper_sandbox_runtime ~timeout_sec] preflights the host
    Docker runtime against the configured hardening requirements
    (seccomp profile present, optional rootless / userns checks).
    Returns the [--security-opt seccomp=...] argv fragment when the
    runtime passes; [Error _] when something is missing. Exposed for
    [Keeper_docker_read] (RFC-0006 Phase B-2) which reuses the same
    preflight before spawning a one-shot container for fs reads. *)
val ensure_keeper_sandbox_runtime :
  timeout_sec:float -> (string list, string) result
