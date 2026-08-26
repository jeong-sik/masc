type durability =
  | Durable
  | Durability_unconfirmed

type config_state =
  | Configured
  | Rejected
  | Unreadable

type skill_application =
  | Skill_published of
      { input_source_revision : string
      ; snapshot_revision : string
      ; catalog_revision : string
      ; config_state : config_state
      }
  | Skill_unchanged of
      { input_source_revision : string
      ; snapshot_revision : string
      ; catalog_revision : string
      ; config_state : config_state
      }
  | Skill_superseded of
      { commit_order : string
      ; applied_order : string
      }
  | Skill_workspace_retired of { input_source_revision : string }
  | Skill_invalid_workspace

type routing_status =
  | Routing_active
  | Routing_applied

type keeper_overlay_status =
  | Keeper_not_configured
  | Keeper_pending_restart
  | Keeper_applied
  | Keeper_preempted_by_env
  | Keeper_mixed

type applied_at =
  | Not_applied
  | Applied_at_string of string
  | Applied_at_int of int
  | Applied_at_float of float

type application =
  { operation : string
  ; routing_status : routing_status
  ; routing_requires_restart : bool
  ; routing_applied_at : applied_at
  ; keeper_status : keeper_overlay_status
  ; keeper_requires_restart : bool
  ; keeper_applied_at : applied_at
  ; keeper_configured_count : int
  ; keeper_pending_keys : string list
  ; keeper_applied_keys : string list
  ; keeper_preempted_keys : string list
  ; skills : skill_application
  }

type t =
  { source_revision : string
  ; order : string
  ; durability : durability
  ; application : application
  }

val decode : Yojson.Safe.t -> (t, string) result
val summary : t -> string
