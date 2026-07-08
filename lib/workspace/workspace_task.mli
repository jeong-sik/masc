(** Workspace_task -- Task lifecycle: add, claim, transition, complete, cancel.

    This module is [include]d by {!Workspace}; all bindings are part of
    the public Workspace interface.  Re-exports {!Workspace_utils} and
    {!Workspace_state}.

    The implementation is split across three sub-modules that are
    re-exported via [include]:
    - {!Workspace_task_classify} — state classification, task actor kind,
      working agents, event helpers
    - {!Workspace_task_create} — dedup logic, add_task, batch_add_tasks
    - {!Workspace_task_claim} — claim_task, claim_task_r, release/reclaim
      helpers *)

include module type of Workspace_utils
include module type of Workspace_state

(** {1 Sub-module re-exports} *)

include module type of Workspace_task_classify
include module type of Workspace_task_create
include module type of Workspace_task_claim

(** {1 Task transitions} *)

(** Typed transition result. [noop = true] marks the idempotent case
    (e.g. release on an already-Todo task): status unchanged, no
    write/events. RFC-0088 §1 follow-up — callers must branch on this
    field, not on the message string. *)
type transition_outcome =
  { message : string
  ; noop : bool
  }

val transition_task_outcome_r :
  config -> agent_name:string -> task_id:string -> action:Masc_domain.task_action ->
  ?prepare_verification_request:
    (task:Masc_domain.task ->
     assignee:string ->
     verification_id:string ->
     evidence_refs:string list ->
     (unit, string) result) ->
  ?compensate_verification_request:(verification_id:string -> unit) ->
  ?prepare_verification_verdict:
    (task:Masc_domain.task ->
     verifier:string ->
     verification_id:string ->
     decision:[ `Approve of string | `Reject of string ] ->
     (unit, string) result) ->
  ?expected_version:int -> ?notes:string -> ?reason:string ->
  ?handoff_context:Masc_domain.task_handoff_context ->
  ?authority:Masc_domain.completion_authority ->
  unit -> transition_outcome Masc_domain.masc_result

val transition_task_r :
  config -> agent_name:string -> task_id:string -> action:Masc_domain.task_action ->
  ?prepare_verification_request:
    (task:Masc_domain.task ->
     assignee:string ->
     verification_id:string ->
     evidence_refs:string list ->
     (unit, string) result) ->
  ?compensate_verification_request:(verification_id:string -> unit) ->
  ?prepare_verification_verdict:
    (task:Masc_domain.task ->
     verifier:string ->
     verification_id:string ->
     decision:[ `Approve of string | `Reject of string ] ->
     (unit, string) result) ->
  ?expected_version:int -> ?notes:string -> ?reason:string ->
  ?handoff_context:Masc_domain.task_handoff_context ->
  ?authority:Masc_domain.completion_authority ->
  unit -> string Masc_domain.masc_result

val release_task_r :
  config -> agent_name:string -> task_id:string ->
  ?expected_version:int ->
  ?handoff_context:Masc_domain.task_handoff_context -> unit -> string Masc_domain.masc_result

val force_release_task_r :
  config -> agent_name:string -> task_id:string ->
  ?handoff_context:Masc_domain.task_handoff_context -> unit -> string Masc_domain.masc_result

val force_done_task_r :
  config -> agent_name:string -> task_id:string ->
  notes:string -> unit -> string Masc_domain.masc_result

(** Typed failure surface of {!submit_and_approve_task_r}. Every branch is
    reported; none is swallowed. *)
type machine_verify_failure =
  | Machine_verify_invalid_verifier of string
      (** [verifier_name] failed [Validation.Agent_id] — rejected before any
          state mutation *)
  | Machine_verify_verifier_not_distinct of
      { agent_name : string
      ; verifier_name : string
      }
      (** verifier and submitter share one identity key — rejected before any
          state mutation (self-approval would be unrecoverable post-submit) *)
  | Machine_verify_submit_failed of Masc_domain.masc_error
      (** submit rejected by the FSM; task state unchanged *)
  | Machine_verify_approve_failed_compensated of Masc_domain.masc_error
      (** approve failed; the compensating reject succeeded — task is back to
          [InProgress { assignee }] *)
  | Machine_verify_approve_failed_stranded of
      { approve_error : Masc_domain.masc_error
      ; reject_error : Masc_domain.masc_error
      }
      (** approve and the compensating reject both failed — task remains
          [AwaitingVerification]; another identity can approve/reject it *)

(** RFC-0323 G-2: complete a task through the verification lane — submit as
    [agent_name] (the assignee), approve as the distinct machine identity
    [verifier_name]. Replaces direct [force_done_task_r] completion for
    deterministic harnesses (RFC-0199 probe). *)
val submit_and_approve_task_r :
  config -> agent_name:string -> verifier_name:string -> task_id:string ->
  notes:string -> approve_notes:string -> unit ->
  (string, machine_verify_failure) result

(** {1 Task cancellation} *)

val cancel_task_r :
  config -> agent_name:string -> task_id:string ->
  reason:string -> string Masc_domain.masc_result

(** Force-cancel a task regardless of assignee. System privilege.
    Used by {!Verification_protocol.check_timeouts} to expire
    [AwaitingVerification] tasks whose verifier deadline has passed. *)
val force_cancel_task_r :
  config -> agent_name:string -> task_id:string ->
  reason:string -> unit -> string Masc_domain.masc_result

val link_task_execution_artifacts_r :
  config -> task_id:string ->
  ?session_id:string -> ?operation_id:string ->
  unit -> string Masc_domain.masc_result

(** {1 Re-exported type (backward compatibility)} *)

type claim_next_result = Masc_domain.claim_next_result =
  | Claim_next_claimed of {
      task_id : string;
      title : string;
      priority : int;
      released_task_id : string option;
      message : string;
      scope_widened : bool;
    }
  | Claim_next_no_unclaimed
  | Claim_next_no_eligible of
      { excluded_count : int
      ; blocked_count : int
      ; verification_blocked_count : int
      ; scope_excluded_count : int
      ; explicit_excluded_count : int
      ; claim_pool_candidate_count : int
      }
  | Claim_next_error of string
