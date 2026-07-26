(** Private canonical codec for immutable revival payloads. *)

open Keeper_dead_revival_payload_types

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

val transaction_leaf_for_id :
  transaction_id:string ->
  (string, error) result

val prepare : payload -> (prepared, error) result
val prepared_payload : prepared -> payload
val prepared_ref : prepared -> immutable_ref

val authority_shard_for_keeper :
  keeper_name:string ->
  (authority_shard, error) result

val authority_shard_leaf : authority_shard -> string

val authority_shard_matches_keeper :
  authority_shard ->
  keeper_name:string ->
  bool

val payload_digest : string -> string
val canonical_authority_leaf : string -> string
val valid_authority_leaf : string -> bool
val valid_transaction_leaf : string -> bool
