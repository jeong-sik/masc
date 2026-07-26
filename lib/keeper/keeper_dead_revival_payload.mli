(** Immutable, binding-complete payloads for dead-Keeper revival journals. *)

type payload
type immutable_ref
type prepared
type authority_shard
type inventory_transaction

type create_outcome =
  | Created of prepared
  | Reconciled_created of
      { prepared : prepared
      ; initial_failure : Fs_compat.capability_write_error
      }

type create_reconciliation_failure =
  | Reconciliation_read_failed of
      Fs_compat.Capability_exact_read.failure
  | Reconciliation_read_settlement_failed of
      Fs_compat.Capability_exact_read.settlement_warning list
  | Reconciliation_parent_sync_failed of
      Fs_compat.capability_directory_sync_error

type error =
  | Invalid_binding of string
  | Malformed_payload of string
  | Unsupported_payload_schema of string
  | Noncanonical_payload
  | Malformed_ref of string
  | Unsupported_ref_schema of string
  | Noncanonical_ref
  | Filesystem_capability_unavailable
  | Directory_prepare_failed of string
  | Parent_open_failed of string
  | Create_conflict of
      { prepared : prepared
      ; initial_failure : Fs_compat.capability_write_error
      }
  | Create_unsettled of
      { prepared : prepared
      ; initial_failure : Fs_compat.capability_write_error
      }
  | Create_reconciliation_failed of
      { prepared : prepared
      ; initial_failure : Fs_compat.capability_write_error
      ; reconciliation_failure : create_reconciliation_failure
      }
  | Read_failed of Fs_compat.Capability_exact_read.failure
  | Read_settlement_failed of
      Fs_compat.Capability_exact_read.settlement_warning list
  | Payload_digest_mismatch
  | Payload_binding_mismatch
  | Delete_failed of Keeper_fs.durable_remove_error
  | Inventory_failed of string

val error_to_string : error -> string

val make_payload :
  transaction_id:string ->
  owner_id:string ->
  keeper_name:string ->
  expected_trace_id:Keeper_id.Trace_id.t ->
  expected_generation:int ->
  original:Keeper_meta_contract.keeper_meta ->
  candidate:Keeper_meta_contract.keeper_meta ->
  (payload, error) result

val payload_to_bytes : payload -> string
val payload_of_bytes : string -> (payload, error) result

val payload_transaction_id : payload -> string
val payload_owner_id : payload -> string
val payload_keeper_name : payload -> string
val payload_expected_trace_id : payload -> Keeper_id.Trace_id.t
val payload_expected_generation : payload -> int
val payload_original : payload -> Keeper_meta_contract.keeper_meta
val payload_candidate : payload -> Keeper_meta_contract.keeper_meta

val immutable_ref_to_json : immutable_ref -> Yojson.Safe.t
val immutable_ref_of_json : Yojson.Safe.t -> (immutable_ref, error) result
val immutable_ref_to_bytes : immutable_ref -> string
val immutable_ref_of_bytes : string -> (immutable_ref, error) result

val immutable_ref_authority_leaf : immutable_ref -> string
val immutable_ref_transaction_leaf : immutable_ref -> string
val immutable_ref_sha256 : immutable_ref -> string
val immutable_ref_byte_count : immutable_ref -> int64

val prepare : payload -> (prepared, error) result
val prepared_payload : prepared -> payload
val prepared_ref : prepared -> immutable_ref

val create :
  Workspace.config ->
  prepared ->
  (create_outcome, error) result
(** Durably creates one exclusive mode-[0600] payload. Existing leaves are
    never replaced. An exact pre-existing payload is reconciled as idempotent
    success; conflicting bytes are rejected. *)

val read :
  Workspace.config ->
  expected_ref:immutable_ref ->
  expected_authority_leaf:string ->
  transaction_id:string ->
  owner_id:string ->
  keeper_name:string ->
  expected_trace_id:Keeper_id.Trace_id.t ->
  expected_generation:int ->
  (payload, error) result
(** Reads exactly the referenced byte count, verifies its revival-domain
    digest, decodes only the current canonical schema, and checks every caller
    binding. *)

val delete :
  Workspace.config ->
  keeper_name:string ->
  expected_authority_leaf:string ->
  transaction_id:string ->
  immutable_ref ->
  (unit, error) result
(** Idempotently removes the immutable payload and durably anchors absence.
    The caller must continuously hold the matching revival authority lock. *)

val authority_shard_for_keeper :
  keeper_name:string ->
  (authority_shard, error) result

val authority_shard_leaf : authority_shard -> string

val authority_shard_matches_keeper :
  authority_shard ->
  keeper_name:string ->
  bool

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
