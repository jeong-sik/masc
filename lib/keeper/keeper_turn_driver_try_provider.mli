(** Extracted provider-attempt runner for keeper runtime turns. *)

(** A reading of the keeper's live in-turn progress signal (#28417).

    Mirrors the two [Keeper_registry_types.turn_observation] fields the stall
    decision needs, so this module decides without depending on
    [Keeper_registry]. *)
type provider_progress_sample =
  { last_progress_at : float
        (** Unix timestamp of the most recent in-turn progress signal. *)
  ; active_tool_count : int
        (** Tools issued but not yet completed; non-zero means work in
            flight, not a stall. *)
  }

type try_provider_ctx =
  { runtime_id : string
  ; error_runtime_id : string
  ; max_request_body_bytes : int
  ; model_input_capacity_bytes : int
  ; base_path : string
  ; keeper_name : string
  ; name : string
  ; goal : string
  ; goal_blocks : Agent_core.Types.content_block list option
  ; session_id : string option
  ; system_prompt : string
  ; tools : Agent_core.Tool.t list
  ; initial_messages : Agent_core.Types.message list
  ; model_input_projection : Agent_core.Agent.model_input_projection option
  ; stream_idle_timeout_s : float option
  ; first_event_timeout_s : float option
  ; body_timeout_s : float option
  ; provider_call_deadline_sec : float option
        (** Seconds a provider attempt may go WITHOUT a progress signal
            before it is cancelled and rotated (#28417 changed this from a
            total-elapsed ceiling). [None] disables MASC-side enforcement. *)
  ; provider_progress_probe : (unit -> provider_progress_sample option) option
        (** Reads the keeper's live progress signal. Must not raise; return
            [None] when unavailable, which degrades the deadline to the
            pre-#28417 elapsed ceiling. *)
  ; temperature : float option
  ; accept : Agent_core.Types.api_response -> bool
  ; hooks : Agent_core.Hooks.hooks option
  ; raw_trace : Agent_core.Raw_trace.t option
  ; trace_link : (string * string) option
  ; transport_resolved : Masc_grpc_transport.t
  ; checkpoint_sidecar : Yojson.Safe.t option
  ; cache_system_prompt : bool
  ; yield_on_tool : bool
  ; checkpoint_sink : Agent_core.Agent.checkpoint_sink option
  ; checkpoint_stage_observed : bool Atomic.t
  ; context_injector : Agent_core.Hooks.context_injector option
  ; context : Agent_core.Context.t option
  ; enable_thinking : bool option
  ; preserve_thinking : bool option
  ; cooperative_yield_probe : Runtime_agent.cooperative_yield_probe option
  ; agent_core_checkpoint : Agent_core.Checkpoint.t option
  ; sw : Eio.Switch.t
  ; net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  ; on_event : (Agent_core.Types.sse_event -> unit) option
  ; on_yield : (unit -> unit) option
  ; on_resume : (unit -> unit) option
  ; agent_ref : Agent_core.Agent.t option ref option
  ; on_runtime_observation :
      (Runtime_observation.runtime_observation -> unit) option
  ; on_request_wire_observation :
      (runtime_id:string ->
       max_request_body_bytes:int ->
       body_bytes:int ->
       unit)
        option
  ; on_model_input_window_observation :
      (measurement:Turn_record.model_input_measurement
       -> Runtime_model_input_tail_window.window_observation
       -> unit)
        option
        (** Called with the cut the window stage selected over the keeper's
            conversation history, as that stage saw it, and which shape it was
            measured against.

            Two kinds of material in the same request are outside these counts,
            for two different reasons. Pinned extra-system context and the
            synthetic preamble are excluded by rule: {!annotate} classifies
            them [Pinned] every turn because they are re-assembled rather than
            conversed. Anything [ctx.model_input_projection] appends afterwards
            — a pending Gate approval replay, for instance — is excluded only
            because it arrives after this stage has run. That one is ordinary
            conversation, it is persisted, and from the next turn it is counted
            like any other atom; the turn it is appended on undercounts by
            exactly that message and then self-corrects.

            So this is not a decomposition of {!on_request_wire_observation}:
            that one measures the bytes the provider admitted, and those bytes
            cover material these atoms do not.

            Invoked per provider request, and one keeper turn issues many —
            62 and 83 on the two turns this module's window comment measures —
            so the retained value is the last request of the turn, not a
            summary of it. Never invoked when the projection refuses: the turn
            carries a typed budget error instead, and reporting a cut that was
            never dispatched would fabricate evidence. *)
  ; event_bus : Agent_core.Event_bus.t option
  ; runtime_manifest_context : Keeper_runtime_manifest.turn_context option
  ; runtime_manifest_append : (Keeper_runtime_manifest.t -> unit) option
  ; turn_start : Mtime.t
  ; seq_ref : int ref
  }

val apply_accept :
  runtime_id:string ->
  accept:(Agent_core.Types.api_response -> bool) ->
  Runtime_agent.run_result ->
  (Runtime_agent.run_result, Agent_core.Error.t) result

val observe_checkpoint_stage :
  bool Atomic.t -> Agent_core.Agent.checkpoint_stage -> unit

val checkpoint_allows_candidate_transition : bool Atomic.t -> bool

val attempt_stalled :
  now:float
  -> threshold_sec:float
  -> attempt_started_at:float
  -> sample:provider_progress_sample option
  -> bool
(** The stall verdict for a running provider attempt (#28417), pure in its
    inputs so it is testable without Eio or a registry.

    With a [sample], the attempt is stalled when no tool is in flight AND the
    last progress signal is older than [threshold_sec]. A tool call that runs
    for minutes refreshes no progress signal while it runs, so tools in
    flight count as work.

    With [sample = None] (probe absent, or no live turn observation), the
    verdict falls back to elapsed time since [attempt_started_at] — the
    pre-#28417 behaviour, so a lost progress signal cannot silently disable
    enforcement. *)

val run_try_provider :
  try_provider_ctx ->
  ?enable_thinking_override:bool ->
  Runtime_candidate.t ->
  (Runtime_agent.run_result, Agent_core.Error.t) result
  * Agent_core.Checkpoint.t option
  * (string * Obj.t) option

val accept_rejected_error :
  runtime_id:string ->
  response:Agent_core.Types.api_response ->
  Agent_core.Error.t

module For_testing : sig
  val apply_accept :
    runtime_id:string ->
    accept:(Agent_core.Types.api_response -> bool) ->
    Runtime_agent.run_result ->
    (Runtime_agent.run_result, Agent_core.Error.t) result

  val observe_request_wire_error :
    runtime_id:string ->
    max_request_body_bytes:int ->
    on_request_wire_observation:
      (runtime_id:string ->
       max_request_body_bytes:int ->
       body_bytes:int ->
       unit)
        option ->
    Agent_core.Error.t ->
    unit

  val memoize_message_measurement :
    (Agent_core.Types.message -> int) -> Agent_core.Types.message -> int

  val plan_and_window_model_input :
    measure_message_bytes:(Agent_core.Types.message -> int) ->
    capacity_bytes:int ->
    reserved_bytes:int ->
    base_path:string ->
    demote_before:int ->
    Agent_core.Types.message list ->
    (Keeper_model_input_demotion.plan_result
     * Runtime_model_input_tail_window.projection
     * int,
     Runtime_model_input_tail_window.budget_error)
    result

  val offload_model_input_cpu : (unit -> 'a) -> 'a

end
