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
    stored intent/retry may attempt a source-locked save. Caller must offload no
    part of this Eio entry point; its blocking scopes offload themselves. *)
val publish : store:Lane_addon_store.t -> config:Workspace.config ->
  request:Keeper_librarian_durable_request.t ->
  original:Lane_addon_tool_request_owner.retained ->
  proposal:Keeper_librarian_runtime.durable_proposal ->
  fresh_authority:(unit -> (unit, string) result) ->
  (Keeper_librarian_durable_owner.publication, string) result

val validate : store:Lane_addon_store.t -> request:Keeper_librarian_durable_request.t ->
  record:Lane_addon_tool_request_owner.retained -> (unit, string) result
(** Blocking strict full-inventory validation. Original host proof, preparation,
    complete Gate lineage, terminal and immutable commit markers are checked.
    Historical Finished does not require today's moving range receipts/cursors
    to equal its old ones; it grants no current effect or ACK authority. *)

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
