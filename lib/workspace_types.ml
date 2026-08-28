(** Workspace_types - Shared types for workspace modules *)

type context =
  { config : Workspace.config
  ; agent_name : string
  }

type credential_state =
  { credential_required : bool
  ; credential_available : bool
  ; credential_candidates : string list
  }

type current_binding =
  { assigned_task_ids : string list
  ; primary_owned : string option
  ; planning_current : string option
  ; current_is_assigned : bool
  ; effective_current : string option
  ; drift_reason : string option
  ; current_task_set : bool
  ; claim_first_suppressed : bool
  }

