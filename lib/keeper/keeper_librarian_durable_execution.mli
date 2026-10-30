(** Production completed-history Addon adapter. Call only inside the Keeper's
    serialized Memory lane and purge fence. Resume immutable retained work before
    invoking a fresh selector; never re-create or redispatch an unknown request. *)
val consume_one : config:Workspace.config -> keeper_name:string ->
  wake:(unit -> unit) ->
  (Keeper_librarian_durable_consumer.outcome,
   Keeper_librarian_durable_consumer.error) result
(** An unavailable attachment reports [Original_publication_blocked] and leaves
    the original source unread. A verified host terminal [Outcome_unknown]
    remains the original unfinished frontier and returns [Pending] on its first
    and later wakes, without fresh selection or a new provider call. Definite
    terminal host refusals preserve their actual diagnostic in
    [Memory_not_committed] without remaining an unfinished frontier; a later
    wake may freshly select their still-unread source under a new ID.
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
    turn, as a failed commit does. This grants no consumption, capacity or skip
    authority beyond that. Original
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
