(** Keeper_tools_agent_core — Wrap keeper tools as AGENT_CORE Tool.t for Agent.run().

    Bridges [Keeper_tool_dispatch_runtime.execute_keeper_tool_call_with_outcome] dispatch
    to [Agent_core.Tool.t] list via [Tool_bridge.agent_core_tool_of_masc].

    Tool execution reads current context from [ctx_snapshot] (immutable),
    enabling Agent.run() to manage messages while keeper tools
    access the working context for status/metrics.

    @since Phase 4 — Keeper → Agent.run() migration *)

type terminal_effect_failure =
  { failure_class : Tool_result.tool_failure_class
  ; effect_disposition : Tool_result.failure_effect_disposition
  ; detail : Keeper_terminal_effect_detail.t
  }

type terminal_effect_state =
  | Terminal_effect_open
  | Deferred_tool_result
  | External_effect_deferred
  | Terminal_effect_completed of Keeper_tool_execution.terminal_effect_receipt
  | Terminal_effect_failed of terminal_effect_failure

type attached_surface =
  { offered : Keeper_identity_tools.offered_tool list
  ; agent_cell : Agent_core.Agent.t option ref
  ; history : Agent_core.Types.message list
  ; load_receipts : Keeper_tool_load_receipts.restored
  ; keeper_turn_id : int
  }

type listing_placement =
  | No_listing
  | Listing of { deferred_builtin_names : string list }

type image_admission = Image_input_admitted | Image_input_unavailable

let descriptor_admitted ?(image_generation_admitted = true) admission (descriptor : Keeper_tool_descriptor.t) =
  match descriptor.runtime_handler with
  | Keeper_tool_descriptor.Tool_read_image ->
    (match admission with
     | Image_input_admitted -> true
     | Image_input_unavailable -> false)
  | Keeper_tool_descriptor.Tool_analyze_image ->
    (match admission with
     | Image_input_admitted -> false
     | Image_input_unavailable -> true)
  | Keeper_tool_descriptor.Tool_generate_image ->
    image_generation_admitted
  | Keeper_tool_descriptor.Tool_lane_addon _
  | Keeper_tool_descriptor.Tool_execute
  | Keeper_tool_descriptor.Tool_search_files
  | Keeper_tool_descriptor.Tool_read_file
  | Keeper_tool_descriptor.Tool_edit_file
  | Keeper_tool_descriptor.Tool_write_file
  | Keeper_tool_descriptor.Tool_lane_status
  | Keeper_tool_descriptor.Tool_tools_list
  | Keeper_tool_descriptor.Tool_capability_search
  | Keeper_tool_descriptor.Tool_context_status
  | Keeper_tool_descriptor.Tool_peer_artifact
  | Keeper_tool_descriptor.Tool_artifact_read
  | Keeper_tool_descriptor.Tool_skill_validate
  | Keeper_tool_descriptor.Tool_artifact_draft
  | Keeper_tool_descriptor.Tool_artifact_publish
  | Keeper_tool_descriptor.Tool_skill_publish
  | Keeper_tool_descriptor.Tool_workspace_memory_read
  | Keeper_tool_descriptor.Tool_memory_search
  | Keeper_tool_descriptor.Tool_memory_select
  | Keeper_tool_descriptor.Tool_memory_retract
  | Keeper_tool_descriptor.Tool_memory_write
  | Keeper_tool_descriptor.Tool_constitution_write
  | Keeper_tool_descriptor.Tool_constitution_read
  | Keeper_tool_descriptor.Tool_constitution_remove
  | Keeper_tool_descriptor.Tool_wiki_search
  | Keeper_tool_descriptor.Tool_wiki_read
  | Keeper_tool_descriptor.Tool_surface_read
  | Keeper_tool_descriptor.Tool_surface_post
  | Keeper_tool_descriptor.Tool_ide_annotate
  | Keeper_tool_descriptor.Tool_voice_dispatch
  | Keeper_tool_descriptor.Tool_task_dispatch
  | Keeper_tool_descriptor.Tool_board_dispatch
  | Keeper_tool_descriptor.Tool_masc_task_dispatch
  | Keeper_tool_descriptor.Tool_masc_plan_dispatch
  | Keeper_tool_descriptor.Tool_masc_run_dispatch
  | Keeper_tool_descriptor.Tool_masc_agent_dispatch
  | Keeper_tool_descriptor.Tool_masc_workspace_dispatch
  | Keeper_tool_descriptor.Tool_masc_misc_dispatch
  | Keeper_tool_descriptor.Tool_web_search
  | Keeper_tool_descriptor.Tool_web_fetch
  | Keeper_tool_descriptor.Tool_browser_tabs
  | Keeper_tool_descriptor.Tool_browser_read
  | Keeper_tool_descriptor.Tool_browser_session
  | Keeper_tool_descriptor.Tool_browser_goto
  | Keeper_tool_descriptor.Tool_browser_act
  | Keeper_tool_descriptor.Tool_browser_interact
  | Keeper_tool_descriptor.Tool_masc_agent_timeline_dispatch
  | Keeper_tool_descriptor.Tool_masc_schedule_dispatch
  | Keeper_tool_descriptor.Tool_keeper_job_dispatch
  | Keeper_tool_descriptor.Tool_receipt_wait
  | Keeper_tool_descriptor.Tool_keeper_code_query_dispatch
  | Keeper_tool_descriptor.Tool_masc_keeper_dispatch
  | Keeper_tool_descriptor.Tool_masc_fusion_dispatch
  | Keeper_tool_descriptor.Tool_masc_fusion_status
  | Keeper_tool_descriptor.Tool_masc_fusion_decision
  | Keeper_tool_descriptor.Tool_masc_file_dispatch
  | Keeper_tool_descriptor.Tool_masc_wiki_dispatch
  | Keeper_tool_descriptor.Tool_masc_local_runtime_dispatch -> true

type model_tool_surface =
  { image_admission : image_admission
  ; image_generation_admitted : bool
  ; tools : Agent_core.Tool.t list
  ; agent_core_tools : Agent_core.Tool.t list
  ; on_demand_tool_names : string list
  ; result_bounds : (string * int) list
  ; listing : listing_placement
  }

let assemble_model_tool_surface ~image_admission ~tools ~agent_core_tools
    ~on_demand_tool_names ~result_bounds ~listing : model_tool_surface =
  { image_admission; image_generation_admitted = true; tools; agent_core_tools; on_demand_tool_names; result_bounds; listing }

let with_image_generation_admitted image_generation_admitted surface =
  { surface with image_generation_admitted }

type model_tool_projection =
  runtime:Runtime_instance.t -> carried:Agent_core.Tool.t list -> model_tool_surface

type tool_bundle =
  { tools : Agent_core.Tool.t list
  ; agent_core_tools : Agent_core.Tool.t list
  ; on_demand_tool_names : string list
  ; result_bounds : (string * int) list
  ; listing : listing_placement
  ; project_for_runtime : model_tool_projection
  ; cleanup : unit -> unit
  ; terminal_effect_state : unit -> terminal_effect_state
  ; gate_replay_inputs : Keeper_gate_replay.resolution_input list
  ; turn_sandbox_factory : Keeper_sandbox_factory.t option
  }

(** Tool usage now lives in Keeper_registry (per-entry tool_usage Hashtbl).
    These public functions expose the registry view without re-exporting
    the entry record type. *)

let tool_usage_for_keeper keeper_name : (string * Keeper_types.tool_call_entry) list =
  Keeper_registry_lookup.tool_usage_of_by_name keeper_name
;;

let record_keeper_internal_tool_call ~tool_name ~disposition ~duration_ms =
  Tool_registry.record_call
    ~source:Agent_internal
    ~tool_name
    ~disposition
    ~duration_ms
    ()
;;

(* ── end tracking ────────────────────────────────────────────── *)

(* Build AGENT_CORE Tool.t list from keeper's allowed tools.

   Each tool delegates to [execute_keeper_tool_call_with_outcome] with the current
   [ctx_snapshot] value. Tools that raise exceptions return error results
   instead of crashing the agent loop.

   @param config Workspace configuration for tool dispatch
   @param meta Keeper metadata (determines which tools are allowed)
   @param ctx_snapshot Immutable snapshot of current working context *)

(** Build the per-tool handler closure.

    Extracted from the original anonymous closure inside [make_tools] so
    that alias [Tool.t] entries (e.g. [Execute]) can reuse
    the exact same telemetry/decision-log pipeline by
    instantiating this helper with the INTERNAL name as [~name].

    Telemetry SSOT contract: [~name] flows into every observability
    sink (Keeper_registry.record_tool_use, SSE broadcast tool_name,
    decision-log "tool" field, Tool_registry). The LLM-facing
    public name (Execute/Read/...) only appears as the [Tool.schema.name]
    set by [Tool_bridge.agent_core_tool_of_masc] above this helper.

    Public aliases validate the LLM-facing payload before translation to the
    internal tool's expected payload. Identity by default. *)

(* Handlers moved to [Keeper_tools_agent_core_handler] — see
   keeper_tools_agent_core_handler.mli for [make_keeper_tool_handler],
   [make_tool_bundle], and [make_tools]. *)
