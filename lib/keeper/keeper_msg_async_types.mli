(** Canonical immutable request state and outcomes. *)
type request_status =
  | Queued
  | Running
  | Cancelling of
      { reason : string
      ; cancelled_by : string
      }
  | Lost of { reason : string }
  | Cancelled of
      { reason : string
      ; cancelled_by : string
      }
  | Persistence_failed of
      { attempted_status : string
      ; reason : string
      }
  | Done of
      { ok : bool
      ; body : string
      ; data : Yojson.Safe.t option
      }

type entry =
  { request_id : string
  ; keeper_name : string
  ; base_path : string
  ; submitted_by : string
  ; request_context : (string * Yojson.Safe.t) list option
  ; status : request_status
  ; submitted_at : float
  ; completed_at : float option
  }

type access_rejection =
  | Invalid_base_path of { reason : string }
  | Invalid_caller
  | Invalid_request_id
  | Caller_mismatch

(** Outcome of looking up a request record. [Absent] means no accepted record
    exists for this identity (or it was explicitly removed); it is not evidence
    that resubmission is safe.
    [Unreadable] means a record file exists but cannot be decoded — the
    request WAS accepted, but its result cannot be recovered. *)
type load_result =
  | Found of entry
  | Absent
  | Unreadable of string
  | Rejected of access_rejection

type active_inventory_store_error =
  | Inventory_access_rejected of access_rejection
  | Inventory_directory_rejected of Fs_compat.owned_directory_chain_rejection
  | Inventory_directory_read_failed of
      { path : string
      ; reason : string
      }

type active_inventory_record_error_kind =
  | Invalid_record_name
  | Record_missing
  | Record_not_regular of Unix.file_kind
  | Record_unreadable of string
  | Record_inspection_failed of { reason : string }
  | Record_terminal_status of request_status

type active_inventory_record_error =
  { path : string
  ; request_id : string option
  ; kind : active_inventory_record_error_kind
  }

type durable_active_inventory =
  { entries : entry list
  ; record_errors : active_inventory_record_error list
  }

type durable_terminal_proof = { terminal_entry : entry }

type canonical_terminal_error =
  | Canonical_terminal_absent
  | Canonical_terminal_unreadable of string
  | Canonical_terminal_access_rejected of access_rejection
  | Canonical_terminal_runtime_active of request_status
  | Canonical_terminal_publication_ambiguous of request_status
  | Canonical_terminal_nonterminal of request_status
  | Canonical_terminal_noncanonical_location of request_status

type recovery_report =
  { lost : int
  ; finalized : int
  ; cleaned : int
  ; staging_files_inspected : int
  ; staging_files_deleted : int
  ; staging_files_preserved : int
  ; unreadable : int
  ; failed : int
  ; store_errors : recovery_store_error list
  ; record_errors : recovery_record_error list
  }

and recovery_store =
  | Active_store
  | Atomic_staging_store

and recovery_store_error =
  { store : recovery_store
  ; path : string
  ; reason : string
  }

and recovery_record_error =
  { store : recovery_store
  ; path : string
  ; request_id : string
  ; keeper_name : string option
  ; kind : recovery_record_error_kind
  }

and recovery_record_error_kind =
  | Recovery_record_unreadable of string
  | Recovery_record_missing
  | Recovery_record_not_file
  | Recovery_record_rejected of access_rejection
  | Recovery_terminal_integrity of string
  | Recovery_persistence_failed of string
  | Recovery_source_cleanup_failed
  | Recovery_entry_exception of string

type submit_error =
  | Submit_lane_unavailable of
      { lane : string
      ; wait_budget_sec : float
      }
  | Submit_rejected of access_rejection
  | Submit_invalid_keeper_name of { reason : string }
  | Submit_invalid_request_context of { reason : string }
  | Initial_persistence_failed of { reason : string }
  | Acceptance_persistence_failed of
      { request_id : string
      ; reason : string
      }
  | Background_switch_unavailable of { reason : string }
  | Background_fork_failed of
      { request_id : string
      ; reason : string
      }

type submission_acceptance =
  | Durably_accepted
  | Reconciliation_required of { reason : string }

type submit_outcome =
  { request_id : string
  ; acceptance : submission_acceptance
  }

type persistence_durability =
  | Durably_committed
  | Published_unconfirmed of { reason : string }

type cancel_result =
  | Cancellation_requested of persistence_durability
  | Cancel_not_found
  | Cancel_unreadable of string
  | Cancel_rejected of access_rejection
  | Cancel_worker_ownership_unknown of request_status
  | Cancel_already_terminal of request_status
  | Cancel_persistence_failed of { reason : string }
  | Cancel_worker_signal_failed of
      { durability : persistence_durability
      ; reason : string
      }
  | Cancel_state_invariant_failed of { reason : string }

(* [Worker_cancelled], not [Cancelled]: [request_status] above already binds
   an unqualified [Cancelled] constructor with the same field names in this
   module. A same-named constructor here would shadow it for every
   unqualified use below and risk silently constructing the wrong type. *)
type worker_cancel_source =
  | Operator_request
  | Runtime_cancellation

type worker_abort_reason =
  | Worker_cancelled of
      { cancelled_by : worker_cancel_source
      ; reason : string
      }

type settlement_durability =
  | Durable
  | Volatile_persistence_failure

type settlement_origin =
  | Transition_commit
  | Canonical_reconciliation

type worker_settlement =
  | Status_settlement of
      { entry : entry
      ; durability : settlement_durability
      ; origin : settlement_origin
      }
  | Settlement_projection_error of
      { attempted_entry : entry
      ; poll_result : load_result
      }
