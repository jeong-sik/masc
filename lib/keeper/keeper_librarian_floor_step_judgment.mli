(** The absorb gate's judgment of one answered message-floor step, and the
    Memory decision that judgment makes. The step's record stays at its answer:
    the gate runs as a journal of originals of its own, whose root names the
    decision, and the Memory commit belongs to the whole chain. Caller holds the
    existing Memory-lane/purge fence and serializes this owner. *)
type result =
  | Pending of string
      (** The judgment is not complete: the gate is unavailable or still being
          asked, or its evaluation failed. The detail says which. A later call
          asks again or replays; nothing is skipped. *)
  | Decided of Keeper_librarian_runtime.memory_step
      (** The gated decision, in the form the ordered Memory plan and program
          take, with the gate root's request ID as its run identity. *)
val judge : store:Lane_addon_store.t -> step:Keeper_librarian_floor_step_request.t ->
  record:Lane_addon_tool_request_owner.retained -> answer:Keeper_librarian_floor_step_owner.answer ->
  fresh_authority:(unit -> (unit, string) Stdlib.result) ->
  inventory:Keeper_librarian_floor_step_gate.Inventory.t -> (result, string) Stdlib.result
(** [record] is the step's answered record. Prepare the gate's root once and
    retain that intent on the record, publish a root a crash left pending, run
    the journal's next question or replay a completed one, and retry a failed
    evaluation as a new attempt. A completed journal replays from the
    evaluations the host retained: a restart never asks the model again and never
    judges again with the Memory of the moment. [fresh_authority] checks the
    owner and the configured destination before anything is created or sent.

    [inventory] is the owner's gate scope read once for the whole pass. A step
    whose journal it shows complete and successful is judged from it, without
    reading the store: the cost of a pass then grows with the chain's length,
    not with its square. Every other step, which may recover, retry or
    dispatch, reads and writes the store afresh, as an inventory is never
    authority for a mutation.

    An Eio entry point: offload no part of it; its blocking store reads and
    writes offload themselves. *)
