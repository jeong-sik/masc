(** Private concrete state shared by immutable revival payload helpers. *)

type payload =
  { transaction_id : string
  ; owner_id : string
  ; keeper_name : string
  ; expected_trace_id : Keeper_id.Trace_id.t
  ; expected_generation : int
  ; original : Keeper_meta_contract.keeper_meta
  ; candidate : Keeper_meta_contract.keeper_meta
  }

type immutable_ref =
  { authority_leaf : string
  ; transaction_leaf : string
  ; sha256 : string
  ; byte_count : int64
  }

type prepared =
  { payload : payload
  ; reference : immutable_ref
  ; bytes : string
  }

type authority_shard =
  { keeper_name : string option
  ; authority_leaf : string
  }

type inventory_transaction =
  { inventory_authority_leaf : string
  ; inventory_transaction_leaf : string
  }

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
  | Reconciliation_read_injected of string
  | Reconciliation_parent_sync_failed of
      Fs_compat.capability_directory_sync_error
  | Reconciliation_parent_sync_injected of string

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

type testing_boundary_decision =
  [ `Fail of string
  | `Use_production
  ]

type testing_hooks =
  { create_target_effect :
      Fs_compat.capability_write_target_effect option
  ; reconciliation_read : unit -> testing_boundary_decision
  ; parent_sync : unit -> testing_boundary_decision
  }


val testing_hooks_key : testing_hooks Eio.Fiber.key
