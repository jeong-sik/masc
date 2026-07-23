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
    when it is safe to drain the next owner-FIFO entry. Eio cancellation is a
    caller-directed structured abort, so it terminally quarantines the active
    attempt regardless of receipt phase/count and never releases or fails over.
    Missing exact request context is permanent and reported as non-retryable;
    transient preparation failures remain retryable. *)
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

  type lifecycle_write =
    | Lifecycle_fsync_completed
    | Lifecycle_visible_unconfirmed of string
    | Lifecycle_write_error of string

  type lifecycle_execution =
    | Lifecycle_success of
        { observation : attempt_observation
        ; output : Yojson.Safe.t
        }
    | Lifecycle_provenance_mismatch of attempt_observation
    | Lifecycle_replay of attempt_observation
    | Lifecycle_before_dispatch_failure of
        { observation : attempt_observation
        ; reason : string
        }
    | Lifecycle_post_dispatch_failure of attempt_observation
    | Lifecycle_cancellation of
        { observation : attempt_observation
        ; cancellation : exn
        }

  type 'candidate lifecycle_candidate =
    { initial_observation : attempt_observation
    ; candidate : 'candidate
    }

  type lifecycle_result =
    { continue_owner : bool
    ; cancellation : exn option
    }

  type 'candidate lifecycle_effects =
    { bind : attempt_observation -> lifecycle_write
    ; release : attempt_observation -> lifecycle_write
    ; fail : attempt_observation -> reason:string -> lifecycle_write
    ; quarantine :
        attempt_observation ->
        Keeper_approval_queue.exact_attempt_quarantine_cause ->
        lifecycle_write
    ; complete :
        attempt_observation ->
        Keeper_approval_queue.hitl_context_summary ->
        lifecycle_write
    ; execute : 'candidate -> lifecycle_execution
    ; parse :
        model_run_id:string ->
        Yojson.Safe.t ->
        (Keeper_approval_queue.hitl_context_summary, string) result
    ; on_summary : Keeper_approval_queue.hitl_context_summary -> unit
    ; record_outcome : string -> unit
    ; protect : (unit -> bool) -> bool
    ; report_write_issue :
        operation:string ->
        attempt_observation ->
        detail:string ->
        unit
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
  val preparation_error_retryable : preparation_error -> bool
  val observations : prepared_lane -> attempt_observation list
  val is_before_dispatch_zero : Agent_sdk.Exact_output.receipt -> bool
  val provenance_evidence_matches : provenance_evidence -> provenance_evidence -> bool
  val run_lifecycle
    :  effects:'candidate lifecycle_effects
    -> 'candidate lifecycle_candidate list
    -> lifecycle_result
  val summary_version : int
end
