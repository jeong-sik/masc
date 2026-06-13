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
  ?force:bool -> unit -> string Masc_domain.masc_result

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
