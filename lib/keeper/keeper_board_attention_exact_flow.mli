(** Opaque-runtime exact-output execution for one durable Board candidate.

    MASC owns the immutable Board input, strict domain decoder, and durable
    callbacks. AGENT_CORE owns lane admission, affine attempts, dispatch, and
    advancement. This interface deliberately exposes no receipt phase or
    dispatch count. *)

type setup_error =
  | Network_unavailable
  | Candidate_not_pending
  | Prompt_contract_unavailable of string
  | Registry_unavailable
  | Lane_unavailable
  | Lane_preference_unavailable of string
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
    AGENT_CORE receipt, effect phase, dispatch count, target, and execution cause. *)

type candidate_visit =
  { flow_id : string
  ; ordinal : int
  ; slot_id : string
  ; catalog_generation_fingerprint : string
  ; catalog_evidence_sha256 : string
  ; target_identity_fingerprint : string
  }
(** Opaque projection of the immutable AGENT_CORE-selected successor visit. No
    execution receipt exists yet, so this type contains no call id, request
    plan, or body hash. *)

type advance_source =
  | Executed_failure of attempt_provenance
  | Predispatch_rejection of candidate_visit
(** Opaque source of one AGENT_CORE-selected advancement. Predispatch rejection
    carries only the immutable candidate visit because no attempt receipt
    exists. *)

type 'callback_error execution_error =
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
  | Providers_exhausted of
      { attempts : attempt_provenance list
      ; detail : string
          (** Why the HTTP walk gave up: the provider error's label and
              payload. The CLI tail, when the lane walks one, reports through
              {!Cli_slots_exhausted} rather than being folded in here. *)
      }
  | Cli_slots_exhausted of
      { prior_error : 'callback_error execution_error option
          (** The HTTP failure the tail was walked after, or [None] on a
              CLI-only lane, which has no HTTP walk. *)
      ; failures : Keeper_lane_cli_oneshot.failure list
          (** One per slot the tail walked, in the order it walked them.
              Kept as the walker's own type: it separates an admission
              refusal from an execution failure from a rejected answer, and
              a reader counting those cannot recover them from a sentence. *)
      }
  | Flow_bookkeeping_failed of
      { attempts : attempt_provenance list
      ; detail : string
          (** An attempt or measurement could not establish its durable
              bookkeeping boundary. No second transport is tried. *)
      }
  | Provenance_mismatch of string
  | Domain_output_invalid of string

type prepared

val lane_id : string

val terminal_of_flow_error
  :  'callback_error Agent_core.Exact_output.flow_execution_error
  -> 'callback_error execution_error
(** Classify every AGENT_CORE flow terminal before deciding whether a second
    transport may run. The closed input and output variants make a new flow
    terminal a compile-time classification request. *)

(** Snapshot only an effective resumable pending candidate. Quarantined and
    requeue-requested candidates are not executable; a durably requeued pending
    candidate is executable through the same exact flow as a normal pending one. *)
val prepare :
  base_path:string ->
  keeper_name:string ->
  net:Eio_context.eio_net option ->
  Keeper_board_attention_candidate.candidate ->
  (prepared, setup_error) result
(** Freeze one complete ordered AGENT_CORE flow. Missing network context fails before
    AGENT_CORE allocates an attempt. *)

val execute :
  ?cli_runner:Keeper_lane_cli_oneshot.runner ->
  clock:_ Eio.Time.clock ->
  before_dispatch:
    (attempt_provenance -> (unit, 'callback_error) result) ->
  before_advance:
    (failed:advance_source ->
     next:candidate_visit ->
     (unit, 'callback_error) result) ->
  prepared ->
  ( Keeper_board_attention_candidate.judgment
  , 'callback_error execution_error )
  result
(** Execute the prepared affine flow exactly once. After semantic exhaustion
    or a typed advanceable final HTTP failure, walk the same frozen lane's
    declared official clients as one-shots ([cli_runner], default the real
    client). Persistence, replay, cancellation, and non-advanceable execution
    failures remain terminal; a CLI-only lane walks its slots directly. The
    run record is closed after the complete lane and names the slot that
    answered. Cancellation is not caught. The caller's durable callback
    progress is the sole terminalization authority and must be quarantined
    under cancellation protection; no AGENT_CORE receipt state is inspected. *)
(** Cancellation is propagated promptly without protected partition I/O.
    Durable [Bound] or [Advancing] progress is quarantined only by the subsequent
    process-start recovery path. *)
