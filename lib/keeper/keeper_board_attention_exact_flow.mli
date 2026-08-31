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
  | Exact_execution_failed of attempt_provenance list
  | Provenance_mismatch of string
  | Domain_output_invalid of string

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
(** Freeze one complete ordered AGENT_CORE flow. Missing network context fails before
    AGENT_CORE allocates an attempt. *)

type cli_tail_error =
  | No_cli_slots
  | Cli_slots_exhausted of Keeper_lane_cli_oneshot.failure list
  | Cli_output_invalid of
      { slot_id : string
      ; detail : string
      }

val cli_tail_error_to_string : cli_tail_error -> string

val cli_slots : prepared -> string list
(** The lane's declared official-client tail, in declaration order. Empty when
    the lane declares none. *)

val run_cli_tail :
  ?runner:Keeper_lane_cli_oneshot.runner ->
  base_path:string ->
  prepared ->
  ( string * Keeper_board_attention_candidate.judgment
  , cli_tail_error )
  result
(** Walk [cli_slots] as one-shots and return the first slot whose answer judges
    this candidate, as [(slot_id, judgment)].

    Call this only after {!execute} reported [Exact_execution_failed], which is
    the provider-exhaustion arm. The persistence and provenance arms keep their
    terminal: they say the durable record is in doubt, and a second transport
    does not settle that (RFC cli-runtimes-as-lane-slots, the same split the
    librarian and HITL lanes apply).

    The judgment carries [Cli_lane_slot], so completing with it is checked
    against an exhausted exact binding rather than against an attempt receipt
    that does not exist. *)

val execute :
  ?clock:_ Eio.Time.clock ->
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
(** Execute the prepared affine flow exactly once. Domain identity and
    provenance failures are terminal results and never request AGENT_CORE
    advancement. Cancellation is not caught. The caller's durable callback
    progress is the sole terminalization authority and must be quarantined
    under cancellation protection; no AGENT_CORE receipt state is inspected. *)
(** Cancellation is propagated promptly without protected partition I/O.
    Durable [Bound] or [Advancing] progress is quarantined only by the subsequent
    process-start recovery path. *)
