type t
type identity =
  { keeper : string
  ; run_id : string
  }
type registration =
  { identity : identity
  ; preset : string
  ; started_at : float
  }
type terminal =
  | Deliberated of Fusion_types.deliberation_evidence
  | Aborted of string
  | Cancelled of string
  | Interrupted_after_restart
val equal_terminal : terminal -> terminal -> bool
type error =
  | Empty_keeper
  | Empty_run_id
  | Invalid_started_at of float
  | Empty_abort_detail
  | Empty_cancellation_detail
  | Partial_tail
  | Unsupported_schema_version of { line : int; found : int }
  | Invalid_record of { line : int; detail : string }
  | Orphan_terminal
  | Reversed_records
  | Unexpected_sequence of int
  | Identity_mismatch of identity
  | Registration_conflict of registration
  | Durable_append_failed of Fs_compat.durable_append_error
type register_outcome =
  | Registered
  | Already_running
  | Already_settled of terminal
type claim_outcome =
  | First_committed
  | Already_same
  | Conflict of terminal

type recovered_run =
  | Running_run of registration
  | Settled_run of
      { registration : registration
      ; terminal : terminal
      }

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
  -> keeper:string
  -> run_id:string
  -> preset:string
  -> started_at:float
  -> (register_outcome, error) result
val claim_terminal
  :  t
  -> keeper:string
  -> run_id:string
  -> terminal
  -> (claim_outcome, error) result
