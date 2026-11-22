open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

type grpc_heartbeat_starter_fn = {
  f : 'a. ctx:'a context -> m:keeper_meta -> stop:bool Atomic.t -> (unit -> unit) option;
}

val grpc_heartbeat_starter : ctx:'a context -> m:keeper_meta -> stop:bool Atomic.t -> (unit -> unit) option

val register_grpc_heartbeat_starter : grpc_heartbeat_starter_fn -> unit

val record_tool_skipped : tool_name:string -> reason_code:string -> unit

val register_record_tool_skipped :
  (tool_name:string -> reason_code:string -> unit) ->
  unit

val record_execute_output :
  keeper_name:string ->
  task_id:string option ->
  stdout:string ->
  stderr:string ->
  status:Yojson.Safe.t ->
  streamed:bool ->
  unit

val register_record_execute_output :
  (keeper_name:string ->
   task_id:string option ->
   stdout:string ->
   stderr:string ->
   status:Yojson.Safe.t ->
   streamed:bool ->
   unit) ->
  unit

val record_execute_stream_chunk :
  keeper_name:string -> stream_id:int -> stream:[ `Stdout | `Stderr ] -> string -> unit

val register_record_execute_stream_chunk :
  (keeper_name:string -> stream_id:int -> stream:[ `Stdout | `Stderr ] -> string -> unit) ->
  unit

val record_execute_stream_start :
  keeper_name:string -> stream_id:int -> task_id:string option -> command:string -> unit

val register_record_execute_stream_start :
  (keeper_name:string -> stream_id:int -> task_id:string option -> command:string -> unit) ->
  unit

val record_execute_stream_end :
  keeper_name:string -> stream_id:int -> task_id:string option -> status:Yojson.Safe.t -> unit

val register_record_execute_stream_end :
  (keeper_name:string -> stream_id:int -> task_id:string option -> status:Yojson.Safe.t -> unit) ->
  unit

(** FSM guard identity helpers (Cycle 43).
    Wrapped by [Keeper_fsm_guard_runtime.wrap_unit] at call sites. *)
val pre_turn_complete_heartbeat : turn_running:bool ref -> unit
val post_turn_complete_heartbeat : turn_running:bool ref -> unit
val post_wakeup_signal : wakeup:bool Atomic.t -> unit
val post_submit_task : meta:keeper_meta -> task_id:Keeper_id.Task_id.t -> unit

(** Outcome of an [interruptible_sleep] call. Mirrors the three terminal
    branches of the polling loop, so callers can distinguish an exact Keeper
    wake from the configured heartbeat cadence. *)
type sleep_outcome =
  | Stopped   (** [stop] atomic was observed [true] before the duration
                  elapsed. *)
  | Woken     (** [wakeup] transitioned [true -> false], or an active
                  [cadence_sleeping] handshake was consumed by a cadence
                  update; the caller should dispatch the next cycle. *)
  | Timeout   (** Full [duration] elapsed without [stop] or [wakeup]. *)

(** Whether a wakeup may end the sleep before its duration elapses.
    [Interrupt_on_wakeup] is the heartbeat default. Under
    [Serve_wakeup_after_duration] a wakeup raised during the sleep is consumed
    when the duration ends, so the tick happens once per signal, only later;
    [stop] ends either policy at once. Used for the provider backoff after a
    rate-limited or exhausted turn, where waking sooner only re-runs the same
    failing call (#34653). *)
type wake_policy =
  | Interrupt_on_wakeup
  | Serve_wakeup_after_duration

(** Sleep in short chunks so [stop_keepalive] or [wakeup_keeper] takes
    effect within ~chunk_sec instead of waiting for the full interval. *)
val interruptible_sleep :
  ?cadence_sleeping:bool Atomic.t ->
  ?on_cadence_sleeping_changed:(unit -> unit) ->
  ?wake_policy:wake_policy ->
  ?interrupt_when:(unit -> bool) ->
  clock:'a Eio.Time.clock ->
  stop:bool Atomic.t ->
  wakeup:bool Atomic.t ->
  (unit -> float) ->
  sleep_outcome
(** When [cadence_sleeping] is supplied, it is [true] only inside this sleep.
    [on_cadence_sleeping_changed] records non-yielding metadata after an actual
    handshake transition, including cancellation cleanup. Callback failures
    cannot replace the sleep/cleanup result and are counted separately.
    A runtime cadence decrease consumes it with CAS, avoiding a queued wake
    during active cycle setup and closing both the duration-resolution and
    timeout-edge races. [duration] is resolved only after the handshake is
    visible. [interrupt_when], when supplied, revalidates the dependency of
    the wait at each existing sleep boundary. A true result returns [Woken]
    even under [Serve_wakeup_after_duration]; ordinary stimulus/cadence hints
    still cannot interrupt that policy. [stop] has precedence. *)

val failed_cadence_notifications : unit -> int
(** Exceptions raised by cadence metadata observers; reads do not notify. *)

(** Wake up a specific keeper immediately.

    When [?stimulus] is given, the stimulus is durably appended to the keeper's
    Event Layer queue ([Keeper_registry_event_queue.enqueue]) independently of
    lifecycle phase. The wake hint is sent only to a lifecycle-admitted Running
    Keeper; inactive and paused lanes retain the durable event without a
    false delivery claim. If no live registry entry exists, callers
    must supply [base_path] so the payload can be persisted for replay. Callers
    that only need to break the keeper out of [interruptible_sleep] may omit the
    stimulus. *)
val wakeup_keeper :
  ?base_path:string ->
  ?stimulus:Keeper_event_queue.stimulus ->
  string -> unit

val wakeup_relevant_keeper_for_board_signal :
  ?dispatch_attention:(Keeper_board_attention_candidate.candidate list -> unit) ->
  ?dispatch_discoverable_post:(Board_dispatch.board_signal -> unit) ->
  config:Workspace.config -> Board_dispatch.addressed_board_signal -> unit
(** Route typed immediate audiences to durable Keeper stimulus queues.
    [dispatch_discoverable_post] reserves and asynchronously admits normal
    discoverable posts to one event batch. Owners retain durable cursor catchup.
    Without that callback, established owners use their cursor and only initial
    cursor fallbacks persist on the producer fiber. *)

(** Per-stage timing accumulator for Phase 0 profiling. *)
type stage_timing = {
  presence_ms : float;
  snapshot_ms : float;
  board_ms : float;
  turn_ms : float;
}

val stage_timing_ring_size : unit -> int

val percentile : float array -> float -> float

val stage_timing_to_json :
  ring:stage_timing array -> count:int ->
  [> `Null
  | `Assoc of
      (string *
       [> `Assoc of (string * [> `Float of float | `Int of int ]) list ])
      list
  ]

val format_since_last_scheduled_autonomous : int option -> string

val dispatch_keepalive_event :
  ctx:'a context -> keeper_name:string ->
  Keeper_state_machine.event -> unit


type periodic_cadence = Initial_due of float | After_periodic of float
val periodic_remaining : now:float -> interval:float -> periodic_cadence -> float
val periodic_is_due : now:float -> interval:float -> periodic_cadence -> bool
val consume_periodic : now:float -> periodic_cadence

(** {1 Unified Reactive/Proactive Wake Policy & Queue Circulation} *)

(** Typed sender authority driving producer-selected wake timing. *)
type sender_kind =
  | Human_sender
  | Connector_sender
  | Keeper_sender
  | Own_async_sender
  | System_sender

(** Closed classification of Keeper inbound stimuli. *)
type input_kind =
  | Direct_message
  | Board_mention_or_reply
  | Board_broadcast
  | Board_reaction_or_vote
  | Board_attention_ambient
  | Delegate_completion
  | Own_async_completion
  | Task_cancelled_or_rejected
  | Task_outcome_approved
  | Scheduled_wake
  | Workspace_broadcast

(** Producer-selected wake policy (#54342):
    - [Now]: wake immediately (or steer if a turn is already active).
    - [At_tick]: coalesce onto the Keeper's deterministic staggered tick grid.
    - [Carry]: durably queue to ride the next reactive or spontaneous turn
      without forcing an extra wakeup. *)
type stimulus_wake_policy =
  | Now
  | At_tick
  | Carry

type inbound_queue_mode = Keeper_arrived_stimuli.inbound_queue_mode =
  | Steer
  | FollowUp
  | Coalesce

(** Adaptive spontaneous idle backoff ladder (30m -> 1h -> 2h). *)
type idle_backoff_stage =
  | Idle_30m
  | Idle_1h
  | Idle_2h

(** Whether a reaction turn ran since the last self-wake. The next self-wake
    reads it: after a reaction the interval stays at the start, after none it
    doubles up to the cap (RFC keeper-reaction-and-queue §4.4). *)
type idle_activity =
  | Quiet_since_self_wake
  | Reacted_since_self_wake

type adaptive_idle_state =
  { stage : idle_backoff_stage
  ; next_spontaneous_at : float
  ; since_self_wake : idle_activity
  }

val default_stagger_tick_sec : float
val adaptive_idle_30m_sec : float
val adaptive_idle_1h_sec : float
val adaptive_idle_2h_sec : float

val stimulus_wake_policy_of :
  input_kind:input_kind -> sender_kind:sender_kind -> stimulus_wake_policy

val urgency_of_stimulus_wake_policy :
  stimulus_wake_policy -> Keeper_event_queue.urgency

val inbound_queue_mode_of :
  turn_running:bool ->
  wake_policy:stimulus_wake_policy ->
  sender_kind:sender_kind ->
  inbound_queue_mode

val stagger_offset_sec : keeper_name:string -> tick_interval_sec:float -> float
val next_staggered_tick :
  now:float -> keeper_name:string -> tick_interval_sec:float -> float

val notify_at_tick_pending :
  base_path:string ->
  keeper_name:string ->
  ?tick_interval_sec:float ->
  now:float ->
  unit ->
  unit
(** Record an in-memory staggered-tick deadline for a Keeper when an [At_tick]
    stimulus arrives so a long adaptive-idle sleep wakes at [next_staggered_tick]
    without disk polling or an immediate wake storm. *)

val at_tick_deadline_opt : base_path:string -> keeper_name:string -> float option
val at_tick_due : base_path:string -> keeper_name:string -> now:float -> bool
val clear_at_tick_pending : base_path:string -> keeper_name:string -> unit

val idle_backoff_duration : idle_backoff_stage -> float
val adaptive_idle_interval :
  base_interval_sec:float -> idle_backoff_stage -> float

val adaptive_idle_init : now:float -> warmup_sec:float -> adaptive_idle_state
val adaptive_idle_after_self_wake :
  ?base_interval_sec:float -> now:float -> adaptive_idle_state -> adaptive_idle_state
(** A self-wake served the due boundary. The stage returns to [Idle_30m] when a
    reaction ran since the previous self-wake, and otherwise advances one step
    up to [Idle_2h]. The turn's result does not matter: a failed self-wake
    backs off the same way. *)

val adaptive_idle_after_served_boundary :
  ?base_interval_sec:float -> now:float -> unit -> adaptive_idle_state
(** A turn other than a self-wake served the due boundary: a completed due
    schedule (#54338) or a reaction cycle that opened at the boundary. The
    stage returns to [Idle_30m] and the next self-wake is one start interval
    after [now]. *)

val adaptive_idle_pull_in_on_reactive :
  ?base_interval_sec:float -> now:float -> adaptive_idle_state -> adaptive_idle_state
(** A reaction cycle off the boundary, whether its turn finished or failed. The
    stage returns to [Idle_30m] and the next self-wake moves to
    [min next_spontaneous_at (now + start)]. It never moves later, so a
    boundary that came due during the reaction is still served. *)
val adaptive_idle_remaining : now:float -> adaptive_idle_state -> float
val adaptive_idle_is_due : now:float -> adaptive_idle_state -> bool

val input_kind_of_stimulus_payload :
  Keeper_event_queue.stimulus_payload -> input_kind
