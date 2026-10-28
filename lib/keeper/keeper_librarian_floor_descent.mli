(** The way down from a refused history original to the durable message floor
    (RFC librarian-durable-message-floor 3.9). A refused original is a floor
    candidate when the host kept a typed size refusal for the one turn it read,
    and no Memory receipt covers that turn yet. {!descend} runs the floor's
    chain over the turn, one message at a time, and publishes nothing: the
    finished program is the caller's to publish. Caller holds the Memory lane
    and purge fence and serializes this owner. *)
type turn =
  | Atoms of Keeper_memory_os_current.durable_range_id
  | Official of Keeper_librarian_range.official_line * Keeper_memory_os_current.official_range_id
(** The one turn a candidate's original read: an atom range, or one official
    turn, each with the range its Memory receipt names. *)

type t

val candidate : store:Lane_addon_store.t -> record:Lane_addon_tool_request_owner.retained ->
  request:Keeper_librarian_durable_request.t -> (t option, string) result
(** [Some] when all of these hold, [None] when any does not:
    - the host retained a refusal of the execution ([Rejected]);
    - the original read one turn: its extent is [To_first_cut_point] and its
      source is one atom range or one official turn, not both;
    - the original has a message to read;
    - the refusal shows that reading less may help, by the rule the Runtime
      floor applies to its evidence ({!Keeper_librarian_runtime.may_descend_messages})
      over the host's own ({!Keeper_librarian_durable_request.refusal_evidence}).
      The Runtime floor takes a one-turn read of any extent; the durable path
      takes the narrowed read, so a one-turn backlog the consumer first read as
      a whole descends one pass later;
    - Memory holds no receipt of the original's range;
    - the read positions are still the ones the original captured. If they
      moved, the range the next pass selects is not the original's.

    An error is a record that is not the request's own, or a record or host
    evidence that cannot be read; it is never a candidate that was dropped. The
    record is one the caller validated with
    {!Keeper_librarian_durable_commit.validate_inventory}. An Eio entry point:
    offload no part of it; its blocking reads offload themselves. *)

val request : t -> Keeper_librarian_durable_request.t
val record : t -> Lane_addon_tool_request_owner.retained
val turn : t -> turn
val range : t -> Keeper_librarian_floor_step_request.link
(** The original, named by ID and digest as every step of its chain names it. *)

val covers : t -> Keeper_librarian_durable_capture.t -> bool
(** Whether a pass that selected its range afresh selected the candidate's: the
    same read extent and the same receipt identities, except two line numbers of
    an atom range that move with the log. The count of boundary lines the pass
    saw grows, and the line that witnesses the range's end is a later line when
    a later line states the same position. They say where the log put the range,
    not which range it is, so they are not compared. The pass's own capture is
    not the candidate's original, and the chain of the candidate is the one that
    reads the pass's range. *)

val descend : store:Lane_addon_store.t -> config:Workspace.config -> reserved:string list ->
  t -> (Keeper_librarian_floor_chain.outcome, string) result
(** Run {!Keeper_librarian_floor_chain.run} over the candidate's turn. The
    chain reads the turn from the original: an official turn from its retained
    messages, an atom range from the checkpoint as the source lock sees it now,
    which must still hold what the original read. A chain that has a step
    starts again from that step. A chain with none starts from the Memory facts
    of this call, no carried working state and the unread ledger as it is.
    An Eio entry point: offload no part of it; its blocking scopes offload
    themselves. *)
