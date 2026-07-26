include Keeper_dead_revival_payload_types

let error_to_string = Keeper_dead_revival_payload_error.error_to_string
let make_payload = Keeper_dead_revival_payload_codec.make_payload
let payload_to_bytes = Keeper_dead_revival_payload_codec.payload_to_bytes
let payload_of_bytes = Keeper_dead_revival_payload_codec.payload_of_bytes
let payload_transaction_id = Keeper_dead_revival_payload_codec.payload_transaction_id
let payload_owner_id = Keeper_dead_revival_payload_codec.payload_owner_id
let payload_keeper_name = Keeper_dead_revival_payload_codec.payload_keeper_name
let payload_expected_trace_id = Keeper_dead_revival_payload_codec.payload_expected_trace_id
let payload_expected_generation = Keeper_dead_revival_payload_codec.payload_expected_generation
let payload_runtime_transition = Keeper_dead_revival_payload_codec.payload_runtime_transition
let payload_original = Keeper_dead_revival_payload_codec.payload_original
let payload_candidate = Keeper_dead_revival_payload_codec.payload_candidate
let immutable_ref_to_json = Keeper_dead_revival_payload_codec.immutable_ref_to_json
let immutable_ref_of_json = Keeper_dead_revival_payload_codec.immutable_ref_of_json
let immutable_ref_to_bytes = Keeper_dead_revival_payload_codec.immutable_ref_to_bytes
let immutable_ref_of_bytes = Keeper_dead_revival_payload_codec.immutable_ref_of_bytes
let immutable_ref_authority_leaf = Keeper_dead_revival_payload_codec.immutable_ref_authority_leaf
let immutable_ref_transaction_leaf = Keeper_dead_revival_payload_codec.immutable_ref_transaction_leaf
let immutable_ref_sha256 = Keeper_dead_revival_payload_codec.immutable_ref_sha256
let immutable_ref_byte_count = Keeper_dead_revival_payload_codec.immutable_ref_byte_count
let transaction_leaf_for_id = Keeper_dead_revival_payload_codec.transaction_leaf_for_id
let prepare = Keeper_dead_revival_payload_codec.prepare
let prepared_payload = Keeper_dead_revival_payload_codec.prepared_payload
let prepared_ref = Keeper_dead_revival_payload_codec.prepared_ref
let create = Keeper_dead_revival_payload_store.create
let read = Keeper_dead_revival_payload_store.read
let delete = Keeper_dead_revival_payload_store.delete
let authority_shard_for_keeper = Keeper_dead_revival_payload_codec.authority_shard_for_keeper
let authority_shard_leaf = Keeper_dead_revival_payload_codec.authority_shard_leaf
let authority_shard_matches_keeper = Keeper_dead_revival_payload_codec.authority_shard_matches_keeper
let inventory_authority_shards = Keeper_dead_revival_payload_inventory.inventory_authority_shards
let inventory_transactions = Keeper_dead_revival_payload_inventory.inventory_transactions
let inventory_transaction_matches = Keeper_dead_revival_payload_inventory.inventory_transaction_matches
let delete_inventory_transaction = Keeper_dead_revival_payload_inventory.delete_inventory_transaction

module For_testing = struct
  type nonrec hooks = testing_hooks

  let hooks
      ?create_target_effect
      ?(reconciliation_read = fun () -> `Use_production)
      ?(parent_sync = fun () -> `Use_production)
      ()
    =
    { create_target_effect
    ; reconciliation_read
    ; parent_sync
    }
  ;;

  let with_hooks hooks fn =
    Eio.Fiber.with_binding testing_hooks_key hooks fn
  ;;
end
