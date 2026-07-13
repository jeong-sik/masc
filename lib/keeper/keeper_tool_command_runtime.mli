(** Tool execution handlers — typed command execution and ripgrep search.

    Handles [Execute] (typed Shell IR behind the exact external-effect Gate) and
    [Grep] / [tool_search_files] (ripgrep pattern search).

    Both tools default to the keeper playground unless an explicit
    allowed [cwd] is provided. *)

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
  ?continuation_channel:Keeper_continuation_channel.t ->
  ?gate_context:(unit -> Keeper_gate.causal_context) ->
  ?gate_grant:Keeper_gate.cycle_grant ->
  args:Yojson.Safe.t ->
  unit ->
  string

val handle_tool_execute_with_outcome :
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  exec_cache:Masc_exec.Exec_cache.t option ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  ?continuation_channel:Keeper_continuation_channel.t ->
  ?gate_context:(unit -> Keeper_gate.causal_context) ->
  ?gate_grant:Keeper_gate.cycle_grant ->
  args:Yojson.Safe.t ->
  unit ->
  Keeper_tool_execution.t

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

val handle_tool_search_files_with_outcome :
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  exec_cache:Masc_exec.Exec_cache.t option ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  Keeper_tool_execution.t
