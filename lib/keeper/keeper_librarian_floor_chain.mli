(** The durable message floor's chain of steps (RFC librarian-durable-message-floor).
    The floor reads a range that exceeded the worker frame one message at a time.
    This module drives the floor's machine ({!Keeper_librarian_message_floor.Machine})
    with durable originals instead of live calls: each question becomes a retained
    step that runs at most once, its answer is judged by the absorb gate's
    journal, and the gated decision goes back into the machine. A message every
    slot refuses as too large becomes an unread hole and the floor moves on; any
    other refusal stops the chain.

    It performs no Memory commit, source lock, position move or settlement: the
    finished machine hands the ordered program to whoever publishes it. A restart
    runs the same function again. Every step the first run retained is restored,
    not asked again, and every gate judgment replays from the journal. A run
    reads the owner's gate scope once, when its first answered step needs
    judging, and answers the judgments of the steps an earlier run finished from
    that read; only the step it judges for the first time reads the scope
    again. A run with no answered step does not read it. A run then costs time
    in proportion to the steps it replays. Caller holds the Memory lane and
    purge fence and serializes this owner. *)
type fresh = {
  transaction_id : string;
  current : Keeper_librarian.current_selection option;
  previous_state : string option;
  unread_messages : Keeper_librarian_unread.t list;
}
(** What a chain with no step yet starts from: the one Memory transaction its
    program will carry, the facts the floor starts from, and the working state and
    unread messages the first question carries in. A chain that already has a
    step ignores all four and takes them from its first step, so a restart can
    neither name a new transaction nor start from the Memory of the moment. *)

type outcome =
  | Finished of Keeper_librarian_message_floor.Machine.finished
      (** Every message is decided and the ordered program is validated. *)
  | Pending of string
      (** A step awaits its worker, or a judgment awaits the gate. A later wake
          runs the chain again. *)
  | Stopped of {position : int; report : Keeper_librarian_runtime.not_committed}
      (** The step at [position] ended in a refusal that does not show reading
          less could help, or the question is a host observation that cannot become
          a hole. The chain does not advance. [report] is the host's own evidence. *)

val run :
  store:Lane_addon_store.t -> config:Workspace.config -> reserved:string list ->
  owner:Keeper_librarian_durable_request.owner -> range:Keeper_librarian_floor_step_request.link ->
  input:Keeper_librarian.input -> sources:Keeper_librarian_unread.source list ->
  fresh:(unit -> (fresh, string) result) ->
  unread_message:(Keeper_librarian_unread.source ->
    reasons:Keeper_librarian_input_refusal.t list -> (Keeper_librarian_unread.t, string) result) ->
  (outcome, string) result
(** [input] and [sources] are the range's complete input and one source per
    message, as {!Keeper_librarian_message_floor.Machine.read} takes them; [range]
    names the range's original, which every step links to. [fresh] is called
    only when the chain has no step yet, so a restart never reads the Memory of
    the moment; an error from it is the chain's error. [unread_message] builds
    the hole of a message from its source and the refusal causes. An error is a
    chain that disagrees with itself or its range: two steps at one position, a
    step the floor never asked about, a step that is not the question the machine
    asks, or a step whose previous link or transaction differs. An Eio entry
    point: offload no part of it; its blocking store accesses offload
    themselves. *)
