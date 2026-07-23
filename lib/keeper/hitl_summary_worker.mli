val lane_id : string
(** Stable OAS exact-output lane used by automatic HITL judgment. *)

(** Verify that the registry-owned Gate judgment prompt is renderable and that
    the published immutable exact-output registry resolves at least one usable
    [hitl_auto_judge] slot. *)
val readiness : unit -> (unit, string) result

(** Prepare every usable lane candidate before launching the fiber, durably bind
    each immutable attempt before its sole OAS POST, and call [on_summary] only
    after provenance/domain validation and an fsync-confirmed completion.
    [on_finish] always releases the owner claim; [continue_owner] is true only
    when it is safe to drain the next owner-FIFO entry. *)
val spawn
  :  sw:Eio.Switch.t
  -> entry:Keeper_approval_queue.pending_approval
  -> on_summary:(Keeper_approval_queue.hitl_context_summary -> unit)
  -> on_failure:(reason:string -> retryable:bool -> unit)
  -> on_finish:(continue_owner:bool -> unit)
  -> unit
  -> unit

module For_testing : sig
  val lane_id : string
  val system_prompt : unit -> (string, string) result

  type context_bundle_error = Exact_request_context_unavailable

  val build_context_bundle
    :  entry:Keeper_approval_queue.pending_approval
    -> (Yojson.Safe.t, context_bundle_error) result

  val context_bundle_error_to_string : context_bundle_error -> string

  val messages_for_summary
    :  system_prompt:string
    -> context_bundle:Yojson.Safe.t
    -> Agent_sdk.Types.message list

  val parse_summary
    :  generated_at:float
    -> model_run_id:string
    -> Yojson.Safe.t
    -> (Keeper_approval_queue.hitl_context_summary, string) result

  type attempt_observation =
    { slot_id : string
    ; call_id : string
    ; phase : Agent_sdk.Exact_output.effect_phase
    ; dispatch_count : int
    ; plan_fingerprint : string
    ; request_body_sha256 : string
    ; catalog_generation_fingerprint : string
    ; catalog_evidence_sha256 : string
    ; target_identity_fingerprint : string
    }

  type prepared_lane

  type provenance_evidence =
    { source_schema_fingerprint : string
    ; effective_schema_fingerprint : string option
    ; actual_assurance : Agent_sdk.Exact_output.actual_assurance
    ; catalog_generation_fingerprint : string
    ; catalog_evidence_sha256 : string
    ; target_identity_fingerprint : string
    }

  type preparation_error =
    | Context_unavailable of context_bundle_error
    | Prompt_unavailable of string
    | Lane_unavailable of string
    | Admission_rejected of string

  val prepare_lane
    :  registry:Runtime_exact_output_registry.t
    -> entry:Keeper_approval_queue.pending_approval
    -> (prepared_lane, preparation_error) result

  val preparation_error_to_string : preparation_error -> string
  val observations : prepared_lane -> attempt_observation list
  val is_before_dispatch_zero : Agent_sdk.Exact_output.receipt -> bool
  val provenance_evidence_matches : provenance_evidence -> provenance_evidence -> bool
  val summary_version : int
end
