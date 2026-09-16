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
  ; max_request_body_bytes : int option
  ; context_marks : Runtime_schema.context_marks option
        (** The marks the carried range is judged against after each
            response (RFC keeper-context-window-in-tokens §10.5), as the
            binding declares them; [None] leaves eviction to a refusal.
            [max_request_body_bytes] judges the serialized request only. *)
  ; carried_front_seed : unit -> Keeper_carried_front.seed option
        (** Where the carried range starts when no ledger holds this
            (keeper, runtime) pair yet: the range the newest completed turn
            record on the runtime measured. Read once per attempt, on that
            path only. *)
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
  ; recovery_view : Keeper_recovery_transmission.t option
  ; stream_idle_timeout_s : float
  ; first_event_timeout_s : float
  ; body_timeout_s : float option
  ; provider_call_deadline_sec : float
        (** Seconds a provider attempt may go WITHOUT a progress signal
            before it is cancelled and rotated (#28417 changed this from a
            total-elapsed ceiling). Always set: the operator's value or the
            resolved layer's failsafe floor. *)
  ; provider_progress_probe : (unit -> provider_progress_sample option) option
        (** Reads the keeper's live progress signal. Must not raise; return
            [None] when unavailable, which degrades the deadline to the
            pre-#28417 elapsed ceiling. *)
  ; person_queued_probe : (unit -> bool) option
        (** Reads whether a person's chat operation is queued behind this turn.
            Present only on the autonomous lane; [None] disables first-token-wait
            preemption (RFC-0441 pre-first-token gap). Must not raise. *)
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
       max_request_body_bytes:int option ->
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

type provider_lease_phase =
  | Provider_active_since of float
  | Provider_yielded
(** Invocation-local main-provider lease observation, not tool completion or
    a persisted lifecycle state. *)

val provider_lease_stalled :
  lease_phase:provider_lease_phase
  -> now:float
  -> threshold_sec:float
  -> attempt_started_at:float
  -> permit_wait:Llm_provider.Provider_admission.permit_wait
  -> sample:provider_progress_sample option
  -> bool
(** A yielded main-provider lease cannot be stalled. On reacquisition, the
    no-progress window starts no earlier than that reacquisition, including
    when the asynchronous registry sample is absent or stale. *)

val attempt_stalled :
  now:float
  -> threshold_sec:float
  -> attempt_started_at:float
  -> permit_wait:Llm_provider.Provider_admission.permit_wait
  -> sample:provider_progress_sample option
  -> bool
(** The stall verdict for a running provider attempt (#28417), pure in its
    inputs so it is testable without Eio or a registry.

    Never stalled while [permit_wait] is [Waiting_for_permit]: a bounded wait
    for the binding's admission permit is queueing with a deadline of its
    own, and Agent Core writes the cell for no other kind of wait, so
    standing down for it leaves nothing unbounded and lets the admission
    bound alone end it, as [Queue]. [Wait_settled_at] is the instant that
    wait ended, and the verdict counts from it: the attempt's own budgets
    start there, so the silence that is a stall is the silence after it.

    With a [sample], the attempt is stalled when no tool is in flight AND the
    last progress signal is older than [threshold_sec]. A tool call that runs
    for minutes refreshes no progress signal while it runs, so tools in
    flight count as work.

    With [sample = None] (probe absent, or no live turn observation), the
    verdict falls back to elapsed time since [attempt_started_at] — the
    pre-#28417 behaviour, so a lost progress signal cannot silently disable
    enforcement. *)

val preempt_pre_first_token : first_event_seen:bool -> person_queued:bool -> bool
(** First-token-wait preemption verdict (RFC-0441 pre-first-token gap), pure in
    its inputs. [true] only when the provider has produced no streaming event
    yet ([not first_event_seen]) and a person's chat operation is queued. Once
    the first event arrives the tool-boundary yield owns the handover, so this
    is [false]; with no one queued it is [false] and the attempt keeps its full
    first-event/idle bounds. *)

val default_context_overflow_shrink_capacity : capacity:int -> int
(** The shared provider-oracle target for one ordinary shrink step. The
    runtime-specific caller may clamp this target further to structural
    message boundaries. *)

val context_overflow_shrink_sequence :
  ?shrink_capacity:
    (capacity:int -> default_capacity:int -> int) ->
  ?final_shrink_capacity:(capacity:int -> int option) ->
  starting_capacity:int ->
  same_run_retry_authorized:(unit -> bool) ->
  shrink_admits_history:(capacity:int -> bool) ->
  record_success:(capacity:int -> unit) ->
  on_shrink_retry:
    (shrink_attempt:int ->
     previous_capacity:int ->
     capacity:int ->
     unit) ->
  attempt:(capacity:int -> ('ok, Agent_core.Error.t) result) ->
  unit ->
  ('ok, Agent_core.Error.t) result
(** Provider-oracle retry policy of the official-client runtimes, whose
    seed history is cut against a declared prompt byte cap; the capacity is
    in bytes. The Agent Core lane answers the same refusal by moving its
    carried front ({!run_try_provider_with_carried_range_eviction}).
    [default_capacity] is the policy's ordinary halved value;
    a custom [shrink_capacity] can replace only exceptional starting values
    without copying the shared divisor. The walk carries no attempt count:
    it ends where no strictly smaller view exists. [final_shrink_capacity]
    names a measured structural floor; once the ordinary target would reach
    or pass it, the floor itself is attempted, and its refusal ends the
    sequence. A custom value that does not strictly decrease
    [capacity] terminates the sequence without another provider attempt.

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

type eviction_retry =
  | Evicted_blocks of Keeper_carried_range.step
      (** The oldest blocks of the pair's ledger left. *)
  | Halved_range of
      { first_atom : int
      ; atom_count : int
      }
      (** No block structure to walk: the range halved toward the newest
          atom. *)
  | Demoted_newest_atom
      (** The newest atom alone was refused: #28845's demotion of the turn's
          own tool results was armed for one more request. *)

val carried_range_eviction_sequence :
  same_run_retry_authorized:(unit -> bool) ->
  ledger:(unit -> Keeper_model_input_ledger.t option) ->
  last_request:(unit -> Keeper_model_input_ledger.request option) ->
  marks:Runtime_schema.context_marks option ->
  evict:(Keeper_carried_range.step -> unit) ->
  halve:(first_atom:int -> atom_count:int -> retry:int -> unit) ->
  last_resort:(retry:int -> bool) ->
  on_retry:(retry:int -> eviction_retry -> unit) ->
  attempt:(unit -> ('ok, Agent_core.Error.t) result) ->
  unit ->
  ('ok, Agent_core.Error.t) result
(** The Agent Core lane's retry policy over an injected [attempt] (RFC
    keeper-context-window-in-tokens §10.5). A provider context overflow or a
    size refusal on the byte axis is answered from the pair's ledger with
    {!Keeper_carried_range.after_overflow}; [evict] applies the step before
    the next attempt. When the ledger has no block structure to walk, no
    usage counted yet or a single block, [last_request]'s range halves
    toward the newest atom through [halve]; at a single atom [last_resort]
    may arm one more request with the turn's own tool results demoted
    (#28845), and answers [false] once used or with nothing to demote, which
    ends the sequence with the refusal in hand. Every other error ends it at
    once, as does a refusal once [same_run_retry_authorized] is [false]. *)

val run_try_provider_with_carried_range_eviction :
  ?continuation_checkpoint:Agent_core.Checkpoint.t ->
  try_provider_ctx ->
  Runtime_candidate.t ->
  (Runtime_agent.run_result, Agent_core.Error.t) result
  * Agent_core.Checkpoint.t option
  * (string * Obj.t) option
(** {!run_try_provider} under {!carried_range_eviction_sequence}: the
    eviction moves the pair's ledger front, the halving holds a seed for the
    rest of this attempt, and each retry is recorded on the runtime
    manifest. *)

val run_try_provider_with_truncation_recovery :
  ?continuation_checkpoint:Agent_core.Checkpoint.t ->
  try_provider_ctx ->
  Runtime_candidate.t ->
  (Runtime_agent.run_result, Agent_core.Error.t) result
  * Agent_core.Checkpoint.t option
  * (string * Obj.t) option
(** Run the carried-range eviction first. When the accepted
    boundary instead reports a typed [MaxTokens] truncation, remove only that
    incomplete Assistant message from the post-run checkpoint and continue the
    same candidate once with thinking disabled. No new User message is added,
    so already-recorded tool results remain the continuation authority. *)

val accept_rejected_error :
  runtime_id:string ->
  response:Agent_core.Types.api_response ->
  Agent_core.Error.t

type composed =
  { planned : Keeper_model_input_demotion.plan_result
  ; projection : Runtime_model_input_tail_window.projection
  ; transmitted_bytes : int
        (** Pinned messages, the carried atoms and the preamble, as the
            composition's encoder counts them; excludes the reservation. *)
  ; history_atom_count : int  (** Atoms in the whole history. *)
  ; origin : Keeper_carried_front.origin
  ; outlived_seed : Keeper_carried_front.seed option
        (** A front the history shrank under, dropped by
            {!Keeper_carried_front.for_history}; the request started over. *)
  }
(** One request as {!For_testing.compose_carried_model_input} composes it
    (RFC keeper-context-window-in-tokens §10.4): RFC-0363 demotion over the
    atoms older than [demote_before], or over every atom when the last
    resort is armed, then the carried range from [front]; the whole history
    without one. Nothing here measures the request against a limit. *)

module For_testing : sig
  val observe_provider_lease :
    now:(unit -> float) -> on_yield:(unit -> unit) option ->
    on_resume:(unit -> unit) option ->
    provider_lease_phase Atomic.t * (unit -> unit) * (unit -> unit)

  val checkpoint_before_incomplete_response :
    Agent_core.Checkpoint.t -> Agent_core.Checkpoint.t option

  val max_tokens_truncation_error : Agent_core.Error.t -> bool

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

  (** The candidate a no-thinking truncation retry dispatches to: identical
      but for [reasoning_effort = None], because the wires that admit effort
      reject it with thinking disabled. *)
  val candidate_without_reasoning_effort : Runtime_candidate.t -> Runtime_candidate.t

  val apply_accept :
    runtime_id:string ->
    accept:(Agent_core.Types.api_response -> bool) ->
    Runtime_agent.run_result ->
    (Runtime_agent.run_result, Agent_core.Error.t) result

  val observe_request_wire_error :
    runtime_id:string ->
    max_request_body_bytes:int option ->
    on_request_wire_observation:
      (runtime_id:string ->
       max_request_body_bytes:int option ->
       body_bytes:int ->
       serialized:Llm_provider.Request_wire_observer.observation option ->
       unit)
        option ->
    Agent_core.Error.t ->
    unit

  val message_measurer : unit -> Agent_core.Types.message -> int
  (** Counts the bytes [Yojson.Safe.to_string] would produce, without building
      the string. Each call returns a measurer with its own buffer. *)

  val memoize_message_measurement :
    (Agent_core.Types.message -> int) -> Agent_core.Types.message -> int

  val message_measurement_hash : Agent_core.Types.message -> int

  val compose_carried_model_input :
    measure_message_bytes:(Agent_core.Types.message -> int) ->
    front:Keeper_carried_front.seed option ->
    last_resort:bool ->
    base_path:string ->
    demote_before:int ->
    Agent_core.Types.message list ->
    composed

  val last_resort_demotes :
    measure_message_bytes:(Agent_core.Types.message -> int) ->
    base_path:string ->
    Agent_core.Types.message list ->
    bool
  (** Whether the current turn's own atoms carry a tool result the store
      could hold: what arming the last resort would change. *)

  val offload_model_input_cpu : (unit -> 'a) -> 'a

end
