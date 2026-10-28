(** What the message floor leaves in the store when its steps are no longer
    needed (RFC librarian-durable-message-floor 3.9, items 4 to 6). A step is
    settled like a history original: its record moves to the archive under the
    day its ID was minted, then the gate records of its judgment move under the
    same day. A stop between the two leaves gate records of an archived step,
    which a later call settles.

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
    program the Memory no longer accepts starts again from nothing. *)

val settle_step : store:Lane_addon_store.t -> owner:Keeper_librarian_durable_request.owner ->
  Keeper_librarian_floor_descent.t -> position:int -> (int, string) result
(** Settle the step of one candidate at one position, and its gate records. The
    other steps stay: a chain that stopped at a message asks that message again
    and keeps the answers before it. *)
