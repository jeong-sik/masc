(** Private OAS exact-flow resources for one registered Keeper generation. *)

type surface =
  | Compaction
  | Board_attention
  | Hitl_summary
  | Librarian

type t

type evidence_commit_error = Keeper_exact_flow_evidence_journal.commit_error

type measurement_commit_stage =
  | Before_measurement_dispatch
  | Measurement_terminal

type measurement_provenance =
  { operation_id : string
  ; flow_id : string
  ; visit_ordinal : int
  ; candidate_id : string
  ; candidate_binding_sha256 : string
  ; request_body_sha256 : string
  }

type measurement_commit_error =
  { stage : measurement_commit_stage
  ; provenance : measurement_provenance
  ; cause : evidence_commit_error
  }

type setup_error =
  | Owner_not_registered of { keeper_name : string }
  | Owner_draining of { keeper_name : string }
  | Evidence_recovery_blocked of
      { surface : surface
      ; cause : Keeper_exact_flow_evidence_journal.load_error
      }
  | Scope_identity_invalid of { surface : surface }

type release_error =
  | Retirement_deferred
  | Retirement_commit_failed of
      { surface : surface
      ; cause : evidence_commit_error
      }
  | Retirement_in_progress of { surface : surface }
  | Retirement_conflict of { surface : surface }

type 'a current_boundary =
  | Current of 'a
  | Owner_unregistered_deferred

type retirement_boundary =
  | Retirement_draining
  | Retirement_not_allocated
  | Retirement_owner_replaced

val for_registered
  :  registered_lane_id:(unit -> Keeper_lane.Id.t option)
  -> base_path:string
  -> keeper_name:string
  -> surface:surface
  -> (t, setup_error) result

val setup_error_to_string : setup_error -> string
val release_error_to_string : release_error -> string
val evidence_commit_error_to_string : evidence_commit_error -> string
val measurement_commit_error_to_string : measurement_commit_error -> string

val preference_store : t -> Agent_sdk.Exact_output.flow_preference_store
val scope : t -> Agent_sdk.Exact_output.flow_scope

val commit_domain_settlement_intent
  :  t
  -> Agent_sdk.Exact_output.domain_settlement_intent
  -> (unit, evidence_commit_error) result
(** Durable callback for every domain terminal on this exact owner/surface.
    The encoded current OAS intent is committed to the same journal used by
    startup recovery. *)

val commit_measurement_dispatch_intent
  :  t
  -> Agent_sdk.Exact_output.flow_measurement_receipt
  -> (unit, measurement_commit_error) result

val commit_measurement_terminal
  :  t
  -> Agent_sdk.Exact_output.flow_measurement_receipt
  -> (unit, measurement_commit_error) result
(** Persist only the two OAS-owned durable callback boundaries. The central
    scope owns snapshot projection, current-schema encoding, transition
    classification, and journal mutation. *)

val with_current
  :  t
  -> registered_lane_id:(unit -> Keeper_lane.Id.t option)
  -> (unit -> 'a)
  -> 'a current_boundary
(** Acquire a generation-sensitive owner pin under the Keeper lifecycle key
    lock, run the callback after releasing that lock, then release the pin.
    A retired or replaced owner cannot acquire a new pin. *)

val with_settlement
  :  t
  -> registered_lane_id:(unit -> Keeper_lane.Id.t option)
  -> (unit -> 'a)
  -> 'a current_boundary
(** Finish an already-bound generation while its owner is [Active] or
    [Draining]. The lifecycle key lock covers only pin acquisition; callback
    I/O runs outside it. Scope release is deferred until the final pin leaves. *)

val with_librarian_execution_slot
  :  t
  -> capacity:int
  -> (unit -> 'a)
  -> 'a option

val begin_retirement
  :  base_path:string
  -> keeper_name:string
  -> expected_lane_id:Keeper_lane.Id.t
  -> retirement_boundary
(** Atomically stop admission for one registered generation without removing
    its registry identity. Already-bound work may still cross
    {!with_settlement}. *)

val release_owner
  :  base_path:string
  -> keeper_name:string
  -> expected_lane_id:Keeper_lane.Id.t
  -> (unit, release_error) result
(** Retire only the exact registry generation that was removed. Every reserved
    surface commits its current OAS retirement intent before OAS releases the
    scope. A pinned owner returns [Retirement_deferred] and remains alive until
    the last pin runs the same durable retirement boundary. *)

val clear : unit -> unit
