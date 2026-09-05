(** Extracted provider-attempt runner for keeper runtime turns. *)

(** A reading of the keeper's live in-turn progress signal (#28417).

    What the stall decision needs, read by the caller so this module decides
    without depending on [Keeper_registry] or on the approval registry. *)
type provider_progress_sample =
  { last_progress_at : float
        (** Unix timestamp of the most recent in-turn progress signal. *)
  ; active_tool_count : int
        (** Tools issued but not yet completed; non-zero means work in
            flight, not a stall. *)
  ; awaiting_approval : bool
        (** Whether a call from this keeper is parked at the approval gate.

            Held calls raise neither signal above: the gate runs at
            [pre_tool_use] and the event that raises [active_tool_count] is
            published after it. So a keeper waiting on a person reads as a
            provider that stopped answering, and the attempt is cancelled and
            filed against the provider. The wait carries its own bound, so
            excluding it here leaves nothing unbounded. *)
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
  ; approval_gate : Keeper_tool_approval_gate.t option
        (** Holds a tool call for an operator before it runs. Absent means no
            call is held, which is what an autonomous turn wants: nobody is
            watching it to answer. *)
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
       serialized:Llm_provider.Request_wire_observer.observation option ->
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

val same_run_retry_allowed : bool Atomic.t -> bool

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

val default_context_overflow_shrink_capacity : capacity_bytes:int -> int
(** The shared provider-oracle target for one ordinary shrink step. The
    runtime-specific caller may clamp this target further to structural
    message boundaries. *)

val context_overflow_shrink_sequence :
  ?shrink_capacity:
    (capacity_bytes:int -> default_capacity_bytes:int -> int) ->
  ?final_shrink_capacity:(capacity_bytes:int -> int option) ->
  starting_capacity_bytes:int ->
  same_run_retry_authorized:(unit -> bool) ->
  shrink_admits_history:(capacity_bytes:int -> bool) ->
  record_success:(capacity_bytes:int -> unit) ->
  on_shrink_retry:
    (shrink_attempt:int ->
     previous_capacity_bytes:int ->
     capacity_bytes:int ->
     unit) ->
  attempt:(capacity_bytes:int -> ('ok, Agent_core.Error.t) result) ->
  unit ->
  ('ok, Agent_core.Error.t) result
(** Provider-oracle retry policy shared by AGENT_CORE and official-client
    runtimes. [default_capacity_bytes] is the policy's ordinary halved value;
    a custom [shrink_capacity] can replace only exceptional starting values
    without copying the shared divisor. The walk carries no attempt count:
    it ends where no strictly smaller view exists. [final_shrink_capacity]
    names a measured structural floor; once the ordinary target would reach
    or pass it, the floor itself is attempted, and its refusal ends the
    sequence. A custom value that does not strictly decrease
    [capacity_bytes] terminates the sequence without another provider attempt.

    [shrink_admits_history] answers whether a proposed capacity leaves room
    for any conversation history once the caller's non-history reserve is
    charged. A [false] verdict terminates the sequence with the failure in
    hand rather than spending an attempt on a size that cannot succeed: the
    reserve does not shrink with the capacity, so a smaller window refuses
    for the same reason, one size lower. *)

val run_try_provider :
  ?continuation_checkpoint:Agent_core.Checkpoint.t ->
  try_provider_ctx ->
  Runtime_candidate.t ->
  (Runtime_agent.run_result, Agent_core.Error.t) result
  * Agent_core.Checkpoint.t option
  * (string * Obj.t) option

val run_try_provider_with_context_overflow_shrink :
  try_provider_ctx ->
  Runtime_candidate.t ->
  (Runtime_agent.run_result, Agent_core.Error.t) result
  * Agent_core.Checkpoint.t option
  * (string * Obj.t) option

val run_try_provider_with_truncation_recovery :
  try_provider_ctx ->
  Runtime_candidate.t ->
  (Runtime_agent.run_result, Agent_core.Error.t) result
  * Agent_core.Checkpoint.t option
  * (string * Obj.t) option
(** Run the ordinary context-overflow recovery first. When the accepted
    boundary instead reports a typed [MaxTokens] truncation, remove only that
    incomplete Assistant message from the post-run checkpoint and continue the
    same candidate once with thinking disabled. No new User message is added,
    so already-recorded tool results remain the continuation authority. *)

val accept_rejected_error :
  runtime_id:string ->
  response:Agent_core.Types.api_response ->
  Agent_core.Error.t

module For_testing : sig
  val checkpoint_before_incomplete_response :
    Agent_core.Checkpoint.t -> Agent_core.Checkpoint.t option

  val max_tokens_truncation_error : Agent_core.Error.t -> bool
  val thinking_was_enabled : bool option -> bool

  (** What a max-tokens rejection owes the checkpoint. Retrying without
      thinking is a remedy for a budget spent thinking and applies only when
      thinking was on; dropping the rejected response is owed either way,
      because accept judged it unusable and a checkpoint that keeps it feeds
      it back as input on every later turn. *)
  type truncation_recovery =
    | Recovery_not_applicable
    | Retry_without_thinking of Agent_core.Checkpoint.t
    | Drop_rejected_response of Agent_core.Checkpoint.t

  val truncation_recovery :
    enable_thinking:bool option ->
    result:(Runtime_agent.run_result, Agent_core.Error.t) result ->
    checkpoint:Agent_core.Checkpoint.t option ->
    truncation_recovery

  (** Write the cut checkpoint through the keeper's sink under
      [After_rejected_response_dropped]; [Ok ()] with no sink. *)
  val persist_dropped_response
    :  checkpoint_sink:Agent_core.Agent.checkpoint_sink option
    -> now:float
    -> Agent_core.Checkpoint.t
    -> (unit, string) result

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
       serialized:Llm_provider.Request_wire_observer.observation option ->
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
