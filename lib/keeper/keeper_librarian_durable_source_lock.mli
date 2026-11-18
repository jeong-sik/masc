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
val with_original_settlement : request:Keeper_librarian_durable_request.t ->
  (unit -> ('a, string) result) -> ('a, string) result
(** Hold the same physical source locks while recovering a receipt-proved
    settlement. The callback must check the original effect fence and actual
    Memory receipts, and accept only captured or already settled frontiers
    before any ACK/write. This scope permits a partial previous settlement;
    it does not require every frontier to still equal the captured one and
    does not reread a receipt-proved history prefix that may have been pruned.
    It checks the physical owner and grants no publication or acknowledgement
    authority of its own. *)
val positions_unchanged : Keeper_librarian_durable_request.t -> (bool, string) result
(** Whether the atom and official read positions are still the ones the
    original captured. A position that cannot be read is an error, not [false].
    Blocking reads; offload the call in an Eio caller. *)
val with_original_manifest : request:Keeper_librarian_durable_request.t ->
  (Keeper_librarian_durable_capture.message_manifest -> ('a, string) result) -> ('a, string) result
(** [with_original_snapshot]'s actual source/owner/cursor fence, yielding the
    complete retained message manifest from those same locked observations.
    It preserves original mixed ordering and full-source receipt coordinates.
    The callback must not reenter source locks. Offload this entire blocking
    scope; retaining its data grants no lock or later effect authority. *)

type 'a frontier = private
  | Advance of { observed : 'a option; target : 'a }
  | Keep_exact of 'a option
  | Keep_later of 'a
type position_plan
val atom_frontier : position_plan -> Keeper_librarian_progress.t frontier
val official_frontier : position_plan -> Keeper_librarian_official_progress.t frontier
val recheck_before : position_plan -> (unit, string) result
val recheck_after : position_plan -> (unit, string) result
(** A fresh source-locked position observation, never retained execution or
    acknowledgement authority. [Keep_later] is constructed only after the
    current coordinate is witnessed in the canonical source and original
    history generation. It authorizes no position write and proves no prior
    input absorption. [recheck_before] requires the exact observed frontiers
    and external preparation; [recheck_after] requires the planned frontiers
    and the original's exact settled external ACK. Neither reacquires locks. *)
val with_original_publication : request:Keeper_librarian_durable_request.t ->
  (position_plan -> ('a, string) result) -> ('a, string) result
(** The full immutable source/owner fence of [with_original], with canonical
    later positions preserved rather than rewound. Only an actual answered
    original plus its validated Gate, or a complete read program, may consume
    this port for publication. Refusal abandonment must keep using the strict
    [with_original] port. External preparation remains exactly as captured.
    Caller holds the serialized Memory lane; acquire Memory locks only inside
    this callback. Recheck this plan before effects and after settlement. *)
val with_original_settlement_plan : request:Keeper_librarian_durable_request.t ->
  (position_plan -> ('a, string) result) -> ('a, string) result
(** Reconstruct a new plan under the same physical source locks. The callback
    must independently prove actual complete input-reading Memory receipts
    and original answer/program authority before any effect or Finished fact.
    Captured/exact-target recovery does not reread the old source prefix.
    Preserving a later atom requires its fresh checkpoint/digest/restart
    witness; a later official cursor requires its exact completed official
    boundary row. A raced loading hint grants no authority: actual positions
    are reread under the scope. No old plan, new registry or marker is used. *)
