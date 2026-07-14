(** Keeper_chat_consumer — transition-driven queue drain.

    Consumes typed queue/admission wake transitions and initiates turn
    processing for queued messages via a user-provided callback.

    This decouples queue consumption from the HTTP request lifecycle,
    enabling external connectors (Discord, Slack) to enqueue messages
    that will be auto-drained without requiring a Dashboard HTTP request.

    @since 2.145.0 *)

(** Wake one Keeper lane after a durable queue mutation, admission release, or
    explicit operator reconciliation. Repeated pending wakes for the same
    Keeper are coalesced without a capacity limit; a wake observed while that
    Keeper is running schedules exactly one follow-up inspection. *)
val notify_transition : keeper_name:string -> unit

type persistence_blocked_operation =
  | Lease_next_blocked
  | Finalize_blocked
  | Nack_blocked

type persistence_blocked_status =
  { operation : persistence_blocked_operation
  ; lease_id : string option
  ; error : Keeper_chat_queue.mutation_error
  }

(** Observe the exact Keeper-local queue mutation that is waiting for an
    explicit retry trigger. This is operational state, not a retry timer or an
    admission constraint. *)
val persistence_blocked_status :
  base_path:string ->
  keeper_name:string ->
  (persistence_blocked_status option, string) result

(** A typed outcome from the whole queued-turn delivery boundary. Connector
    adapters must be joined before returning [Delivered]; a persisted failure,
    missing connector, or outbound error returns [Failed]. [Delivered]'s
    [outcome_ref] is required and must be a canonical [Ids.Turn_ref] string;
    the consumer fails closed as [Internal_error] if that invariant is broken. *)
type turn_outcome =
  | Delivered of { outcome_ref : string }
  | Failed of
      { kind : Keeper_chat_queue.failure_kind
      ; detail : string
      ; outcome_ref : string option
      }
  | Deferred of { rejection : Keeper_turn_admission.rejection }

(** [run ~sw ~clock ~base_path ~handle_turn] runs the queue consumer control
    loop and does not return before cancellation. The runtime supervisor owns
    the control-loop fiber, so an exception is observed by that subsystem
    boundary instead of escaping through an unobserved child fiber.

    Startup performs one inventory of restored queue lanes. Thereafter the
    consumer is driven only by durable queue transitions, Keeper admission
    release, and explicit operator reconciliation; it performs no fleet-wide
    timer polling.

    Per Keeper wake: when a turn is in flight
    ([Keeper_turn_admission.in_flight]), queued messages are left to
    accumulate; once the slot is free, the exact FIFO head receipt is leased
    ([Keeper_chat_queue.lease_next]) into one typed turn. User-message identity,
    multimodal blocks, transcript provenance, and receipt correlation are never
    flattened into a delimiter string. The turn then runs in a Keeper-scoped child fiber, so a slow queued turn for one
    keeper does not block wake processing or delivery for other keepers.  A
    keeper-local dispatch gate preserves the single follow-up turn contract
    for messages sent during an existing queued turn.

    [handle_turn]'s typed terminal outcome is durably finalized as [Delivered]
    or [Failed]. [Deferred] and structured cancellation nack the unchanged
    receipt back to [Pending]; [Deferred] is reserved for a typed admission
    rejection such as an active shutdown fence, so the same accepted receipt is
    retried after the lane reopens. A lease found after process restart is
    [Recovery_required] and is never automatically dispatched: an operator must
    explicitly requeue or cancel its exact receipt/revision/lease evidence. An
    unexpected handler exception becomes a durable [Internal_error] failure
    instead of a poison-message retry loop. There is deliberately no second
    wall-clock watchdog: the turn runtime owns timeout/cancellation and must
    return the typed outcome.

    If finalization persistence fails before publication, the exact decision is
    retained and retried before another turn starts after the next durable
    transition or explicit operator reconciliation. External diagnostic text is
    normalized at this terminal boundary. If queue validation still rejects the
    decision, the consumer replaces it with a typed [Internal_error] terminal
    outcome instead of retrying a permanently invalid action forever.

    The call runs until [sw] is released.

    [handle_turn] is responsible for creating an event stream,
    spawning the appropriate delivery adapter, and calling
    [process_single_turn].  See RFC-0217 §Phase 3. *)
val run :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  base_path:string ->
  handle_turn:(sw:Eio.Switch.t -> keeper_name:string -> delivery_key:Keeper_chat_delivery_identity.delivery_key -> queued_message:Keeper_chat_queue.queued_message -> turn_outcome) ->
  unit

module For_testing : sig
  type dispatch_state

  val create_dispatch_state : base_path:string -> dispatch_state
  val is_dispatching : dispatch_state -> string -> bool
  val mark_dispatching : dispatch_state -> string -> bool
  val clear_dispatching : dispatch_state -> string -> unit
  val finish_dispatching_and_reschedule : dispatch_state -> string -> unit
  val notify_transition : keeper_name:string -> unit
  val take_wake_nonblocking : unit -> string option
  val reset_wake_inbox : unit -> unit
  val reset_persistence_blocked : unit -> unit
end
