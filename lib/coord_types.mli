(** Coord_types — Shared types for coordination modules.

    Type-SSOT for the [tool_coord] / [coord_status_rendering] /
    [coord_assertions] / [coord_goals] cluster.  Consumers
    typically [open Coord_types] (4 sites: [tool_coord],
    [coord_goals], [coord_status_rendering], [coord_assertions])
    so every type below is part of the cross-module contract.

    All records are concrete because callers construct +
    destructure them field-by-field at the dispatch site. *)

(** [tool_result] is [(success, message)].  Used by tool dispatch
    return type before promotion to {!Tool_result.t}. *)
type tool_result = bool * string

(** Per-call coordination context.  Carries the resolved
    {!Coord.config} and the agent identifier. *)
type context = {
  config : Coord.config;
  agent_name : string;
}

(** Credential availability snapshot used by status rendering /
    cascade gating.  [credential_candidates] enumerates env-var
    names probed during resolution. *)
type credential_state = {
  credential_required : bool;
  credential_available : bool;
  credential_candidates : string list;
}

(** Resolved binding between [current_task] and the assignee /
    planning state.

    - [assigned_task_ids]: tasks where the calling agent is the
      active assignee (Claimed / InProgress / AwaitingVerification).
    - [primary_owned]: single canonical task id (when
      unambiguous).
    - [planning_current]: task id resolved from planning state
      (may differ from [primary_owned] during drift).
    - [current_is_assigned]: whether the [current_task] coord
      field is in [assigned_task_ids].
    - [effective_current]: post-reconciliation task id used by
      status rendering.
    - [drift_reason]: human-readable explanation when planning
      and ownership disagree.
    - [current_task_set]: whether the coord [current_task] field
      is non-empty.
    - [claim_first_suppressed]: whether the "claim_first"
      suggestion was suppressed (e.g. agent already owns a task). *)
type current_binding = {
  assigned_task_ids : string list;
  primary_owned : string option;
  planning_current : string option;
  current_is_assigned : bool;
  effective_current : string option;
  drift_reason : string option;
  current_task_set : bool;
  claim_first_suppressed : bool;
}

(** Planning-context anomaly snapshot.

    - [planning_missing_task]: task id referenced by the planning
      slot but not present in the backlog.
    - [deliverable_conflict_task]: task id whose deliverable
      claims completion in conflict with the recorded status. *)
type planning_context_state = {
  planning_missing_task : string option;
  deliverable_conflict_task : string option;
}
