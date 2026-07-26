(** Private concrete state shared by lifecycle nonce helpers. *)

module Head = Fs_compat.Capability_head

type corruption =
  | Invalid_current of string

type error =
  | Invalid_base_path of string
  | Invalid_keeper_id
  | Invalid_owner_id
  | Invalid_floor of int64
  | Authority_missing
  | Authority_identity_mismatch
  | Lifecycle_admission_mismatch
  | Shutdown_floor_invalid of string
  | Filesystem_capability_unavailable
  | Directory_prepare_failed of string
  | Entropy_source_failed of string
  | Corrupt_current of corruption
  | Head_read_failed of Head.failure
  | Head_read_settlement_failed of
      { cursor : Head.cursor
      ; row : string option
      ; observed_nonce : int64 option
      ; warnings : Head.settlement_warning list
      }
  | Head_write_failed of Head.failure
  | Contention_exhausted of
      { attempts : int
      ; last_failure : Head.failure
      }
  | Published_with_warnings of
      { nonce : int64
      ; evidence : Head.publication_evidence
      ; warnings : Head.settlement_warning list
      }
  | Published_with_failure of
      { nonce : int64
      ; failure : Head.failure
      }
  | Publication_indeterminate of
      { nonce : int64
      ; failure : Head.failure
      }
  | Nonce_exhausted
  | Runtime_nonce_out_of_range of int64

type row =
  { keeper_id : string
  ; allocated_to : string
  ; nonce : int64
  ; source_owner_id : string option
  ; source_nonce : int64 option
  }

type identity =
  { owner_id : string
  ; nonce : int64
  }

type create
type replace
type recover_exact

type 'kind witness =
  { base_path : string
  ; keeper_id : string
  ; source : identity option
  ; target : identity
  }

type settled_replace =
  | Settled_allocated of replace witness
  | Settled_recovered of recover_exact witness * error option

type replacement_fault =
  | Publication_settlement_warning
  | Verified_publication_failure
  | Publication_indeterminate
  | Cancellation_after_publication


val replacement_fault_key : replacement_fault Eio.Fiber.key
