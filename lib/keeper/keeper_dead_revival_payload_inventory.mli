(** Private inventory operations for immutable revival payloads. *)

open Keeper_dead_revival_payload_types

val inventory_authority_shards :
  Workspace.config ->
  (authority_shard list, error) result
(** Enumerates only validated authority directories under the payload root.
    The returned opaque shard may represent a create-before-[Reserved] orphan
    and therefore does not claim a reversible keeper name. *)

val inventory_transactions :
  Workspace.config ->
  authority_shard ->
  (inventory_transaction list, error) result
(** Lists only the validated single-component transaction leaves in one
    caller-locked authority shard. No raw filesystem path is exposed. The
    caller must continuously hold the matching revival authority lock across
    inventory, classification, and deletion. *)

val inventory_transaction_matches :
  inventory_transaction ->
  transaction_id:string ->
  bool

val delete_inventory_transaction :
  Workspace.config ->
  authority_shard:authority_shard ->
  inventory_transaction ->
  (unit, error) result
(** Deletes one opaque inventory entry. The caller must continuously hold the
    matching revival authority lock. *)
