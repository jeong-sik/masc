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
  | Pwd
  | Ls
  | Cat
  | Rg
  | Git_status
  | Find
  | Head
  | Tail
  | Wc
  | Tree
  | Git_log
  | Git_diff
  | Git_worktree
  | Bash
  | Git_clone
  | Gh

val shell_op_to_string : shell_op -> string
val all_shell_ops : shell_op list
val valid_shell_op_strings : string list

(** Return the Good:/Bad: rewrite hint shown in
    [command_blocked_readonly] errors. Exposed so unit tests can assert
    that each category carries a concrete example, not just a label. *)
val readonly_hint_of_category : string -> string

(** Minimum timeout_sec floor applied to gh op. Exposed so regression
    tests can lock the floor against drift back to sub-network-latency
    values. See #8688. *)
val gh_min_timeout_sec : float

(** Rewrites occurrences of the keeper sandbox container root back to the
    corresponding host playground root in path-bearing output. Used by
    turn-scoped sandbox responses that must preserve host-path contracts
    for follow-up tool calls. *)
val rewrite_turn_runtime_paths_to_host
  :  config:Coord.config
  -> meta:Keeper_types.keeper_meta
  -> string
  -> string

(** Docker git-credentials per-command dispatch predicate. True when
    the trimmed command's first whitespace-separated word is exactly
    "git" or "gh". Under sandbox_profile=docker this upgrades the
    container to network=inherit with gh/git credential mounts for
    the duration of that one command unless
    [MASC_KEEPER_SANDBOX_HARD_MODE=true], where dispatch is disabled and
    structured git/gh tools use brokered host execution instead. Exposed
    for unit testing. *)
val cmd_targets_git_or_gh : string -> bool

val handle_keeper_bash
  :  turn_sandbox_runtime:Keeper_turn_sandbox_runtime.t option
  -> turn_sandbox_runtime_git:Keeper_turn_sandbox_runtime.t option
  -> exec_cache:Masc_exec.Exec_cache.t option
  -> config:Coord.config
  -> meta:Keeper_types.keeper_meta
  -> args:Yojson.Safe.t
  -> unit
  -> string

(** Legendary Bash P2: poll pending stdout/stderr from a background
    task spawned via [keeper_bash] with [run_in_background=true]. *)
val handle_keeper_bash_output
  :  config:Coord.config
  -> meta:Keeper_types.keeper_meta
  -> args:Yojson.Safe.t
  -> string

(** Legendary Bash P2: terminate a background task's process group
    (SIGTERM → grace → SIGKILL). Idempotent. *)
val handle_keeper_bash_kill
  :  config:Coord.config
  -> meta:Keeper_types.keeper_meta
  -> args:Yojson.Safe.t
  -> string

val handle_keeper_shell
  :  turn_sandbox_runtime:Keeper_turn_sandbox_runtime.t option
  -> exec_cache:Masc_exec.Exec_cache.t option
  -> config:Coord.config
  -> meta:Keeper_types.keeper_meta
  -> args:Yojson.Safe.t
  -> string

(** [ensure_keeper_sandbox_runtime ~timeout_sec] preflights the host
    Docker runtime against the configured hardening requirements
    (seccomp profile present, optional rootless / userns checks).
    Returns the [--security-opt seccomp=...] argv fragment when the
    runtime passes; [Error _] when something is missing. Exposed for
    [Keeper_docker_read] (RFC-0006 Phase B-2) which reuses the same
    preflight before spawning a one-shot container for fs reads. *)
val ensure_keeper_sandbox_runtime : timeout_sec:float -> (string list, string) result
