(** Opaque-runtime exact-output execution for one durable Board candidate.

    MASC owns the immutable Board input, strict domain decoder, and durable
    callbacks. OAS owns lane admission, affine attempts, dispatch, and
    advancement. This interface deliberately exposes no receipt phase or
    dispatch count. *)

type setup_error =
  | Network_unavailable
  | Candidate_not_pending
  | Prompt_contract_unavailable of string
  | Registry_unavailable
  | Lane_unavailable
  | Lane_resolved_without_slots
  | Candidate_invalid of
      { position : int
      ; slot_id : string
      }
  | Flow_snapshot_failed
  | Flow_start_failed

type attempt_provenance =
  { slot_id : string
  ; call_id : string
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  }
(** Opaque identity of one admitted attempt. It deliberately excludes the raw
    OAS receipt, effect phase, dispatch count, target, and execution cause. *)

type candidate_visit =
  { flow_id : string
  ; ordinal : int
  ; slot_id : string
  ; catalog_generation_fingerprint : string
  ; catalog_evidence_sha256 : string
  ; target_identity_fingerprint : string
  }
(** Opaque projection of the immutable OAS-selected successor visit. No
    execution receipt exists yet, so this type contains no call id, request
    plan, or body hash. *)

type advance_source =
  | Executed_failure of attempt_provenance
  | Predispatch_rejection of candidate_visit
(** Opaque source of one OAS-selected advancement. Predispatch rejection
    carries only the immutable candidate visit because no attempt receipt
    exists. *)

type domain_rejection =
  | Execution_provenance_mismatch of string
  | Invalid_domain_output of string

type domain_terminal =
  | Domain_valid of Keeper_board_attention_candidate.judgment
  | Domain_rejected of domain_rejection
(** Closed provider-neutral Board terminal passed to the caller's durable
    commit boundary. No OAS preference changes before this terminal and the
    current settlement intent are durable. *)

type 'callback_error execution_error =
  | Owner_unregistered_deferred
  | Flow_already_started of attempt_provenance list
  | Before_dispatch_persistence_failed of
      { cause : 'callback_error
      ; current : attempt_provenance
      ; evidence : attempt_provenance list
      }
  | Before_advance_persistence_failed of
      { cause : 'callback_error
      ; failed : advance_source
      ; next : candidate_visit
      ; evidence : attempt_provenance list
      }
  | Exact_execution_failed of attempt_provenance list
  | Provenance_mismatch of string
  | Domain_output_invalid of string
  | Domain_terminal_persistence_failed of
      { terminal : domain_terminal
      ; cause : 'callback_error
      }
  | Domain_settlement_intent_persistence_failed of
      { terminal : domain_terminal
      ; cause : Keeper_exact_flow_scope.evidence_commit_error
      }
  | Domain_settlement_in_progress of domain_terminal
  | Domain_settlement_conflict of domain_terminal
  | Measurement_dispatch_persistence_failed of
      { cause : Keeper_exact_flow_scope.measurement_commit_error
      ; evidence : attempt_provenance list
      }
  | Measurement_terminal_persistence_failed of
      { cause : Keeper_exact_flow_scope.measurement_commit_error
      ; evidence : attempt_provenance list
      }
  | Callback_boundary_mismatch

type prepared

val lane_id : string

(** Snapshot only an effective resumable pending candidate. Quarantined and
    requeue-requested candidates are not executable; a durably requeued pending
    candidate is executable through the same exact flow as a normal pending one. *)
val prepare :
  base_path:string ->
  keeper_name:string ->
  net:Eio_context.eio_net option ->
  Keeper_board_attention_candidate.candidate ->
  (prepared, setup_error) result
(** Freeze one complete ordered OAS flow. Missing network context fails before
    OAS allocates an attempt. *)

val execute :
  ?clock:_ Eio.Time.clock ->
  before_dispatch:
    (attempt_provenance -> (unit, 'callback_error) result) ->
  before_advance:
    (failed:advance_source ->
     next:candidate_visit ->
     (unit, 'callback_error) result) ->
  commit_domain:
    (domain_terminal -> (unit, 'callback_error) result) ->
  prepared ->
  ( Keeper_board_attention_candidate.judgment
  , 'callback_error execution_error )
  result
(** Execute the prepared affine flow exactly once. Domain identity and
    provenance failures are terminal results and never request OAS
    advancement. [commit_domain] must idempotently persist the closed Board
    terminal. The adapter then persists the opaque current OAS settlement
    intent through the owner scope before OAS may apply a preference.
    Cancellation is not caught; committed current-schema evidence is recovered
    by the scope journal and no OAS receipt state is inspected. *)
(** Cancellation is propagated promptly without protected partition I/O.
    Durable [Bound] or [Advancing] progress is quarantined only by the subsequent
    process-start recovery path. *)

val with_current_generation
  :  prepared
  -> (unit -> 'a)
  -> 'a Keeper_exact_flow_scope.current_boundary
(** Fence a local durable projection against Keeper owner replacement. The
    callback must not perform network I/O or re-enter the lifecycle key lock. *)

val with_settlement_generation
  :  prepared
  -> (unit -> 'a)
  -> 'a Keeper_exact_flow_scope.current_boundary
(** Fence the terminal durable projection of an already-bound attempt. Unlike
    admission, this remains available while shutdown is draining the owner. *)
