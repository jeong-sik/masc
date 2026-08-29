(** Keeper_tools_agent_core — Wrap keeper tools as [Agent_core.Tool.t] for [Agent.run].

    Bridges [Keeper_tool_dispatch_runtime.execute_keeper_tool_call_with_outcome] dispatch
    to [Agent_core.Tool.t list] via [Tool_bridge.agent_core_tool_of_masc]. Tool
    execution reads the current context from [ctx_snapshot]
    (immutable), enabling [Agent.run] to manage messages while
    keeper tools access the working context for status/metrics.

    @since Phase 4 — Keeper → Agent.run() migration *)

(** Bundle returned by [make_tool_bundle]: the [Agent_core.Tool.t list]
    plus a [cleanup] thunk that releases the per-turn sandbox
    runtimes. *)
type terminal_effect_failure =
  { failure_class : Tool_result.tool_failure_class
  ; effect_disposition : Tool_result.failure_effect_disposition
  ; diagnostic : string
  }

type terminal_effect_state =
  | Terminal_effect_open
      (** No tool has requested a turn boundary. *)
  | Deferred_tool_result
      (** A normal tool transition deferred; it is not a Gate external effect. *)
  | External_effect_deferred
      (** Gate deferred an external effect and will emit a durable resolution. *)
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
    (** Every tool this turn can run, always-loaded first. The official-client
        lanes take this list whole: their tool set is pinned at process spawn
        or thread start and is part of a resumable session's identity, so a
        set widened mid-turn is one they cannot accept. *)
  ; always_loaded : Agent_core.Tool.t list
    (** What is sent as schemas on every lane. Built-in tools: the day the
        index was measured, every tool a Keeper actually called was one of
        these, so hiding them behind an index would add a round trip and save
        nothing. *)
  ; deferrable : (Agent_core.Types.tool_schema * Agent_core.Tool.t) list
    (** Attached-service tools, which the Agent Core lane may carry as an
        index instead. [tools] is [always_loaded] followed by these, so the
        three cannot disagree about what the turn holds. *)
  ; cleanup : unit -> unit
  ; terminal_effect_state : unit -> terminal_effect_state
  ; gate_replay_delivery : gate_replay_delivery option
  }

(** Per-keeper tool usage view from [Keeper_registry]. *)
val tool_usage_for_keeper : string -> (string * Keeper_types.tool_call_entry) list

(** Record an internal keeper tool call in the telemetry registry. *)
val record_keeper_internal_tool_call
  :  tool_name:string
  -> disposition:('completed, 'deferred, 'failed) Tool_result.disposition
  -> duration_ms:int
  -> unit

(* Handlers moved to [Keeper_tools_agent_core_handler] — see
   keeper_tools_agent_core_handler.mli for [make_keeper_tool_handler],
   [make_tool_bundle], and [make_tools]. *)


(** Build the per-tool handler closure used by both internal and
    alias tool entries. The closure dispatches via
    [execute_keeper_tool_call_with_outcome] using [~name] as the
    INTERNAL tool name (telemetry SSOT). [~input_schema] is the
    internal tool schema used for pre-execution validation. Public aliases
    validate their LLM-facing payload before translation to the internal
    payload. *)

(** Build the keeper's full [tool_bundle]: internal tools +
    alias-registered (public name) tools that translate input to
    internal payloads. The cleanup thunk releases per-turn sandbox
    runtimes (Docker case). *)

(** Convenience over [make_tool_bundle] returning only [.tools]. *)
