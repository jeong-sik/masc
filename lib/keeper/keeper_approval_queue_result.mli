(** Typed outcomes, refusal classification and operator projections for the
    durable approval queue. This contract contains no persistence or dispatch. *)

open Keeper_approval_queue_rules_types

type storage_error =
  { path : string
  ; reason : string
  }

type summary_transition_rejection =
  | Summary_exact_attempt_bound of exact_attempt_binding

type summary_transition_error =
  | Summary_transition_storage_error of storage_error
  | Summary_transition_rejected of summary_transition_rejection

type summary_owner_retirement_error =
  | Summary_owner_retirement_storage_error of storage_error
  | Summary_owner_retirement_exact_attempt_unsettled of exact_attempt_binding

type exact_attempt_rejection =
  | Exact_attempt_not_found of string
  | Exact_attempt_key_mismatch of
      { approval_id : string
      ; input_hash : string
      ; sequence : int
      }
  | Exact_attempt_invalid_identity of string
  | Exact_attempt_summary_not_pending of string
  | Exact_attempt_unbound_state of string
  | Exact_attempt_disposition_conflict of
      { approval_id : string
      ; disposition : summary_attempt_disposition
      }
  | Exact_attempt_identity_conflict of exact_attempt_binding
  | Exact_attempt_status_conflict of exact_attempt_binding
  | Exact_attempt_provenance_mismatch of
      { approval_id : string
      ; expected_call_id : string
      ; actual_model_run_id : string
      }
  | Exact_attempt_content_conflict of string

type exact_attempt_error =
  | Exact_attempt_storage_error of storage_error
  | Exact_attempt_rejected of exact_attempt_rejection

type exact_write_outcome =
  Keeper_event_queue_persistence.exact_write_outcome =
  | Fsync_completed
  | Visible_sync_unconfirmed of string

type exact_attempt_transition =
  { changed : bool
  ; write_outcome : exact_write_outcome
  }
(** Exact writes share the Keeper runtime durability outcome SSOT.
    [Fsync_completed] is the only outcome that permits an AGENT_CORE POST, slot
    failover, or automatic Gate finalization. [Visible_sync_unconfirmed _]
    means the rename is visible and the process projection has converged, but
    parent-directory fsync was not confirmed; callers must not cross those
    boundaries and may idempotently rewrite the same identity. A cancellation
    before rename is re-raised with memory unchanged. A cancellation observed
    after rename returns [Visible_sync_unconfirmed _] so visible file and memory
    remain convergent. *)

type approved_resolution_request =
  { keeper_name : string
  ; tool_name : string
  ; input : Yojson.Safe.t
  }

type grant_error =
  | Grant_store_unavailable of storage_error
  | Grant_replay_projection_unavailable of storage_error
  | Grant_workspace_mismatch of
      { approval_id : string
      ; requested_base_path : string
      ; stored_base_path : string
      }
  | Grant_still_pending of string
  | Grant_resolution_not_approved of string
  | Grant_resolution_missing of string
  | Grant_replay_not_consumed of string
  | Grant_replay_outcome_conflict of string

(** What the durable Gate store says when a queued approved resolution has
    nothing behind it. Each constructor is a fact about the store, not a read
    failure: reading again on the next turn returns the same answer, so the
    queued resolution has nothing to replay and is retired. Read failures
    stay in [grant_error] and remain actionable. *)
type resolution_absence =
  | Resolution_missing
      (** neither a delivery row nor a pending row carries the id; the store
          was reset or the row was removed after the resolution was queued *)
  | Resolution_still_pending
      (** the store holds the id unresolved while the queue already carries
          its resolution *)
  | Resolution_not_approved
      (** the store recorded a rejection for an id the queue carries as
          approved *)
  | Resolution_workspace_mismatch of { stored_base_path : string }

type approved_resolution_state =
  | Resolution_unconsumed
  | Resolution_consumed

type resolution_replay_outcome =
  | Replay_applied of Tool_output.artifact_ref
  | Replay_applied_with_warning of Tool_output.artifact_ref
  | Replay_failed of Tool_output.artifact_ref
  | Replay_indeterminate of Tool_output.artifact_ref
(** Derived replay evidence points to exact bytes in {!Tool_blob_store}. The
    Gate sidecar owns only this typed content address. The current provider
    input rehydrates the full payload at the caller-owned projection boundary;
    the assigned Runtime measures and admits that exact projected request.
    Canonical history and checkpoints retain the reference, not a duplicate
    payload or a size-dependent preview.
    [Replay_indeterminate] is terminal and fail-closed: the effect may already
    have happened, so it must never be replayed. *)

type approved_resolution_delivery =
  { request : approved_resolution_request
  ; state : approved_resolution_state
  ; replay_outcome : resolution_replay_outcome option
  }

type grant_consumption =
  | Consumption_committed of Keeper_approval.Audit.receipt
  | Consumption_already_committed
  | Consumption_not_matching

type pending_submission_disposition =
  | Pending_created of Keeper_approval.Audit.receipt
  | Pending_deduplicated
  | Folded_onto_unconsumed_grant
      (** The same effect request is already approved and its one-shot grant
          has not been consumed: the host owes the Keeper a replay of exactly
          this call, so no second approval is opened. Rejected and
          grant-consumed deliveries never fold — those retries are a new
          approval cycle and a new effect respectively. *)

type pending_submission =
  { approval_id : string
  ; disposition : pending_submission_disposition
  }

type replay_recording =
  | Replay_recorded
  | Replay_already_recorded

type delivery_replay_failure =
  { approval_id : string
  ; reason : string
  }

type install_report =
  { loaded_pending : int
  ; replayed_deliveries : int
  ; delivery_replay_failures : delivery_replay_failure list
  ; replay_projection_error : storage_error option
  ; retired_deliveries : int
  ; delivery_retirement_error : storage_error option
  }

type install_error = Install_storage_failed of storage_error

val storage_error_to_string : storage_error -> string
val approval_queue_unavailable_title : string
val approval_queue_unavailable_severity : string
val approval_queue_ready_state_json : Yojson.Safe.t
val approval_queue_unavailable_state_json : storage_error -> Yojson.Safe.t
val summary_transition_error_to_string : summary_transition_error -> string
val summary_owner_retirement_error_to_string :
  summary_owner_retirement_error -> string
val exact_attempt_error_to_string : exact_attempt_error -> string
val grant_error_to_string : grant_error -> string

val resolution_absence_of_grant_error : grant_error -> resolution_absence option
(** [Some] for the store answers that say there is no resolution behind an
    approval id; [None] for read failures and for producer-side replay
    conflicts, which are not statements about the resolution's existence. *)

val resolution_absence_to_string : resolution_absence -> string
val install_error_to_string : install_error -> string


type resolution_result =
  { remembered_rule : approval_rule option
  ; audit_receipts : Keeper_approval.Audit.receipt list
  }


val summary_attempt_start_reserved_operator_detail : string
