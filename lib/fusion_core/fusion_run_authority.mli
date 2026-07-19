type t
type identity =
  { keeper : string
  ; run_id : string
  }
type replay =
  { topology : Fusion_types.fusion_topology
  ; request : Fusion_types.fusion_request
  }
type registration = { replay : replay; started_at : float }
type uncommitted_stop =
  | Denied of Fusion_types.deny_reason
  | Cancelled of string
  | Aborted of string
  | Interrupted_without_computation_restart
type state_kind = Empty_state | Registered_state | Phase_committed_state
type event_kind = Registration_event | Computation_event | Uncommitted_stop_event
type error =
  | Empty_keeper
  | Empty_run_id
  | Invalid_started_at of float
  | Empty_abort_detail
  | Empty_cancellation_detail
  | Partial_tail
  | Unsupported_schema_version of { line : int; found : int }
  | Invalid_record of { line : int; detail : string }
  | Empty_authority_record
  | Evidence_question_mismatch of { expected : string; found : string }
  | Invalid_transition of
      { event_index : int
      ; state : state_kind
      ; event : event_kind
      }
  | Identity_mismatch of identity
  | Registration_conflict of registration
  | Durable_append_failed of Fs_compat.durable_append_error
val error_to_string : error -> string
type register_outcome =
  | Registered
  | Already_registered of recovered_run
and recovered_run =
  | Registered_run of registration
  | Computation_committed_run of registration * Fusion_types.deliberation_evidence
  | Stopped_without_computation_run of registration * uncommitted_stop
type phase =
  | Computation_committed of Fusion_types.deliberation_evidence
  | Stopped_without_computation of uncommitted_stop
val equal_phase : phase -> phase -> bool
type claim_outcome = First_committed | Already_same | Conflict of phase

type scan_entry_error =
  | Invalid_entry_name of string
  | Entry_disappeared
  | Entry_read_failed of Fs_compat.owned_regular_file_read_error
  | Entry_record_failed of error

type scan_entry =
  { entry_name : string
  ; outcome : (recovered_run, scan_entry_error) result
  }

type scan_outcome =
  | Store_missing
  | Store_scanned of scan_entry list

type directory_io_failure =
  | Directory_unix_error of
      { error : Unix.error
      ; function_name : string
      ; argument : string
      }
  | Directory_sys_error of string

type scan_error =
  | Directory_boundary_rejected of Fs_compat.owned_directory_chain_rejection
  | Directory_inspection_failed of directory_io_failure
  | Directory_inventory_failed of directory_io_failure
  | Directory_identity_changed

(** [directory] is the exact store root resolved by the outer MASC path owner. *)
val create : directory:string -> t

(** [scan t] returns every observed authority entry in deterministic filename
    order. One unreadable or invalid entry is retained as an explicit error and
    does not hide valid peers. [Store_missing] means that no run has created the
    injected store directory yet. *)
val scan : t -> (scan_outcome, scan_error) result

val register
  :  t
  -> topology:Fusion_types.fusion_topology
  -> request:Fusion_types.fusion_request
  -> started_at:float
  -> (register_outcome, error) result
val commit_phase
  :  t
  -> keeper:string
  -> run_id:string
  -> phase
  -> (claim_outcome, error) result
