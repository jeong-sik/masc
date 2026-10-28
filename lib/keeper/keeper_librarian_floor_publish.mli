(** Publication of a finished message-floor chain (RFC
    librarian-durable-message-floor 3.9). The chain's program becomes one Memory
    commit over the range the refused original read, and the receipt carries the
    messages the chain could not read. Nothing else is done here: the receipt
    check, the external cursor's acknowledgement and the move of the read
    positions are the consumer's own tail, which it runs after any Memory commit
    of the range. A pass that crashed between the commit and that tail finds the
    range already committed and moves its position without a model call.

    Caller holds the Memory lane and purge fence and serializes this owner. *)
type outcome =
  | Published
      (** Memory holds the range's receipt: this call wrote it, or an earlier
          call did. *)
  | Superseded
      (** The Memory facts are no longer the ones the program judged, and nothing
          was written. The chain's decisions do not apply to the Memory of the
          moment; the caller starts the chain again from it. *)

val publish : candidate:Keeper_librarian_floor_descent.t ->
  finished:Keeper_librarian_message_floor.Machine.finished -> (outcome, string) result
(** Under the source lock of the refused original, confirm the Memory is the one
    the program started from, prepare the external cursor again with the range as
    the receipt will name it (holes included) and the original's own admissions,
    and commit the program. The commit is atomic in Memory; a crash before it
    leaves Memory as it was, and a crash after it leaves the receipt that the
    next call recognizes. An error is a source that is not the original's, a
    cursor that moved on, or a Memory commit that failed: the next call tries
    again with the same program. An Eio entry point: offload no part of it; its
    blocking scopes offload themselves. *)
