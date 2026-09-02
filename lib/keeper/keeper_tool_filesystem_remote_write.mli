(** Write and Edit for a tree the endpoint owns ([Endpoint_owned]): the bytes
    travel through [masc-exec-shim] over the remote lane instead of a host
    filesystem capability. Same path jail, modes, patch and evidence as the
    host handler; no Gate (the jail admits only the keeper's playground) and
    no publication-recovery journal (the replace is [mktemp] + [mv] on the
    endpoint). *)

val handle :
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  Keeper_tool_execution.t
(** Resolve the keeper's endpoint through {!Keeper_sandbox_remote_lane} and
    run {!handle_with_endpoint}. An unreachable endpoint is a
    [Dependency_unavailable] failure. *)

val handle_with_endpoint :
  endpoint:Keeper_sandbox_remote.t ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  Keeper_tool_execution.t

type content_mode =
  | Replace_whole
  | Append_tail

val write_argv : mode:content_mode -> remote_path:string -> string list
(** The [sh -c] payload that writes stdin to [remote_path]: an atomic
    replace beside the target, or an append. *)

val read_source_argv : remote_path:string -> string list
(** The payload that prints a regular file, or exits
    {!patch_source_missing_exit} when there is none to patch. *)

val patch_source_missing_exit : int
