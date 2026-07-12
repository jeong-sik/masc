(** Keeper_chat_consumer — standalone polling fiber for queue drain.

    Polls all keeper queues at a configurable interval and initiates
    turn processing for queued messages via a user-provided callback.

    This decouples queue consumption from the HTTP request lifecycle,
    enabling external connectors (Discord, Slack) to enqueue messages
    that will be auto-drained without requiring a Dashboard HTTP request.

    @since 2.145.0 *)

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

(** [start ~sw ~clock ~base_path ~handle_turn] begins a background fiber that polls [Keeper_chat_queue]
    every [MASC_KEEPER_QUEUE_POLL_SEC] seconds (default 1.0).

    Per keeper and per tick: when a turn is in flight
    ([Keeper_turn_admission.in_flight]), queued messages are left to
    accumulate; once the slot is free, the head run of same-source messages
    is leased ([Keeper_chat_queue.lease_batch]) and merged into ONE
    coalesced message ([Keeper_chat_queue.merge_batch]).  The merged turn
    then runs in a keeper-scoped child fiber, so a slow queued turn for one
    keeper does not block polling or delivery for other keepers.  A
    keeper-local dispatch gate preserves the single follow-up turn contract
    for messages sent during an existing queued turn.

    Delivery is at-least-once. [handle_turn]'s typed terminal outcome is durably
    finalized as [Delivered] or [Failed]. [Deferred] and structured cancellation
    nack the unchanged receipt back to [Pending]; [Deferred] is reserved for a
    typed admission rejection such as an active shutdown fence, so the same
    accepted receipt is retried after the lane reopens. An unexpected handler
    exception becomes a durable [Internal_error] failure instead of a
    poison-message retry loop. There is deliberately no second wall-clock
    watchdog: the turn runtime owns timeout/cancellation and must return the
    typed outcome.

    If finalization persistence fails, the exact decision is retained and
    retried before another turn starts; a transient filesystem error cannot
    leave the lane stuck behind an outstanding lease. External diagnostic text
    is normalized at this terminal boundary. If queue validation still rejects
    the decision, the consumer replaces it with a typed [Internal_error]
    terminal outcome instead of retrying a permanently invalid action forever.

    The fiber runs until [sw] is released.

    [handle_turn] is responsible for creating an event stream,
    spawning the appropriate delivery adapter, and calling
    [process_single_turn].  See RFC-0217 §Phase 3. *)
val start :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  base_path:string ->
  handle_turn:(sw:Eio.Switch.t -> keeper_name:string -> queued_message:Keeper_chat_queue.queued_message -> leased_items:Keeper_chat_queue.leased_message list -> turn_outcome) ->
  unit

module For_testing : sig
  type dispatch_state

  val create_dispatch_state : unit -> dispatch_state
  val is_dispatching : dispatch_state -> string -> bool
  val mark_dispatching : dispatch_state -> string -> bool
  val clear_dispatching : dispatch_state -> string -> unit
end
