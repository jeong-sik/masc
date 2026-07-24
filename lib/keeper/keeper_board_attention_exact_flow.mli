(** Provider-neutral exact-output execution for one durable Board candidate.

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
  | Flow_admission_failed
  | Flow_start_failed

type attempt_provenance =
  { slot_id : string
  ; call_id : string
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  }
(** Provider-neutral identity of one admitted attempt. It deliberately excludes
    the raw OAS receipt, effect phase, dispatch count, target, and provider
    failure cause. *)

type 'callback_error execution_error =
  | Flow_already_started of attempt_provenance list
  | Before_dispatch_persistence_failed of
      { cause : 'callback_error
      ; current : attempt_provenance
      ; evidence : attempt_provenance list
      }
  | Before_advance_persistence_failed of
      { cause : 'callback_error
      ; failed : attempt_provenance
      ; next : attempt_provenance
      ; evidence : attempt_provenance list
      }
  | Exact_execution_failed of attempt_provenance list
  | Provenance_mismatch of string
  | Domain_output_invalid of string

type prepared

val lane_id : string

(** Admit only an effective resumable pending candidate. Quarantined and
    requeue-requested candidates are not executable; a durably requeued pending
    candidate is executable through the same exact flow as a normal pending one. *)
val prepare :
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
    (failed:attempt_provenance ->
     next:attempt_provenance ->
     (unit, 'callback_error) result) ->
  prepared ->
  ( Keeper_board_attention_candidate.judgment
  , 'callback_error execution_error )
  result
(** Execute the prepared affine flow exactly once. Domain identity and
    provenance failures are terminal results and never request OAS
    advancement. Cancellation is not caught. The caller's durable callback
    progress is the sole terminalization authority and must be quarantined
    under cancellation protection; no OAS receipt state is inspected. *)
(** Cancellation is propagated promptly without protected partition I/O.
    Durable [Bound] or [Advancing] progress is quarantined only by the subsequent
    process-start recovery path. *)
