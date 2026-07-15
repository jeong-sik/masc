(** In-process runtime handlers for descriptor-backed workspace tools.

    RFC-0179. Hosts handlers for descriptors whose executor is [In_process] —
    pure OCaml-runtime functions with no sandbox, no host process spawn, no
    remote MCP. Dispatch uses producer-owned [Keeper_tool_execution.t]
    results; raw string entrypoints are compatibility projections only. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

val handle_time_now : args:Yojson.Safe.t -> string

val handle_tools_list : meta:keeper_meta -> args:Yojson.Safe.t -> string

val handle_web_search_with_outcome
  :  config:Workspace.config
  -> meta:keeper_meta
  -> ?continuation_channel:Keeper_continuation_channel.t
  -> ?gate_context:(unit -> Keeper_gate.causal_context)
  -> ?gate_grant:Keeper_gate.cycle_grant
  -> args:Yojson.Safe.t
  -> unit
  -> Keeper_tool_execution.t

val handle_web_fetch_with_outcome
  :  config:Workspace.config
  -> meta:keeper_meta
  -> ?continuation_channel:Keeper_continuation_channel.t
  -> ?gate_context:(unit -> Keeper_gate.causal_context)
  -> ?gate_grant:Keeper_gate.cycle_grant
  -> args:Yojson.Safe.t
  -> unit
  -> Keeper_tool_execution.t

val handle_context_status
  :  config:Workspace.config
  -> meta:keeper_meta
  -> ctx_work:working_context
  -> args:Yojson.Safe.t
  -> string

val handle_memory_search
  :  config:Workspace.config
  -> meta:keeper_meta
  -> ctx_work:working_context
  -> args:Yojson.Safe.t
  -> string

val handle_memory_write
  :  config:Workspace.config
  -> meta:keeper_meta
  -> args:Yojson.Safe.t
  -> string

val handle_library_search_with_outcome
  : meta:keeper_meta -> args:Yojson.Safe.t -> Keeper_tool_execution.t
val handle_library_read_with_outcome
  : meta:keeper_meta -> args:Yojson.Safe.t -> Keeper_tool_execution.t

val handle_surface_read
  :  config:Workspace.config
  -> meta:keeper_meta
  -> args:Yojson.Safe.t
  -> string

val handle_surface_post_with_outcome
  :  config:Workspace.config
  -> meta:keeper_meta
  -> ?continuation_channel:Keeper_continuation_channel.t
  -> ?gate_context:(unit -> Keeper_gate.causal_context)
  -> ?gate_grant:Keeper_gate.cycle_grant
  -> args:Yojson.Safe.t
  -> unit
  -> Keeper_tool_execution.t

val handle_person_note_set
  :  config:Workspace.config
  -> meta:keeper_meta
  -> args:Yojson.Safe.t
  -> string

val handle_person_note_set_with_outcome
  :  config:Workspace.config
  -> meta:keeper_meta
  -> args:Yojson.Safe.t
  -> Keeper_tool_execution.t

val handle_ide_annotate
  :  config:Workspace.config
  -> meta:keeper_meta
  -> args:Yojson.Safe.t
  -> string

val handle_ide_annotate_with_outcome
  :  config:Workspace.config
  -> meta:keeper_meta
  -> args:Yojson.Safe.t
  -> Keeper_tool_execution.t

(** [handle_voice_with_outcome] dispatches to
    [Keeper_tool_voice_runtime.handle_voice_tool_with_outcome] by [name]. Caller
    must pass a name in the voice cluster. *)
val handle_voice_with_outcome
  :  config:Workspace.config
  -> meta:keeper_meta
  -> name:string
  -> args:Yojson.Safe.t
  -> unit
  -> Keeper_tool_execution.t

(** [handle_task] dispatches to [Keeper_tool_task_runtime.handle_keeper_task_tool]
    by [name]. Caller must pass a name in the task / broadcast cluster. *)
val handle_task
  :  config:Workspace.config
  -> meta:keeper_meta
  -> name:string
  -> args:Yojson.Safe.t
  -> string

(** [handle_board] dispatches to
    [Keeper_tool_board_runtime.handle_keeper_board_tool] by [name]. Caller
    must pass a name in the board cluster. *)
val handle_board
  :  meta:keeper_meta
  -> name:string
  -> args:Yojson.Safe.t
  -> string

(** [handle_masc_board] admits only Board operations whose typed Keeper
    projection is [Direct_masc], binds runtime-owned identity to [meta.name],
    and explicitly rejects wrapper-backed or unknown routes. *)
val handle_masc_board : meta:keeper_meta -> name:string -> args:Yojson.Safe.t -> string
val handle_masc_board_with_outcome
  : meta:keeper_meta -> name:string -> args:Yojson.Safe.t -> Keeper_tool_execution.t

(** RFC-0182 §3.1 — [handle_masc_task_with_outcome] is the descriptor-projection
    cluster handler for [masc_task_*] tools (add_task / batch_add_tasks /
    claim_next / task_history / tasks / transition / update_priority).
    Constructs a [Task.Handlers.context] from
    [config + meta.name + sw=None] and calls [Task.Tool.dispatch]. *)
val handle_masc_task_with_outcome
  : config:Workspace.config -> meta:keeper_meta -> name:string -> args:Yojson.Safe.t
  -> Keeper_tool_execution.t

(** RFC-0182 §3.1 — [handle_masc_plan_with_outcome] is the descriptor-projection
    cluster handler for [masc_plan_*] + [masc_note_add] + [masc_deliver]
    tools. Constructs a [Tool_plan.context] from [config] and calls
    [Tool_plan.dispatch]. *)
val handle_masc_plan_with_outcome
  : config:Workspace.config -> name:string -> args:Yojson.Safe.t
  -> Keeper_tool_execution.t

(** RFC-0182 §3.1 — [handle_masc_run_with_outcome] is the descriptor-projection
    cluster handler for [masc_run_*] tools (deliverable / get / init /
    list / log / plan). Constructs a [Tool_run.context] from [config] and
    keeper [meta], then calls [Tool_run.dispatch]. *)
val handle_masc_run_with_outcome
  : config:Workspace.config -> meta:keeper_meta -> name:string -> args:Yojson.Safe.t
  -> Keeper_tool_execution.t

(** RFC-0182 §3.1 — [handle_masc_agent_with_outcome] is the descriptor-projection
    cluster handler for [masc_agents] / [masc_agent_update] /
    [masc_get_metrics] / [masc_agent_fitness] / [masc_agent_card].
    Constructs a [Tool_agent.context] from [config + meta.name] and calls
    [Tool_agent.dispatch]. *)
val handle_masc_agent_with_outcome
  : config:Workspace.config -> meta:keeper_meta -> name:string -> args:Yojson.Safe.t
  -> Keeper_tool_execution.t

(** RFC-0182 §3.1 — [handle_masc_workspace_with_outcome] is the descriptor-projection
    cluster handler for [masc_status] / [masc_heartbeat] / [masc_check] /
    [masc_reset] / [masc_goal_*]. Constructs a [Tool_workspace.context] from
    [config + meta.name] and calls [Tool_workspace.dispatch]. *)
val handle_masc_workspace_with_outcome
  : config:Workspace.config -> meta:keeper_meta -> name:string -> args:Yojson.Safe.t
  -> Keeper_tool_execution.t

(** RFC-0182 §3.1 — [handle_masc_misc_with_outcome] is the descriptor-projection
    cluster handler for [masc_config] / [masc_dashboard] /
    [masc_cleanup_zombies] / [masc_tool_stats] / [masc_tool_help] /
    [masc_web_search] / [masc_web_fetch].
    Constructs a [Tool_misc.context] from [config + meta.name] and calls
    [Tool_misc.dispatch]. *)
val handle_masc_misc_with_outcome
  : config:Workspace.config -> meta:keeper_meta -> name:string -> args:Yojson.Safe.t
  -> Keeper_tool_execution.t

(** RFC-0182 §3.1 — [handle_masc_control_with_outcome] is the descriptor-projection
    cluster handler for [masc_pause] / [masc_resume]. Constructs a
    [Tool_control.context] from [config + meta.name] and calls
    [Tool_control.dispatch]. *)
val handle_masc_control_with_outcome
  : config:Workspace.config -> meta:keeper_meta -> name:string -> args:Yojson.Safe.t
  -> Keeper_tool_execution.t

(** RFC-0182 §3.1 — [handle_masc_agent_timeline_with_outcome] is the
    descriptor-projection singleton handler for [masc_agent_timeline].
    Constructs a [Tool_agent_timeline.context] from [config + meta.name]
    and calls [Tool_agent_timeline.dispatch]. *)
val handle_masc_agent_timeline_with_outcome
  : config:Workspace.config -> meta:keeper_meta -> name:string -> args:Yojson.Safe.t
  -> Keeper_tool_execution.t

(** RFC-0234 — [handle_masc_schedule_with_outcome] is the descriptor-projection
    cluster handler for [masc_schedule_*] tools. *)
val handle_masc_schedule_with_outcome
  : config:Workspace.config -> meta:keeper_meta -> name:string -> args:Yojson.Safe.t
  -> Keeper_tool_execution.t

(** RFC-0252 — [handle_masc_fusion_with_outcome] is the in-process handler for the
    [masc_fusion] out-of-band panel+judge deliberation tool.  It loads the
    [fusion] policy from runtime.toml, mints a fresh run_id, and delegates the
    gate -> fiber fork -> orchestrator logic to {!Fusion_tool.handle}.

    Resolves the server ROOT switch + net from {!Eio_context} (the
    deliberation must outlive the keeper turn, so the turn-scoped switch is
    NOT used).  When the root switch or net is unavailable it returns an
    explicit typed failure (no silent no-op). *)
val handle_masc_fusion_with_outcome
  :  config:Workspace.config
  -> meta:keeper_meta
  -> ?continuation_channel:Keeper_continuation_channel.t
  -> args:Yojson.Safe.t
  -> unit
  -> Keeper_tool_execution.t

(** RFC-0266 §7 Phase 3 — [fusion_status_json] projects the calling keeper's
    fusion runs to the masc_fusion_status tool's JSON string. With an empty
    [run_id] it lists every tracked run owned by [keeper]
    ([{ ok; count; runs }]); with a non-empty [run_id] it returns the owned
    single run ([{ ok; found; run }]) or a not-found envelope
    ([{ ok; found = false; run_id; status = "not_found" }]). A run owned by a
    different keeper is reported as not found. Each run's status is rendered as
    ["running"], ["completed"] (ok), or ["failed"] (denied / sink-failed /
    aborted). Pure over [registry] so tests can pass an isolated
    [Fusion_run_registry.create ()]. *)
val fusion_status_json
  :  registry:Fusion_run_registry.t
  -> keeper:string
  -> run_id:string
  -> string

(** RFC-0266 §7 Phase 3 — in-process handler for the [masc_fusion_status]
    read-only tool. Parses the optional [run_id] argument and projects the
    process-wide [Fusion_run_registry.global] via {!fusion_status_json}, scoped
    to [meta.name]. *)
val handle_masc_fusion_status
  :  meta:Keeper_meta_contract.keeper_meta
  -> args:Yojson.Safe.t
  -> unit
  -> string

(** RFC-keeper-vision-delegation-tool §2.6 — [handle_analyze_image_with_outcome].
    Thin delegate to [Keeper_vision_tool.handle_with_outcome]; needs the Eio
    [net]/[clock] for the vision sub-call. *)
val handle_analyze_image_with_outcome
  :  ?sw:Eio.Switch.t
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> meta:Keeper_meta_contract.keeper_meta
  -> args:Yojson.Safe.t
  -> unit
  -> Keeper_tool_execution.t

(** RFC-0182 §3.1 — [handle_masc_keeper] is the descriptor-projection
    cluster handler for the [masc_keeper_*] ctx-free tool surface.
    Dispatches via [Keeper_dispatch_ref] registered by [Keeper_tool_surface] at
    module load.  Receives [meta] so callers like [masc_keeper_status]
    can resolve the "self" target when the [name] argument is empty. *)
val handle_masc_keeper
  :  publication_recovery_provider:
       Keeper_publication_recovery_availability.provider
  -> ?sw:Eio.Switch.t
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t
  -> ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> ?mcp_session_id:string
  -> ?continuation_channel:Keeper_continuation_channel.t
  -> ?gate_context:(unit -> Keeper_gate.causal_context)
  -> ?gate_grant:Keeper_gate.cycle_grant
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> name:string
  -> args:Yojson.Safe.t
  -> unit
  -> string

val handle_masc_keeper_with_outcome
  :  publication_recovery_provider:
       Keeper_publication_recovery_availability.provider
  -> ?sw:Eio.Switch.t
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t
  -> ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> ?mcp_session_id:string
  -> ?continuation_channel:Keeper_continuation_channel.t
  -> ?gate_context:(unit -> Keeper_gate.causal_context)
  -> ?gate_grant:Keeper_gate.cycle_grant
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> name:string
  -> args:Yojson.Safe.t
  -> unit
  -> Keeper_tool_execution.t

(** Dispatch the local-runtime descriptor cluster. The arbitrary-network
    Ollama probe crosses the neutral external-effect Gate with the exact
    operation identity and complete input; other registered local-runtime
    operations retain their existing dispatch behavior. *)
val handle_masc_local_runtime
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> ?continuation_channel:Keeper_continuation_channel.t
  -> ?gate_context:(unit -> Keeper_gate.causal_context)
  -> ?gate_grant:Keeper_gate.cycle_grant
  -> name:string
  -> args:Yojson.Safe.t
  -> unit
  -> string

val handle_masc_local_runtime_with_outcome
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> ?continuation_channel:Keeper_continuation_channel.t
  -> ?gate_context:(unit -> Keeper_gate.causal_context)
  -> ?gate_grant:Keeper_gate.cycle_grant
  -> name:string
  -> args:Yojson.Safe.t
  -> unit
  -> Keeper_tool_execution.t
