(** Coord_task -- Task lifecycle: add, claim, transition, complete, cancel.

    This module is [include]d by {!Coord}; all bindings are part of
    the public Coord interface.  Re-exports {!Coord_utils} and
    {!Coord_state}.

    The implementation is split across three sub-modules that are
    re-exported via [include]:
    - {!Coord_task_classify} — state classification, task actor kind,
      working agents, event helpers
    - {!Coord_task_create} — dedup logic, add_task, batch_add_tasks
    - {!Coord_task_claim} — claim_task, claim_task_r, release/reclaim
      helpers *)

include module type of Coord_utils
include module type of Coord_state

(** {1 Sub-module re-exports} *)

include module type of Coord_task_classify
include module type of Coord_task_create
include module type of Coord_task_claim

(** {1 Task transitions} *)

val transition_task_r :
  config -> agent_name:string -> task_id:string -> action:Types.task_action ->
  ?agent_tool_names:string list ->
  ?prepare_verification_request:
    (task:Types.task ->
     assignee:string ->
     verification_id:string ->
     evidence_refs:string list ->
     (unit, string) result) ->
  ?prepare_verification_verdict:
    (task:Types.task ->
     verifier:string ->
     verification_id:string ->
     decision:[ `Approve of string | `Reject of string ] ->
     (unit, string) result) ->
  ?expected_version:int -> ?notes:string -> ?reason:string ->
  ?handoff_context:Types.task_handoff_context ->
  ?force:bool -> unit -> string Types.masc_result

val release_task_r :
  config -> agent_name:string -> task_id:string ->
  ?expected_version:int ->
  ?handoff_context:Types.task_handoff_context -> unit -> string Types.masc_result

val force_release_task_r :
  config -> agent_name:string -> task_id:string ->
  ?handoff_context:Types.task_handoff_context -> unit -> string Types.masc_result

val force_done_task_r :
  config -> agent_name:string -> task_id:string ->
  notes:string -> unit -> string Types.masc_result

(** {1 Task cancellation} *)

val cancel_task_r :
  config -> agent_name:string -> task_id:string ->
  reason:string -> string Types.masc_result

val link_task_execution_artifacts_r :
  config -> task_id:string ->
  ?session_id:string -> ?operation_id:string -> ?autoresearch_loop_id:string ->
  unit -> string Types.masc_result

(** {1 Re-exported type (backward compatibility)} *)

type claim_next_result = Types.claim_next_result =
  | Claim_next_claimed of {
      task_id : string;
      title : string;
      priority : int;
      released_task_id : string option;
      message : string;
    }
  | Claim_next_no_unclaimed
  | Claim_next_no_eligible of { excluded_count : int }
  | Claim_next_error of string
