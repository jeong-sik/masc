(** Canonical immutable partition data; entropy remains with the ledger owner. *)
module Candidate = Keeper_board_attention_candidate
module Generation = Keeper_board_attention_partition_generation

module Worker_epoch = struct
  type t = Uuidm.t
  let prefix = "board-attention-worker-"

  let of_string value =
    let prefix_length = String.length prefix in
    if String.length value <> prefix_length + 36
       || not (String.equal (String.sub value 0 prefix_length) prefix)
    then Error (Printf.sprintf "invalid Board attention worker epoch: %S" value)
    else
      match Uuidm.of_string (String.sub value prefix_length 36) with
      | Some uuid -> Ok uuid
      | None -> Error (Printf.sprintf "invalid Board attention worker epoch: %S" value)
  ;;

  let to_string value = prefix ^ Uuidm.to_string value
  let equal = Uuidm.equal
end

type completed_item =
  { candidate_id : string
  ; judgment : Candidate.judgment
  }

type exact_provenance =
  { slot_id : string
  ; call_id : string
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  }

type candidate_visit =
  { flow_id : string
  ; ordinal : int
  ; slot_id : string
  ; catalog_generation_fingerprint : string
  ; catalog_evidence_sha256 : string
  ; target_identity_fingerprint : string
  }

type advance_source =
  | Executed_failure of exact_provenance
  | Predispatch_rejection of candidate_visit

type running_progress =
  | Unbound
  | Bound of exact_provenance
  | Advancing of
      { execution_anchor : exact_provenance option
      ; last_from : candidate_visit option
      ; next : candidate_visit
      }

type blocked_reason =
  | Candidate_membership_conflict of string
  | Durable_partition_invariant of string
  | Exact_setup_unavailable of string
  | Exact_flow_replayed of running_progress option
  | Exact_lane_exhausted of
      { detail : string
      ; progress : running_progress option
      }
  | Exact_flow_bookkeeping_failed of
      { detail : string
      ; progress : running_progress option
      }
  | Exact_completion_failed of
      { detail : string
      ; progress : running_progress option
      }
  | Domain_output_invalid of
      { detail : string
      ; progress : running_progress option
      }
  | Execution_provenance_mismatch of
      { detail : string
      ; progress : running_progress option
      }
  | Unexpected_worker_failure of
      { detail : string
      ; progress : running_progress option
      }
  | Exact_execution_quarantined of running_progress
  | Exact_execution_interrupted of running_progress
  | Restored_candidate_quarantine of
      { failure_category : Candidate.quarantine_failure_category
      ; attempt_provenance : Candidate.attempt_provenance option
      }

type running_state =
  { worker_epoch : Worker_epoch.t
  ; started_at : float
  ; progress : running_progress
  }

type state =
  | Ready
  | Running of running_state
  | Completed of
      { item : completed_item
      ; completed_at : float
      }
  | Settled of { settled_at : float }
  | Abandoned of { abandoned_at : float }
  | Blocked of
      { reason : blocked_reason
      ; blocked_at : float
      }

type t =
  { partition_id : string
  ; keeper_name : string
  ; context_key : Candidate.Context_key.t
  ; candidate_id : string
  ; created_at : float
  ; generation : Generation.t
  ; state : state
  }

type exact_write_outcome =
  | Fsync_completed
  | Visible_sync_unconfirmed of string

type exact_transition =
  { partition : t
  ; changed : bool
  ; write_outcome : exact_write_outcome
  }

type requeue_blocked_outcome =
  | Requeued of exact_transition
  | Cursor_conflict of string
  | Generation_conflict of string
