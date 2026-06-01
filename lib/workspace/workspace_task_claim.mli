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

    [auto_released_task_ids] is the list of *other* tasks previously
    held by the same agent that the claim implicitly auto-released
    (see #10421 / #18839: hot-potato pattern where a keeper churns
    through [task_claim_next] without finishing). Empty when the agent
    held no prior claims; non-empty when [task_claim_next] preempted
    them. Previously this list was only visible as a substring of the
    [message] field (["… (auto-released X, Y)"]); MCP handlers had to
    re-parse it. Surfaced as a typed field so callers — including the
    MCP envelope that feeds the LLM keeper response — can react
    without string parsing.

    RFC-0088 §1 (counter-as-fix) note: this PR only widens the typed
    surface so a caller *can* observe the auto-release. Behaviour is
    unchanged. The follow-up RFC step (reject + explicit release) is
    out of scope for this PR. *)
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
