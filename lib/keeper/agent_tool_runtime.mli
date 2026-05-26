(** Runtime dispatch for descriptor-backed agent tools.

    [Keeper_exec_tools] owns cross-cutting execution bookkeeping. This module
    owns the descriptor-selected lowerer/handler route for first-class agent
    tools such as [Execute], [ReadFile], and [SearchFiles]. *)

type context =
  { config : Coord.config
  ; meta : Keeper_types.keeper_meta
  ; turn_sandbox_factory : Keeper_sandbox_factory.t option
  ; turn_sandbox_factory_git : Keeper_sandbox_factory.t option
  ; exec_cache : Masc_exec.Exec_cache.t option
  }

val descriptor_for_internal : string -> Agent_tool_descriptor.t option

val handle :
  context -> descriptor:Agent_tool_descriptor.t -> args:Yojson.Safe.t -> string option

val handle_internal : context -> name:string -> args:Yojson.Safe.t -> string option
