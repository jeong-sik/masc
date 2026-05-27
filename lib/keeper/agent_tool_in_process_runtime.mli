(** In-process runtime handlers for descriptor-backed coordination tools.

    RFC-0179. Hosts handlers for descriptors whose executor is [In_process] —
    pure OCaml-runtime functions with no sandbox, no host process spawn, no
    remote MCP. Each handler returns the raw output JSON string; the caller
    in [Agent_tool_runtime.handle_in_process] wraps it via
    [Agent_tool_dispatch_runtime.make_executed_tool_result].

    Output parity: each handler reproduces the exact JSON the legacy match
    arm in [Agent_tool_dispatch_runtime.execute_keeper_tool_call_with_outcome] used to
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

(** [handle_task] dispatches to [Agent_tool_task_runtime.handle_keeper_task_tool]
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

(** RFC-0182 §3.1 — [handle_masc_task] is the descriptor-projection
    cluster handler for [masc_task_*] tools (add_task / batch_add_tasks /
    claim_next / task_history / tasks / transition / update_priority).
    Constructs a [Tool_task_handlers.context] from
    [config + meta.name + sw=None] and calls [Tool_task.dispatch]. *)
val handle_masc_task
  :  config:Coord.config
  -> meta:keeper_meta
  -> name:string
  -> args:Yojson.Safe.t
  -> string

(** RFC-0182 §3.1 — [handle_masc_plan] is the descriptor-projection
    cluster handler for [masc_plan_*] + [masc_note_add] + [masc_deliver]
    tools. Constructs a [Tool_plan.context] from [config] and calls
    [Tool_plan.dispatch]. *)
val handle_masc_plan
  :  config:Coord.config
  -> name:string
  -> args:Yojson.Safe.t
  -> string

(** RFC-0182 §3.1 — [handle_masc_run] is the descriptor-projection
    cluster handler for [masc_run_*] tools (deliverable / get / init /
    list / log / plan). Constructs a [Tool_run.context] from [config] and
    calls [Tool_run.dispatch]. *)
val handle_masc_run
  :  config:Coord.config
  -> name:string
  -> args:Yojson.Safe.t
  -> string

(** RFC-0182 §3.1 — [handle_masc_agent] is the descriptor-projection
    cluster handler for [masc_agents] / [masc_agent_update] /
    [masc_get_metrics] / [masc_agent_fitness] / [masc_agent_card].
    Constructs a [Tool_agent.context] from [config + meta.name] and calls
    [Tool_agent.dispatch]. *)
val handle_masc_agent
  :  config:Coord.config
  -> meta:keeper_meta
  -> name:string
  -> args:Yojson.Safe.t
  -> string

(** RFC-0182 §3.1 — [handle_masc_coord] is the descriptor-projection
    cluster handler for [masc_status] / [masc_heartbeat] / [masc_check] /
    [masc_reset] / [masc_goal_*]. Constructs a [Tool_coord.context] from
    [config + meta.name] and calls [Tool_coord.dispatch]. *)
val handle_masc_coord
  :  config:Coord.config
  -> meta:keeper_meta
  -> name:string
  -> args:Yojson.Safe.t
  -> string

(** RFC-0182 §3.1 — [handle_masc_misc] is the descriptor-projection
    cluster handler for [masc_config] / [masc_dashboard] /
    [masc_cleanup_zombies] / [masc_tool_stats] / [masc_tool_help] /
    [masc_web_search] / [masc_web_fetch] / [masc_tool_admin_*].
    Constructs a [Tool_misc.context] from [config + meta.name] and calls
    [Tool_misc.dispatch]. *)
val handle_masc_misc
  :  config:Coord.config
  -> meta:keeper_meta
  -> name:string
  -> args:Yojson.Safe.t
  -> string

(** RFC-0182 §3.1 — [handle_masc_control] is the descriptor-projection
    cluster handler for [masc_pause] / [masc_resume]. Constructs a
    [Tool_control.context] from [config + meta.name] and calls
    [Tool_control.dispatch]. *)
val handle_masc_control
  :  config:Coord.config
  -> meta:keeper_meta
  -> name:string
  -> args:Yojson.Safe.t
  -> string

(** RFC-0182 §3.1 — [handle_masc_agent_timeline] is the
    descriptor-projection singleton handler for [masc_agent_timeline].
    Constructs a [Tool_agent_timeline.context] from [config + meta.name]
    and calls [Tool_agent_timeline.dispatch]. *)
val handle_masc_agent_timeline
  :  config:Coord.config
  -> meta:keeper_meta
  -> name:string
  -> args:Yojson.Safe.t
  -> string

(** RFC-0182 §3.1 — [handle_masc_local_runtime] is the
    descriptor-projection cluster handler for [masc_runtime_verify] /
    [masc_runtime_ollama_probe]. [Tool_local_runtime.dispatch] takes a
    polymorphic ctx that is ignored by the handlers; we pass [()]. *)
val handle_masc_local_runtime
  :  name:string
  -> args:Yojson.Safe.t
  -> string
