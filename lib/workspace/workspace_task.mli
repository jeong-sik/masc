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

val delete_task_r : config -> task_id:string -> unit Masc_domain.masc_result
(** Delete one Task under the canonical backlog lock and clear any agent
    [current_task] cache that still points at it after the backlog commit.
    Missing Task ids are idempotent; read/write failures remain typed. *)

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
     claim:Masc_domain.verification_claim ->
     (unit, string) result) ->
  ?expected_version:int -> ?notes:string -> ?reason:string ->
  ?handoff_context:Masc_domain.task_handoff_context ->
  unit -> transition_outcome Masc_domain.masc_result

(** Commit a completion verdict issued by a [Masc_domain.completion_authority].

    Separate from {!transition_task_outcome_r} because a verdict is not an agent
    action. The caller must authenticate or otherwise validate the authority
    before constructing its provenance value. This is the only path that
    resolves an [AwaitingVerification] obligation.

    [evaluator_runtime] names the configured runtime that produced the verdict,
    and lands in every structured projection alongside the authority identity.
    The authority actor is a fresh id per review and so groups nothing; the
    runtime key is what a verdict history can be aggregated on. Omit it for a
    human operator verdict, where no evaluator ran. *)
val commit_verdict_r :
  config ->
  authority:Masc_domain.completion_authority ->
  verdict:Masc_domain.completion_verdict ->
  task_id:string ->
  verification_id:string ->
  ?notes:string ->
  ?evaluator_runtime:string ->
  unit ->
  transition_outcome Masc_domain.masc_result

val transition_task_r :
  config -> agent_name:string -> task_id:string -> action:Masc_domain.task_action ->
  ?prepare_verification_request:
    (task:Masc_domain.task ->
     assignee:string ->
     verification_id:string ->
     claim:Masc_domain.verification_claim ->
     (unit, string) result) ->
  ?expected_version:int -> ?notes:string -> ?reason:string ->
  ?handoff_context:Masc_domain.task_handoff_context ->
  unit -> string Masc_domain.masc_result

val release_task_r :
  config -> agent_name:string -> task_id:string ->
  ?expected_version:int ->
  ?handoff_context:Masc_domain.task_handoff_context -> unit -> string Masc_domain.masc_result

(** {1 Explicit operator recovery} *)

type operator_task_recovery_result =
  { task_id : string
  ; previous_status : Masc_domain.task_status
  ; previous_assignee : string
  ; backlog_version : int
  ; post_commit_errors : string list
  }

val recover_owned_task_to_todo_r :
  config ->
  operator_actor:string ->
  task_id:string ->
  expected_assignee:string ->
  expected_version:int ->
  reason:string ->
  unit ->
  operator_task_recovery_result Masc_domain.masc_result
(** Explicit compare-and-set recovery for a task whose owner cannot continue.
    Only [Claimed] and [InProgress] tasks are eligible. The persisted assignee
    and backlog version must exactly match the operator's observation.

    This function performs no liveness, elapsed-time, name-shape, or status-file
    inference. Authorization belongs to the operator tool boundary. *)

(** {1 Task cancellation} *)


val link_task_execution_artifacts_r :
  config -> task_id:string ->
  ?session_id:string -> ?operation_id:string ->
  unit -> string Masc_domain.masc_result

(** {1 Re-exported scheduling result} *)

type claim_next_result = Masc_domain.claim_next_result =
  | Claim_next_claimed of {
      task_id : string;
      title : string;
      priority : int;
      message : string;
      scope_widened : bool;
    }
  | Claim_next_no_unclaimed
  | Claim_next_no_eligible of
      { excluded_count : int
      ; scope_excluded_count : int
      ; explicit_excluded_count : int
      ; claim_pool_candidate_count : int
      }
  | Claim_next_error of string
