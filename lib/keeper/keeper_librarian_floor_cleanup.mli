(** What the message floor leaves in the store when its steps are no longer
    needed (RFC librarian-durable-message-floor 3.9, items 4 to 6). A step is
    settled like a history original: its record moves to the archive under the
    day its ID was minted, then the gate records of its judgment move under the
    same day. A stop between the two leaves gate records of an archived step,
    which a later call settles. Steps settle from the highest position down, so
    a stop part way leaves the steps from position 0 up: the ones a chain
    resumes from. A chain refuses any other leftover.

    Caller holds the Memory lane and purge fence and serializes this owner. An
    Eio entry point, called where the history settle is called: offload no part
    of it. *)

val cleanup : store:Lane_addon_store.t -> owner:Keeper_librarian_durable_request.owner ->
  candidates:Keeper_librarian_floor_descent.t list -> (int, string) result
(** Settle every step no candidate owns: its range original was archived, its
    range was published, or the read position moved on. Then settle the gate
    records of a step that is archived. Returns the records moved. *)

val settle_chain : store:Lane_addon_store.t -> owner:Keeper_librarian_durable_request.owner ->
  Keeper_librarian_floor_descent.t -> (int, string) result
(** Settle every step of one candidate and their gate records. A chain whose
    program the Memory no longer accepts starts again from nothing. If this
    stops part way, the steps from position 0 up stay and the next pass
    resumes from the Memory they started from. That chain ends again only if
    the lost tail can be answered again: a tail the host keeps refusing for a
    reason other than size ends each pass in [Stopped], which settles only
    that step. *)

val settle_step : store:Lane_addon_store.t -> owner:Keeper_librarian_durable_request.owner ->
  Keeper_librarian_floor_descent.t -> position:int -> (int, string) result
(** Settle the step of one candidate at one position, and its gate records. The
    other steps stay: a chain that stopped at a message asks that message again
    and keeps the answers before it. An error when the candidate holds no step
    at that position: the caller just asked that step and expects to find it. *)

module For_testing : sig
  val settle_steps_with :
    settle:(store:Lane_addon_store.t -> date:string -> Lane_addon_tool_request_owner.retained ->
            (unit, string) result) ->
    store:Lane_addon_store.t -> owner:Keeper_librarian_durable_request.owner ->
    (Lane_addon_tool_request_owner.retained * Keeper_librarian_floor_step_request.header) list ->
    (int, string) result
  (** The settle that {!cleanup}, {!settle_chain} and {!settle_step} share, over
      the steps given, with the move of each step record swapped, to stop the
      settle part way. The gate records of a step still move for real. *)
end
