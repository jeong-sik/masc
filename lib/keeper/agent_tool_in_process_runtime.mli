(** In-process runtime handlers for descriptor-backed coordination tools.

    RFC-0179 PR-2 onwards. This module hosts handlers for descriptors whose
    executor is [In_process] — pure OCaml-runtime functions with no sandbox,
    no host process spawn, no remote MCP. Each handler returns the raw output
    JSON string; the caller in [Keeper_exec_tools] wraps it via
    [make_executed_tool_result]. *)

val handle_time_now : args:Yojson.Safe.t -> string
(** [handle_time_now ~args] ignores [args] (the descriptor schema mandates an
    empty object) and returns
    [{ "now_iso": <ISO-8601 UTC>, "now_unix": <epoch seconds float> }]. *)

val handle_stay_silent : args:Yojson.Safe.t -> string
(** [handle_stay_silent ~args] ignores [args] and returns
    [{ "status": "silent" }]. *)

val handle_tools_list
  :  meta:Keeper_types.keeper_meta
  -> args:Yojson.Safe.t
  -> string
(** [handle_tools_list ~meta ~args] ignores [args] and returns the
    keeper-visible tool list JSON via [Keeper_exec_shared.keeper_tools_list_json]. *)

val handle_memory_write
  :  config:Coord.config
  -> meta:Keeper_types.keeper_meta
  -> args:Yojson.Safe.t
  -> string
(** [handle_memory_write] delegates to [Keeper_exec_memory.keeper_memory_write_json]. *)

val handle_ide_annotate
  :  config:Coord.config
  -> meta:Keeper_types.keeper_meta
  -> args:Yojson.Safe.t
  -> string
(** [handle_ide_annotate] delegates to [Agent_tool_ide_runtime.handle_ide_annotate]. *)

val handle_voice
  :  meta:Keeper_types.keeper_meta
  -> name:string
  -> args:Yojson.Safe.t
  -> string
(** [handle_voice] delegates to [Agent_tool_voice_runtime.handle_voice_tool].
    The [name] is the descriptor's [internal_name]; the voice runtime
    name-dispatches across the six voice tools (speak / listen / agent /
    sessions / session_start / session_end). *)

val handle_task
  :  config:Coord.config
  -> meta:Keeper_types.keeper_meta
  -> name:string
  -> args:Yojson.Safe.t
  -> string
(** [handle_task] delegates to [Keeper_exec_task.handle_keeper_task_tool].
    The [name] is the descriptor's [internal_name]; the task runtime
    name-dispatches across the nine task tools (tasks_list, tasks_audit,
    task_force_release, task_force_done, broadcast, task_claim,
    task_create, task_done, task_submit_for_verification). *)

val handle_board
  :  meta:Keeper_types.keeper_meta
  -> name:string
  -> args:Yojson.Safe.t
  -> string
(** [handle_board] delegates to [Agent_tool_board_runtime.handle_keeper_board_tool].
    The [name] is the descriptor's [internal_name]; the board runtime
    name-dispatches across the 15 board tools (comment, comment_vote,
    curation_read, curation_submit, get, list, post, search, stats, vote,
    sub_board_create / delete / get / list / update). *)
