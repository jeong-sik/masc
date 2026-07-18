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
  | Succeeded of string
  | Failed of
      { code : string
      ; detail : string
      }
  | Cancelled of string
val equal_terminal : terminal -> terminal -> bool
type error =
  | Empty_keeper
  | Empty_run_id
  | Invalid_started_at of float
  | Empty_success_answer
  | Empty_failure_code
  | Empty_failure_detail
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
  | Read_failed of Fs_compat.owned_regular_file_read_error
type register_outcome =
  | Registered
  | Already_running
  | Already_settled of terminal
type claim_outcome =
  | First_committed
  | Already_same
  | Conflict of terminal
(** [directory] is the exact store root resolved by the outer MASC path owner. *)
val create : directory:string -> t
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
