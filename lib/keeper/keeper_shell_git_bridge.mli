(** Compatibility bridge for [keeper_shell op=git_clone].

    Git clone/pull semantics remain available through the public
    [keeper_shell] surface, but the Git-specific policy, path shaping,
    playground cache update, and backend-neutral runner dispatch live
    here instead of in [Keeper_shell_ops]. *)

type run_command_with_status =
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  timeout_sec:float ->
  host:Keeper_sandbox_runner.host_command ->
  backend:Keeper_sandbox_runner.backend_command ->
  Keeper_sandbox_runner.routed_result

val handle_git_clone :
  ?run_command_with_status:run_command_with_status ->
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  unit ->
  string
