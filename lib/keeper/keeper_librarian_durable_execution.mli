(** Production completed-history Addon adapter. Call only inside the Keeper's
    serialized Memory lane and purge fence. Resume immutable retained work before
    invoking a fresh selector; never send an unknown request again. *)
val consume_one : config:Workspace.config -> keeper_name:string ->
  wake:(unit -> unit) ->
  (Keeper_librarian_durable_consumer.outcome,
   Keeper_librarian_durable_consumer.error) result
(** An unavailable attachment reports [Original_publication_blocked] and leaves
    the original source unread. A verified host terminal [Outcome_unknown] is
    read by its cause. An attempt that raised, and one cut off in this process
    under the declaration it was captured for, remain the original unfinished
    frontier and return [Pending] on the first and later wakes, without fresh
    selection or a new provider call. An attempt a stopped process interrupted
    settles (RFC-0500), and so does one cut off in this process whose
    declaration was replaced since (RFC
    librarian-ends-waiting-requests-of-a-replaced-declaration 3.5): the pass
    that reads the refusal asks [wake], and the next pass moves the original
    and selects its range again, whole, under a new ID, which asks the model
    once more. For the cut one that holds only while the destination the pass
    reads names another configuration revision of the same installation,
    package and tool; the end is the move, so an original not yet moved waits
    again once its declaration is put back. Observed
    worker absence after dispatch may instead prepare the existing fenced
    history resolution, only after its host-proof, receipt and source guards
    pass. Its durable continuation requests a later Memory-lane unit before
    dispatch; neither the original RPC nor its source is replayed or ACKed by
    that preparation. The same durable intent and child resume after a stop.
    Definite terminal host refusals preserve their actual diagnostic in
    [Memory_not_committed] without remaining an unfinished frontier; a later
    wake may freshly select their still-unread source under a new ID, except
    capacity-only counterpart refusals: {!Keeper_librarian_durable_refusal}
    retains and reports their actual original before fresh selection, across
    ticks and restart. A different configured semantic destination permits a
    fresh attempt while retaining the earlier refusal; returning to its old
    configuration blocks again while its range is still relevant. Actual range
    receipts, or a proved later reader frontier including the original external
    ACK, permit settlement without claiming unread messages were read.
    Changed positions do not certify source equality or completed consumption.
    A refused original that read one turn, whose refusal shows that reading
    less may help, is a message floor candidate
    ({!Keeper_librarian_floor_descent}). It is neither archived nor a
    frontier. The pass that selects its range reads the turn message by
    message under the candidate and commits the result to Memory once; a
    message every slot refuses as too large stays unread and is recorded. A
    step the host refuses for another reason ends the pass with that refusal,
    and the next pass asks the same position under a new ID, keeping the
    steps before it. A Memory that changed under the chain drops its steps and
    asks [wake] for another pass. The steps of a range that was published, or
    whose read position moved, are settled before the original that names
    them. A refusal that reaches a pass narrows the next fresh read to one
    turn, as a failed commit does. One refusal does not: a request the host
    ended unrun with the stored [Replaced_declaration] reason. It says
    nothing about the size of the input, so the next read stays whole and the
    pass asks [wake] for it; no host event follows that refusal. This does not
    depend on the current declaration or worker being available. An original
    no worker has received whose declaration was replaced ends in the pass that
    resumes it: nothing was refused, so the next read is not narrowed, and that
    pass asks [wake] too. This grants
    no consumption, capacity or skip authority beyond that. Original
    completed local publication may still recover while the Addon is Off.
    [wake] schedules the same Memory lane after a newly observed Finished fact;
    it also schedules after known basis supersession. Full scope validation
    binds each successor to one strictly superseded predecessor and preserves
    that predecessor's complete original source/frontier while rebasing only
    current Memory. The parent retains its full child intent before publication
    and acknowledges the strictly reread child before dispatch. Missing pending
    publication recovers that same request locally while Off; a missing
    acknowledged child refuses. Missing parents, cycles, orphaned or multiple
    children refuse before selection or dispatch. An unresolved superseded frontier
    reports the unavailable attachment while the Addon is Off. Scheduling acceptance does not prove a Memory effect
    or a drained queue. *)
