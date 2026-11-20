(** Workspace_task_claim — claim_task_r and claim helpers.

    This module is [include]d by {!Workspace_task}; all bindings are part of
    the public Workspace interface.  Re-exports {!Workspace_utils} and
    {!Workspace_state}. *)

open! Workspace_utils

val active_owned_task_ids_for_agent :
  config -> agent_name:string -> Masc_domain.backlog -> string list
(** Active [Claimed] or [InProgress] tasks owned by [agent_name], using the
    same canonical keeper/agent identity comparison as task transitions. *)

(** {1 Task claiming} *)

val claim_task_with_details_r :
  config ->
  agent_name:string ->
  task_id:string ->
  ?auto_start:bool ->
  unit ->
  (Masc_domain.task * string) Masc_domain.masc_result
(** Claim [task_id] for [agent_name] and return both the resulting task record
    and the human-readable outcome message. When [auto_start = true], a newly
    claimed [Todo] task or an already-held [Claimed] task is atomically
    transitioned to [InProgress] inside the same [.backlog] lock and commit. *)

val claim_task_r :
  config ->
  agent_name:string ->
  task_id:string ->
  ?auto_start:bool ->
  unit ->
  string Masc_domain.masc_result

val run_post_commit :
  task_id:string ->
  agent_name:string ->
  action:string ->
  string ->
  (unit -> unit) ->
  unit
(** Run a best-effort post-commit projection step after the authoritative
    backlog write has committed: re-raises [Eio.Cancel.Cancelled] and logs any
    other exception without aborting the committed outcome or skipping
    subsequent post-commit steps. *)

val emit_auto_start_side_effects :
  config ->
  agent_name:string ->
  task_id:string ->
  from_status:Masc_domain.task_status ->
  to_status:Masc_domain.task_status ->
  unit
(** Emit post-commit side effects (broadcast, activity, transition observer,
    hook push, and transition log event) for an atomic [Claimed -> InProgress]
    auto-start transition. *)

val claim_broadcast_content : task_id:string -> string
(** Canonical [System_record] broadcast message emitted when a task is claimed. *)

val emit_claim_side_effects :
  config ->
  action:string ->
  agent_name:string ->
  task_id:string ->
  from_status:Masc_domain.task_status ->
  claimed_status:Masc_domain.task_status ->
  final_status:Masc_domain.task_status ->
  auto_start:bool ->
  activity_payload:Yojson.Safe.t ->
  log_label:string ->
  log_payload:Yojson.Safe.t ->
  unit
(** Emit the full post-commit side-effect sequence for a newly claimed task:
    local agent state update, [System_record] claim broadcast, activity event,
    audit log event, transition observer, and optional [auto_start] side effects. *)
