(** Immutable, binding-complete payloads for dead-Keeper revival journals. *)

type payload
type immutable_ref

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
  | Create_failed of Fs_compat.capability_write_error
  | Read_failed of Fs_compat.Capability_exact_read.failure
  | Read_settlement_failed of
      Fs_compat.Capability_exact_read.settlement_warning list
  | Payload_digest_mismatch
  | Payload_binding_mismatch
  | Delete_failed of Keeper_fs.durable_remove_error

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

val create :
  Workspace.config ->
  authority_leaf:string ->
  payload ->
  (immutable_ref, error) result
(** Durably creates one exclusive mode-[0600] payload. Existing leaves are
    never replaced. *)

val read :
  Workspace.config ->
  expected_ref:immutable_ref ->
  authority_leaf:string ->
  transaction_id:string ->
  owner_id:string ->
  keeper_name:string ->
  expected_trace_id:Keeper_id.Trace_id.t ->
  expected_generation:int ->
  original:Keeper_meta_contract.keeper_meta ->
  candidate:Keeper_meta_contract.keeper_meta ->
  (payload, error) result
(** Reads exactly the referenced byte count, verifies its revival-domain
    digest, decodes only the current canonical schema, and checks every caller
    binding. *)

val delete :
  Workspace.config ->
  immutable_ref ->
  (unit, error) result
(** Idempotently removes the immutable payload and durably anchors absence. *)
