(** Keeper_chat_consumer — standalone polling fiber for queue drain.

    Polls all keeper queues at a configurable interval and initiates
    turn processing for queued messages via a user-provided callback.

    This decouples queue consumption from the HTTP request lifecycle,
    enabling external connectors (Discord, Slack) to enqueue messages
    that will be auto-drained without requiring a Dashboard HTTP request.

    @since 2.145.0 *)

(** [start ~sw ~clock ~handle_turn ()] begins a background fiber that
    polls [Keeper_chat_queue] every [MASC_KEEPER_QUEUE_POLL_SEC] seconds
    (default 1.0) and calls [handle_turn] for each queued message.

    The fiber runs until [sw] is released.

    [handle_turn] is responsible for creating an event stream,
    spawning the appropriate delivery adapter, and calling
    [process_single_turn].  See RFC-0217 §Phase 3. *)
val start :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  handle_turn:(keeper_name:string -> queued_message:Keeper_chat_queue.queued_message -> unit) ->
  unit
