(** Tool execution handlers — command execution and ripgrep search.

    Handles [Execute] (arbitrary commands with blocklist) and
    [Grep] / [tool_search_files] (ripgrep pattern search).

    Both tools default to the keeper playground unless an explicit
    allowed [cwd] is provided. *)

val readonly_hint_of_category : string -> string
(** Return the Good:/Bad: rewrite hint shown in
    [command_blocked_readonly] errors. Exposed so unit tests can assert
    that each category carries a concrete example, not just a label. *)

val diagnosis_of_block_reason :
  Exec_policy.block_reason -> Exec_core.diagnosis option
(** Machine-parseable recovery diagnosis for a readonly/workflow block
    reason. Kept on the facade because the shell executor is the public
    entry point used by tests and callers; implementation lives in
    [Keeper_tool_execute_readonly_policy]. *)

val rewrite_turn_runtime_paths_to_host :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  string ->
  string
(** Rewrites occurrences of the keeper sandbox container root back to the
    corresponding host playground root in path-bearing output. Used by
    turn-scoped sandbox responses that must preserve host-path contracts
    for follow-up tool calls. *)

val rewrite_docker_host_paths_to_container :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  string ->
  string
(** Rewrites host playground root occurrences in keeper-issued Docker
    commands to the corresponding in-container playground root before
    execution. *)

val handle_tool_execute :
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  exec_cache:Masc_exec.Exec_cache.t option ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  unit ->
  string

module For_testing : sig
  val elapsed_duration_ms : start_time:float -> end_time:float -> int
end

val handle_tool_search_files :
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  exec_cache:Masc_exec.Exec_cache.t option ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  string
