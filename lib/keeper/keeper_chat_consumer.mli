(** Keeper_chat_consumer — standalone polling fiber for queue drain.

    Polls all keeper queues at a configurable interval and initiates
    turn processing for queued messages via a user-provided callback.

    This decouples queue consumption from the HTTP request lifecycle,
    enabling external connectors (Discord, Slack) to enqueue messages
    that will be auto-drained without requiring a Dashboard HTTP request.

    @since 2.145.0 *)

(** [start ~sw ~clock ~base_path ~handle_turn] begins a background fiber
    that polls [Keeper_chat_queue] every [MASC_KEEPER_QUEUE_POLL_SEC]
    seconds (default 1.0).

    Per keeper and per tick: when a turn is in flight
    ([Keeper_turn_admission.in_flight]), queued messages are left to
    accumulate; once the slot is free, the head run of same-source
    messages is drained ([Keeper_chat_queue.dequeue_batch]) and merged
    into ONE coalesced message ([Keeper_chat_queue.merge_batch]).  The
    merged turn then runs in a keeper-scoped child fiber, so a slow queued
    turn for one keeper does not block polling or delivery for other
    keepers.  A keeper-local dispatch gate preserves the single follow-up
    turn contract for messages sent during an existing queued turn.

    The fiber runs until [sw] is released.

    [handle_turn] is responsible for creating an event stream,
    spawning the appropriate delivery adapter, and calling
    [process_single_turn].  See RFC-0217 §Phase 3. *)
val start :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  base_path:string ->
  handle_turn:(sw:Eio.Switch.t -> keeper_name:string -> queued_message:Keeper_chat_queue.queued_message -> unit) ->
  unit
