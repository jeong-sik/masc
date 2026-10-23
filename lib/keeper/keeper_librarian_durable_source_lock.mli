(** Original history publication fence. The caller already holds this Keeper's
    serialized Memory lane and purge exclusion. This port acquires the actual
    selected trace locks in stable order, validates the retained source prefixes,
    original read positions and complete current Memory, and invokes [publish]
    while those trace locks remain held. Appended history is allowed; it never
    enlarges the original source, receipts or acknowledgement frontier.

    Blocking filesystem scope: offload the whole call from Eio. The callback
    must not reenter any selected checkpoint/session lock. It acquires Memory
    locks only inside this source fence. An outer release error may follow a
    successful callback; independently reread actual Memory receipts before
    deciding whether publication happened. Data restored from Capture grants
    neither the caller's Memory-lane fence nor any source lock. *)
val with_original : request:Keeper_librarian_durable_request.t ->
  (unit -> ('a, string) result) -> ('a, string) result
