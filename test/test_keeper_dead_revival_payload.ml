open Alcotest
open Test_keeper_dead_revival_payload_codec
open Test_keeper_dead_revival_payload_storage_create
open Test_keeper_dead_revival_payload_storage_read
open Test_keeper_dead_revival_payload_inventory

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Masc_test_deps.init_eio_clock env;
  run
    "keeper dead revival payload"
    [ ( "codec"
      , [ test_case
            "canonical codec and domain bindings"
            `Quick
            test_canonical_codec_and_domain_bindings
        ; test_case
            "candidate lifecycle binding rejections"
            `Quick
            test_candidate_lifecycle_binding_rejections
        ] )
    ; ( "storage"
      , [ test_case
            "create mode, replay evidence, and conflict"
            `Quick
            test_create_mode_replay_evidence_and_conflict
        ; test_case
            "decode-only read"
            `Quick
            test_decode_only_read
        ; test_case
            "Target_created reconciliation"
            `Quick
            test_target_created_reconciles_with_retained_evidence
        ; test_case
            "unsettled target effects"
            `Quick
            test_unsettled_target_effects_retain_evidence
        ; test_case
            "reconciliation read failure"
            `Quick
            test_create_reconciliation_read_failure
        ; test_case
            "reconciliation parent sync failure"
            `Quick
            test_create_reconciliation_parent_sync_failure
        ; test_case
            "Target_created same-leaf conflict"
            `Quick
            test_target_created_classifies_same_leaf_conflict
        ; test_case
            "read failures"
            `Quick
            test_read_failures
        ; test_case
            "noncanonical stored bytes"
            `Quick
            test_read_rejects_noncanonical_stored_bytes
        ; test_case
            "transaction-bound idempotent delete"
            `Quick
            test_transaction_bound_idempotent_delete
        ; test_case
            "large metadata roundtrip"
            `Quick
            test_large_metadata_roundtrip
        ] )
    ; ( "inventory"
      , [ test_case
            "root, shard, and transaction inventory"
            `Quick
            test_root_shard_and_transaction_inventory
        ; test_case
            "invalid inventory entries"
            `Quick
            test_inventory_rejects_invalid_entries
        ] )
    ]
;;
