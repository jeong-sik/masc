(** MASC-owned compaction planning over the provider-neutral OAS exact-output
    surface. Target selection, admission, wire serialization, credentials, and
    dispatch receipts remain OAS-owned. *)

type compaction_plan

type exact_execution_evidence

type completed_plan

type prepared_lane

type attempt_observation =
  { slot_id : string
  ; call_id : string
  ; phase : Agent_sdk.Exact_output.effect_phase
  ; dispatch_count : int
  ; catalog_generation_fingerprint : string
  ; receipt_plan_fingerprint : string
  ; receipt_request_body_sha256 : string
  }

type summarization_failure =
  | Exact_lane_unconfigured
  | Exact_target_selection_failed
  | Exact_admission_failed
  | Exact_attempt_start_failed of string
  | Exact_execution_context_unavailable
  | Exact_execution_failed_before_dispatch
  | Exact_execution_failed_after_dispatch of attempt_observation
  | Exact_attempt_already_started of attempt_observation
  | Exact_execution_cancelled_after_dispatch of attempt_observation
  | Exact_execution_provenance_mismatch of attempt_observation
  | Invalid_plan
  | Invalid_plan_after_dispatch of attempt_observation

type summarizer =
  units:Keeper_compaction_unit.closed_unit list ->
  (completed_plan, summarization_failure) result

(** Pure lane lookup, selection, and admission against exactly one
    caller-supplied immutable registry. Every candidate is considered in
    declaration order, all admitted plans and their real receipts are retained
    before any network effect, and the returned lane is abstract so callers
    cannot replace ready plans. *)
val prepare_lane
  :  keeper_name:string
  -> registry:Runtime_exact_output_registry.t
  -> lane_id:string
  -> units:Keeper_compaction_unit.closed_unit list
  -> (prepared_lane, summarization_failure) result

(** Execute each retained OAS attempt at most once. Only a real receipt at
    [Before_dispatch] with dispatch count zero advances to the next slot.
    Pre-dispatch cancellation is re-raised. Post-dispatch cancellation,
    duplicate execution, provenance mismatch, dispatched failure, and a
    MASC-invalid domain plan are typed terminal outcomes and never fail over. *)
val execute_prepared_lane
  :  keeper_name:string
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> ?clock:_ Eio.Time.clock
  -> prepared_lane
  -> (completed_plan, summarization_failure) result

(** Resolve [compaction_exact] from one published immutable registry, admit all
    resolved slots for valid JSON syntax before dispatch, then execute each
    admitted plan at most once. OAS guarantees JSON syntax; [plan_of_json]
    enforces the MASC-owned compaction schema and domain rules. Invalid domain
    output is terminal and never advances to another slot. Only a receipt still
    at [Before_dispatch] with dispatch count zero permits advancing. *)
val make : keeper_name:string -> unit -> summarizer option

val has_eligible_units : Keeper_compaction_unit.closed_unit list -> bool

val plan_of_json
  :  units:Keeper_compaction_unit.closed_unit list
  -> Yojson.Safe.t
  -> (compaction_plan, string) result

val completed_plan : completed_plan -> compaction_plan
val completed_exact_execution_evidence : completed_plan -> exact_execution_evidence
val exact_execution_evidence_slot_id : exact_execution_evidence -> string
val exact_execution_evidence_call_id : exact_execution_evidence -> string
val exact_execution_evidence_target_identity_fingerprint : exact_execution_evidence -> string
val exact_execution_evidence_catalog_generation_fingerprint : exact_execution_evidence -> string
val exact_execution_evidence_catalog_evidence_sha256 : exact_execution_evidence -> string
val exact_execution_evidence_plan_fingerprint : exact_execution_evidence -> string
val exact_execution_evidence_receipt_plan_fingerprint : exact_execution_evidence -> string
val exact_execution_evidence_receipt_request_body_sha256 : exact_execution_evidence -> string
val apply : compaction_plan -> Agent_sdk.Types.message list
val summarized_indices : compaction_plan -> int list
val dropped_indices : compaction_plan -> int list
val has_changes : compaction_plan -> bool

module For_testing : sig
  val messages_for_plan
    :  units:Keeper_compaction_unit.closed_unit list
    -> Agent_sdk.Types.message list

  val admitted_slot_ids : prepared_lane -> string list

  val attempt_observations : prepared_lane -> attempt_observation list
end
