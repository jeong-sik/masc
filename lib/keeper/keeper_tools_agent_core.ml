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
  ; diagnostic : string
  }

type terminal_effect_state =
  | Terminal_effect_open
  | Deferred_tool_result
  | External_effect_deferred
  | Terminal_effect_completed of Keeper_tool_execution.terminal_effect_receipt
  | Terminal_effect_failed of terminal_effect_failure

type gate_replay_delivery =
  { approval_id : string
  ; outcome : Keeper_gate_replay.outcome
  ; terminal_effect_receipt :
      Keeper_tool_execution.terminal_effect_receipt option
  }

type tool_bundle =
  { tools : Agent_core.Tool.t list
  ; agent_core_tools : Agent_core.Tool.t list
  ; cleanup : unit -> unit
  ; terminal_effect_state : unit -> terminal_effect_state
  ; gate_replay_delivery : gate_replay_delivery option
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

(** RFC-0006 Phase A.2: build the per-tool handler closure.

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
