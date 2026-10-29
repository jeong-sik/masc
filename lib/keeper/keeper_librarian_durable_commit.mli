(** Actual completed-history publication. Caller holds the existing serialized
    Memory lane/purge fence. No explicit-candidate generation or admission
    receipt is used. The full original host answer and original Gate journal
    are revalidated before any Memory effect. New Gate questions require
    [fresh_authority]; already-completed original evaluations and a committed
    Memory receipt can settle locally while the Addon is Off.

    A pending publication can already have its actual Memory receipts: it means
    the complete original settlement (unread archive, external ACK, atom and
    official positions, durable Finished) is not yet confirmed. Recovery never
    repeats inference or an already receipt-proved Memory effect. Only a newly
    stored intent/retry may attempt a source-locked save. Only a typed basis
    refusal from the actual store guard, followed by a receipt recheck, records
    a confirmed supersession; untyped failures remain unconfirmed. Caller must
    offload no part of this Eio entry point; its blocking scopes offload themselves. *)
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
    [Unfinished] includes an actual host terminal [Outcome_unknown]: its source
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
    original that names no range, are errors. Blocking read; offload it in an
    Eio caller. *)

val is_superseded : request:Keeper_librarian_durable_request.t ->
  record:Lane_addon_tool_request_owner.retained -> (bool, string) result
(** Pure strict check of this domain's immutable typed-basis conflict evidence.
    Non-conflicted records return [Ok false]; an unknown or malformed conflict
    is an error. This does not replace [validate]'s host proof, Gate lineage and
    original commit-marker validation and grants no new request by itself.
    Historical conflicts never require today's moving range receipts to remain
    absent: a later linked original can publish the same selected source. *)

module For_testing : sig
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
end
