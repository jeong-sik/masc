(** Workspace_task_claim — claim_task, claim_task_r, release/reclaim helpers.

    This module is [include]d by {!Workspace_task}; all bindings are part of
    the public Workspace interface.  Re-exports {!Workspace_utils} and
    {!Workspace_state}. *)

include module type of Workspace_utils
include module type of Workspace_state

(** {1 Reclaim helpers} *)

val clear_reclaim_decision : Masc_domain.task -> Masc_domain.task
(** Clears non-blocking reclaim policy metadata before a task is claimed. *)

val active_owned_task_ids_for_agent :
  config -> agent_name:string -> Masc_domain.backlog -> string list
(** Active [Claimed] or [InProgress] tasks owned by [agent_name], using the
    same canonical keeper/agent identity comparison as task transitions. *)

val active_ownership_conflict_for_claim :
  config ->
  agent_name:string ->
  requested_task_id:string ->
  Masc_domain.backlog ->
  string option
(** Returns an operator-facing error when [agent_name] already owns a
    different active task and tries to claim [requested_task_id]. *)

(** {1 Task claiming} *)

(** Typed outcome of a successful claim.

    [auto_released_task_ids] is legacy and always empty.
    Auto-release of previously Claimed tasks was removed in #18839
    to stop the hot-potato pattern where a keeper churned through
    [task_claim_next] without finishing. Keepers must now explicitly
    release tasks via [keeper_task_release] before claiming another.
    The field is retained for backward compatibility with existing
    MCP consumers that pattern-match on the record shape. *)
type claim_outcome = {
  message : string;
  auto_released_task_ids : string list;
}

val claim_task :
  config -> agent_name:string -> task_id:string -> string

val claim_task_r :
  config -> agent_name:string -> task_id:string ->
  unit -> claim_outcome Masc_domain.masc_result

(** {1 Release/reclaim helpers} *)

val release_handoff_texts : Masc_domain.task_handoff_context option -> string list

val release_reclaim_policy :
  Masc_domain.task_handoff_context option -> Masc_domain.task_reclaim_policy option

val derive_release_do_not_reclaim_reason :
  Masc_domain.task -> Masc_domain.task_handoff_context option -> string option

val derive_release_reclaim_policy :
  Masc_domain.task ->
  Masc_domain.task_handoff_context option ->
  Masc_domain.task_reclaim_policy option
