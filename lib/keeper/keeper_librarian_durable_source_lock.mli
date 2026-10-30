(** Original history publication fence. The caller already holds this Keeper's
    serialized Memory lane and purge exclusion. This port acquires the actual
    selected trace locks in stable order, confirms that the prefix of each
    source the original read still has its digest and selects and projects to
    its input ({!Keeper_librarian_durable_capture.confirm_sources}), checks the
    original read positions, and invokes [publish]
    while those trace locks remain held. Appended history is allowed; it never
    enlarges the original source, receipts or acknowledgement frontier.

    Blocking filesystem scope: offload the whole call from Eio. The callback
    must not reenter any selected checkpoint/session lock. It acquires Memory
    locks only inside this source fence. The actual Memory store guard, under its
    own update locks after recovery, classifies the captured Memory basis; this
    source fence does not preempt that typed decision. An outer release error may
    follow a successful callback; independently reread actual Memory receipts before
    deciding whether publication happened. Data restored from Capture grants
    neither the caller's Memory-lane fence nor any source lock. *)
val with_original : request:Keeper_librarian_durable_request.t ->
  (unit -> ('a, string) result) -> ('a, string) result
val with_original_snapshot : request:Keeper_librarian_durable_request.t ->
  (messages:Agent_core.Types.message list option -> ('a, string) result) -> ('a, string) result
(** The same fence as [with_original], for a caller that reads the source
    rather than publishes the original's own preparation. Two differences.
    The callback gets the complete messages of the checkpoint the original
    read, as the held lock sees them now, or [None] when the original read no
    checkpoint. And the external cursor may differ from the one the original
    captured: every pass that selects the range prepares it again, so it moves
    as admissions arrive. The read positions must still be the captured ones.
    Everything else above holds: blocking scope, no reentry of a selected lock,
    and no authority beyond the call. *)
val positions_unchanged : Keeper_librarian_durable_request.t -> (bool, string) result
(** Whether the atom and official read positions are still the ones the
    original captured. A position that cannot be read is an error, not [false].
    Blocking reads; offload the call in an Eio caller. *)
