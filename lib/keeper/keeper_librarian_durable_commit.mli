(** Actual completed-history publication. Caller holds the existing serialized
    Memory lane/purge fence. No explicit-candidate generation or admission
    receipt is used. The full original host answer and original Gate journal
    are revalidated before any Memory effect. New Gate questions require
    [fresh_authority], which confirms the physical Keeper/epoch and a ready
    configured destination with the original installation/package/tool. Its
    semantic revision may change after the answer; this never resubmits the
    parent or replaces its proposal. The Gate still requires its own captured
    authority for a new question. Already-completed original evaluations and
    a committed Memory receipt can settle locally while the Addon is Off, provided the
    original question passes the live counterpart-template policy. An unsafe
    legacy question cannot use that receipt to publish a new external ACK.

    A pending publication can already have its actual Memory receipts: it means
    the complete original settlement (unread archive, external ACK, atom and
    official positions, durable Finished) is not yet confirmed. Recovery never
    repeats inference or an already receipt-proved Memory effect. Only a newly
    stored intent/retry may attempt a source-locked save. Only a typed basis
    refusal from the actual store guard, followed by a receipt recheck, records
    a confirmed supersession; untyped failures remain unconfirmed. Caller must
    offload no part of this Eio entry point; its blocking scopes offload themselves.

    An actual answered original and validated Gate may publish its complete
    frozen input at the current Memory basis while preserving canonically
    witnessed later atom/official positions. This still writes new exact
    original-range receipts; a later coordinate proves no previous absorption.
    Position settlement reconstructs and rechecks that proof under source
    locks and never rewinds a preserved position. External preparation stays
    exact. Refusal abandonment retains its strict captured/target policy. *)
val publish : store:Lane_addon_store.t -> config:Workspace.config ->
  request:Keeper_librarian_durable_request.t ->
  original:Lane_addon_tool_request_owner.retained ->
  proposal:Keeper_librarian_runtime.durable_proposal ->
  fresh_authority:(unit -> (unit, string) result) ->
  (Keeper_librarian_durable_owner.publication, string) result

type frontier = Unfinished | Settled
val validate : store:Lane_addon_store.t -> request:Keeper_librarian_durable_request.t ->
  record:Lane_addon_tool_request_owner.retained -> (frontier, string) result
(** Blocking strict full-inventory validation. Original host proof, preparation,
    complete Gate lineage, terminal and immutable commit markers are checked.
    [Unfinished] includes an actual host terminal [Outcome_unknown], except an
    [interrupted] cause or a host-confirmed [cut] with a strict stored
    declaration-replacement disposition. The latter releases source for fresh
    selection without a Memory or input acknowledgement. Other unknown source
    remains owned by this original and cannot be freshly selected. Definite
    terminal refusals are [Settled]; a known basis conflict is also [Settled]
    here and must separately pass the existing strict successor-lineage policy.
    Historical Finished and known typed-basis conflicts do not require today's
    moving range receipts/cursors to equal the old ones; they grant no current
    effect or ACK authority. *)

val validate_inventory : inventory:Keeper_librarian_durable_gate.Inventory.t ->
  store:Lane_addon_store.t -> request:Keeper_librarian_durable_request.t ->
  record:Lane_addon_tool_request_owner.retained -> (frontier, string) result
(** Same strict read-only validation as [validate], using one complete gate
    inventory acquired for this consume pass and the already restored original
    record. The observation is never accepted by publication or dispatch APIs. *)

val receipt_state : Keeper_librarian_durable_request.t -> (bool, string) result
(** Whether Memory holds the receipts of every range this original names. [true]
    when all of them are there, [false] when none is. A partial set, and an
    original that names no range, are errors. The messages a receipt could not
    read are not part of the comparison: a range the message floor published
    with unread messages is the original's range all the same. Blocking read;
    offload it in an Eio caller. *)

val is_superseded : request:Keeper_librarian_durable_request.t ->
  record:Lane_addon_tool_request_owner.retained -> (bool, string) result
(** Pure strict check of this domain's immutable typed-basis conflict evidence.
    Non-conflicted records return [Ok false]; an unknown or malformed conflict
    is an error. This does not replace [validate]'s host proof, Gate lineage and
    original commit-marker validation and grants no new request by itself.
    Historical conflicts never require today's moving range receipts to remain
    absent: a later linked original can publish the same selected source. *)

val settle_program : store:Lane_addon_store.t ->
  floor:Keeper_librarian_history_resolution_floor.t ->
  program:Keeper_memory_os_current.committed_program ->
  (Keeper_librarian_history_program_settlement.t, string) result
(** Settle a fully read actual program from this strict Cut-floor owner. Recheck
    its real leaf, confirmed Cut ancestry, retained first basis and complete
    committed target under source locks before any ACK/position write. Never
    create an empty disposition, abandonment marker or fabricated Finished.
    Return separately re-observed actual post-ACK evidence. Caller is the
    serialized Memory lane and holds no source or Memory lock. *)

module For_testing : sig
  val settle_program : after_settlement:(unit -> unit) -> store:Lane_addon_store.t ->
    floor:Keeper_librarian_history_resolution_floor.t ->
    program:Keeper_memory_os_current.committed_program ->
    (Keeper_librarian_history_program_settlement.t, string) result
  (** Same production path. The hook runs after actual ACK/read-position
      settlement and before a proof is returned or retained by the intent. *)
  val publish : before_settlement:(unit -> unit) ->
    store:Lane_addon_store.t -> config:Workspace.config ->
    request:Keeper_librarian_durable_request.t ->
    original:Lane_addon_tool_request_owner.retained ->
    proposal:Keeper_librarian_runtime.durable_proposal ->
    fresh_authority:(unit -> (unit, string) result) ->
    (Keeper_librarian_durable_owner.publication, string) result
  (** Same production path. Hook runs after actual Memory receipts are proven
      and before source ACK/read-position settlement, so tests can interrupt or
      fault the real filesystem without fabricating domain success. *)
  val settle_refused : before_settlement:(unit -> (unit, string) result) ->
    store:Lane_addon_store.t -> request:Keeper_librarian_durable_request.t ->
    record:Lane_addon_tool_request_owner.retained ->
    (Lane_addon_tool_request_owner.retained, string) result
  (** Same refusal path. The hook runs after actual range receipts and before
      ACK/read-position settlement. Returning an error preserves the refusal
      record so the next ordinary call can recover the same receipt-backed
      settlement, including a frontier the interrupted hook already ACKed. *)
end

val settle_refused : store:Lane_addon_store.t -> request:Keeper_librarian_durable_request.t ->
  record:Lane_addon_tool_request_owner.retained ->
  (Lane_addon_tool_request_owner.retained, string) result
(** End a permanent execution refusal by abandoning its exact range, then record
    [Progress.Refusal_settled diagnosis] on the original. Writes the range's
    Memory receipts with an empty disposition unless they are already proved,
    runs the same unread archive, external ACK and atom/official position
    settlement a finished original uses, and only then appends the fact. Refuses
    any record that is not an unsettled execution refusal, and refuses if the
    original is effect-fenced, has a confirmed Cut ancestor, or the read positions
    moved outside this original's settlement. Fence checks and ACK/write hold
    the original source locks, including fresh strict ancestry checks and
    recovery of a partial previous settlement. A Cut descendant remains
    unresolved without new receipts or source ACK; a refusal is not descendant
    reading. Each locked inspection strictly confirms the actual capacity final
    and proof and excludes Gate/replacement/settlement. The audit diagnosis is
    derived from that evidence. Interrupted ordinary refusal settlement
    re-enters safely. This relaxes fail-closed on purpose: the refused input is
    never read. Blocking; offload it in an Eio caller. *)
