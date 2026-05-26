(** In-process runtime handlers for descriptor-backed coordination tools.

    RFC-0179. Hosts handlers for descriptors whose executor is [In_process] —
    pure OCaml-runtime functions with no sandbox, no host process spawn, no
    remote MCP. Each handler returns the raw output JSON string; the caller
    in [Agent_tool_runtime.handle_in_process] wraps it via
    [Keeper_exec_tools.make_executed_tool_result].

    Output parity: each handler reproduces the exact JSON the legacy match
    arm in [Keeper_exec_tools.execute_keeper_tool_call_with_outcome] used to
    produce, so [classify_tool_result_payload] infers the same outcome. *)

open Keeper_types

val handle_time_now : args:Yojson.Safe.t -> string

val handle_stay_silent : args:Yojson.Safe.t -> string

val handle_tools_list : meta:keeper_meta -> args:Yojson.Safe.t -> string

val handle_tool_search
  :  search_fn:(query:string -> max_results:int -> Yojson.Safe.t)
  -> args:Yojson.Safe.t
  -> string

val handle_context_status
  :  config:Coord.config
  -> meta:keeper_meta
  -> ctx_work:working_context
  -> args:Yojson.Safe.t
  -> string

val handle_memory_search
  :  config:Coord.config
  -> meta:keeper_meta
  -> ctx_work:working_context
  -> args:Yojson.Safe.t
  -> string

val handle_memory_write
  :  config:Coord.config
  -> meta:keeper_meta
  -> args:Yojson.Safe.t
  -> string

val handle_library_search : meta:keeper_meta -> args:Yojson.Safe.t -> string
val handle_library_read : meta:keeper_meta -> args:Yojson.Safe.t -> string

val handle_ide_annotate
  :  config:Coord.config
  -> meta:keeper_meta
  -> args:Yojson.Safe.t
  -> string

(** [handle_voice] dispatches to [Agent_tool_voice_runtime.handle_voice_tool]
    by [name]. Caller must pass a name in the voice cluster. *)
val handle_voice
  :  meta:keeper_meta
  -> name:string
  -> args:Yojson.Safe.t
  -> string

(** [handle_task] dispatches to [Keeper_exec_task.handle_keeper_task_tool]
    by [name]. Caller must pass a name in the task / broadcast cluster. *)
val handle_task
  :  config:Coord.config
  -> meta:keeper_meta
  -> name:string
  -> args:Yojson.Safe.t
  -> string

(** [handle_board] dispatches to
    [Agent_tool_board_runtime.handle_keeper_board_tool] by [name]. Caller
    must pass a name in the board cluster. *)
val handle_board
  :  meta:keeper_meta
  -> name:string
  -> args:Yojson.Safe.t
  -> string

(** [handle_masc_board] dispatches public MCP [masc_board_*] tools through
    the existing board dispatcher while allowing descriptor route evidence
    and receipt summaries to resolve the tool. *)
val handle_masc_board : name:string -> args:Yojson.Safe.t -> string
