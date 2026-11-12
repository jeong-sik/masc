(** Moves a conversation's wait for a background run's receipt forward when the
    receipt is in the outbox. The wait itself is recorded with the turn's
    checkpoint ({!Keeper_chat_operation_store.defer_direct_checkpoint}); this
    module only reads it back and tells the Owner what arrived. *)

val pending_requests
  :  base_path:string
  -> keeper_name:string
  -> (string list, string) result
(** The requests an unsettled execution of this Keeper still waits for. The
    journal is read without the Owner. An unreadable journal is an [Error],
    not an empty list. *)

val request_may_have_worker : Keeper_msg_async.entry -> bool
(** Whether the request record is in a state where a worker may still write the
    run's receipt. [false] for a request that has ended or been cut off. *)

val arrived : base_path:string -> keeper_name:string -> (unit, string) result
(** For every pending request whose receipt is in the outbox, tells the Owner,
    which moves the wait to arrived and starts a claim when it was the last one
    the execution waited for. A request already arrived, or one no execution
    owns, changes nothing, so a repeated call is safe. Every request is tried
    even when one fails; the error lists the failures. *)

val obligations_of_terminal_effect
  :  Keeper_tool_execution.terminal_effect_receipt option
  -> (Keeper_semantic_execution.receipt_obligation list, string) result
(** The [Pending] entries a turn records when it ends on its terminal effect:
    one per request a wait asked for, in the order asked, and none for a post
    or no terminal effect. The turn passes them to
    {!Keeper_chat_operation_store.defer_direct_checkpoint}. *)
