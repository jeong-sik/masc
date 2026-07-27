type stage =
  | Reserved
  | Durable_committed
  | Launch_committed
  | Rollback_reserved
  | Rollback_durable_committed
  | Forward_cleanup_pending
  | Rollback_cleanup_pending_from_reserved
  | Rollback_cleanup_pending_from_durable_committed
  | Cleared

type evidence =
  { keeper_name : string
  ; transaction_id : string
  ; stage : stage
  }

type authority_failure =
  | Authority_path_unavailable
  | Filesystem_capability_unavailable
  | Entropy_unavailable
  | Durable_lock_unavailable
  | Durable_lock_release_failed
  | Authority_read_failed
  | Authority_read_settlement_failed
  | Invalid_current_schema

type blocked_reason =
  | Authority_unreadable of
      { keeper_name : string
      ; failure : authority_failure
      }
  | Authority_invalid of
      { keeper_name : string
      ; failure : authority_failure
      }
  | Rollback_capable_authority of evidence
  | Forward_cleanup_authority of evidence
  | Runtime_meta_authority of evidence
  | Revival_transaction_mismatch of
      { keeper_name : string
      ; observed : evidence option
      }

type permit_lifecycle =
  { mutex : Eio.Mutex.t
  ; leases_changed : Eio.Condition.t
  ; mutable open_to_reentrant_leases : bool
  ; mutable active_reentrant_leases : int
  }

type permit =
  { base_path : string
  ; masc_root : string
  ; keeper_name : string
  ; evidence : evidence option
  ; scope_id : int
  ; lifecycle : permit_lifecycle
  }

type permit_lease =
  { permit_scope_id : int
  ; mutable live : bool
  }

type decision =
  | Admitted of evidence option
  | Blocked of blocked_reason

type projection =
  { keeper_name : string
  ; decision : decision
  }

type decoded =
  { evidence : evidence
  ; owner_id : string option
  }

type 'a admission_result =
  | Admission_completed of 'a
  | Admission_completed_with_attention of 'a * authority_failure
  | Admission_blocked of blocked_reason

type 'a permit_lease_result =
  | Permit_lease_completed of 'a
  | Permit_lease_denied
