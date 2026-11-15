(** RFC-0489 §2.3 — Goal-side phase view over the shared lane-addon request
    progress. [Rejected], [Subdividing] and [Subdivided] carry the typed
    refusal instead of raw evidence JSON, so a consumer cannot reject an
    evidence shape it does not know: the view either produces a variant of
    this closed sum or the consumer never sees the phase. The Goal worker,
    its host and the Goal verification agent match only this view; direct
    [Lane_addon_request_progress.phase] matching stays inside this module.

    Layer 1 keeps observable behavior unchanged: the deep evidence checks
    (receipt against its original, before-dispatch change against its
    original authority binding) stay at their current call sites in the
    worker and run on the payloads carried here. [reviewer_refusal] and
    [Authority_moved.detail] preserve the exact evidence a refusal stands
    for so those checks read the same bytes as before. *)

type run_identity = { run_id : string; started_at : float }

type observation = Waiting of Yojson.Safe.t | Outcome_unknown of Yojson.Safe.t
  | Absent of Yojson.Safe.t

type run_end = Cancelled | Raised | Retention_failed
(** Why a dispatched run ended without a verdict. [Cancelled] and [Raised]
    are today's interruption causes; [Retention_failed] names the case where
    the refusal write itself did not survive (§2.2). Produced from layer 3. *)

type reviewer_refusal = { evidence : Yojson.Safe.t }
(** What [goal_verifier_refusal/v1] carries today. The receipt and
    disposition inside stay opaque here; the worker authenticates them
    against its original at the same call sites as before. *)

type refusal =
  | Reviewer_refused of reviewer_refusal
      (** The reviewer answered without a Goal verdict; the evidence is the
          existing [goal_verifier_refusal/v1] object. *)
  | Run_ended of {
      cause : run_end
    ; run : run_identity
    ; tools : Verification_run_registry.tool_observation list
    ; observations : Yojson.Safe.t list
    }
      (** The run ended without saving a verdict; what it observed is carried
          exactly as [Outcome_unknown] carried it. Produced from layer 3. *)
  | Owner_exited of { run : run_identity }
      (** The original was [Dispatch_pending] with no live owner (§2.6).
          Produced from layer 3. *)
  | Authority_moved of { detail : string }
      (** A before-dispatch refusal's change evidence, preserved verbatim.
          The worker re-reads it to authenticate the change against its
          original. Layer 4 writes new ones. *)

type stage = Before_dispatch | Execution

type phase =
  | Captured
  | Admission_wait of Yojson.Safe.t
  | Dispatch_pending of observation option
  | Judged of Yojson.Safe.t
  | Committing of Lane_addon_request_progress.commit
  | Commit_unknown of Lane_addon_request_progress.commit * Yojson.Safe.t
  | Finished of Lane_addon_request_progress.commit
  | Conflicted of Lane_addon_request_progress.commit * Yojson.Safe.t
  | Rejected of { stage : stage; refusal : refusal }
  | Subdividing of refusal * Lane_addon_request_progress.successor
  | Subdivided of refusal * Lane_addon_request_progress.successor

val view : Lane_addon_request_progress.phase -> phase
(** Total: every Progress phase maps to exactly one Goal-side phase, so a
    consumer never sees a phase it cannot handle. *)

val run_end_label : run_end -> string
val run_end_of_label : string -> (run_end, string) result

val run_json : run_identity -> Yojson.Safe.t
val run_of_json : Yojson.Safe.t -> (run_identity, string) result

val evidence_json : refusal -> Yojson.Safe.t
(** The evidence bytes a refusal stands for: the reviewer refusal's stored
    object, the before-dispatch change parsed back from [detail], or the
    [goal_verifier_unknown/v1]-shaped observation of a lost run. *)
