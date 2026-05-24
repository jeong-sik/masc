(** Compatibility bridge for [keeper_shell op=gh].

    The public tool surface stays [keeper_shell], but GitHub command
    parsing, policy checks, repo-context binding, and backend-neutral
    command dispatch live here instead of in [Keeper_shell_ops]. *)

type run_command_with_status =
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  timeout_sec:float ->
  host:Keeper_sandbox_runner.host_command ->
  backend:Keeper_sandbox_runner.backend_command ->
  Keeper_sandbox_runner.routed_result

val handle_gh_op :
  ?run_command_with_status:run_command_with_status ->
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  repo_check:(string -> (unit, string) result) ->
  unit ->
  string
