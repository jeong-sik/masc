(* Keeper_workspace_read_ops — structured read-side Grep operations. *)

val try_handle_with_authority :
  read_authority:Keeper_sandbox_remote_lane.read_authority option ->
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t -> op:string -> raw_path:string -> Keeper_tool_execution.t option

val try_handle_with_outcome :
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  op:string ->
  raw_path:string ->
  Keeper_tool_execution.t option

(** The program and arguments Grep runs inside the backend to learn whether
    anything can be found at [path]: one [sh] script, [ -e ], with the path as
    a positional argument. It exits 0 when something is there and
    {!path_missing_exit} when nothing can be found; any other status is a probe
    that did not run and proves nothing. A failed rg search is called a missing
    path by that code, never by rg's stderr. *)
val path_probe_argv : string -> string list

val path_missing_exit : int

(** The program and arguments Grep runs inside the backend to learn whether its
    rg can compile [pattern]: [rg -e pattern /dev/null]. It searches nothing, so
    it exits 1 when the pattern is accepted and {!pattern_invalid_exit} when it
    is not; any other status is a probe that did not run and proves nothing. A
    failed rg search is called a bad pattern by that code, never by rg's
    stderr. *)
val pattern_probe_argv : string -> string list

val pattern_invalid_exit : int
