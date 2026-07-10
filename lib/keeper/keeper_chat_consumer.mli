(** Keeper_chat_consumer — standalone polling fiber for queue drain.

    Polls all keeper queues at a configurable interval and initiates
    turn processing for queued messages via a user-provided callback.

    This decouples queue consumption from the HTTP request lifecycle,
    enabling external connectors (Discord, Slack) to enqueue messages
    that will be auto-drained without requiring a Dashboard HTTP request.

    @since 2.145.0 *)

(** [start ~sw ~clock ~base_path ~dispatch_deadline_sec ~handle_turn
    ~on_stalled] begins a background fiber that polls [Keeper_chat_queue]
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

    Delivery is at-least-once: the lease is acked only once [handle_turn]
    returns without raising, nacked (returned to the head of the queue) on
    any other exception including {!Eio.Cancel.Cancelled} from outside this
    fiber. [handle_turn] is raced against [dispatch_deadline_sec]; if it has
    not returned by then, [handle_turn]'s fiber is cancelled, [on_stalled] is
    called to durably record that the queued message was never answered
    (its own failure does not raise — a failed [on_stalled] still nacks so
    the batch is retried instead of silently vanishing), and the lease is
    acked (the stall itself is now the durable, visible answer, so retrying
    would re-run a turn [Keeper_msg_async]'s own internal timeout has
    already given up on). [dispatch_deadline_sec] should exceed the turn
    execution timeout [handle_turn] itself enforces, with margin: it exists
    to bound how long a *misbehaving* [handle_turn] can wedge this keeper's
    queue, not to race the turn's own timeout. If the durable ack/nack rewrite
    fails, the typed finalization decision is retained for the next poll and
    retried before another turn starts; a transient persistence error therefore
    cannot leave this keeper permanently stuck behind [Already_leased].

    The fiber runs until [sw] is released.

    [handle_turn] is responsible for creating an event stream,
    spawning the appropriate delivery adapter, and calling
    [process_single_turn].  See RFC-0217 §Phase 3. *)
val start :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  base_path:string ->
  dispatch_deadline_sec:float ->
  handle_turn:(sw:Eio.Switch.t -> keeper_name:string -> queued_message:Keeper_chat_queue.queued_message -> unit) ->
  on_stalled:(keeper_name:string -> queued_message:Keeper_chat_queue.queued_message -> unit) ->
  unit

module For_testing : sig
  type dispatch_state

  val create_dispatch_state : unit -> dispatch_state
  val is_dispatching : dispatch_state -> string -> bool
  val mark_dispatching : dispatch_state -> string -> bool
  val clear_dispatching : dispatch_state -> string -> unit
end
