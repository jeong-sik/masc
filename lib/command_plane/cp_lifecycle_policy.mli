(** Cp_lifecycle_policy -- dispatch, rebalance, escalate, recall,
    unit management, policy decisions, and tick-based automation.

    This module is [include]d by {!Command_plane_v2}; all bindings
    are therefore part of the public Command_plane_v2 interface. *)

include module type of Cp_lifecycle

(** {1 Dispatch operations} *)

val dispatch_assign_json :
  Room.config -> actor:string -> Yojson.Safe.t -> (Yojson.Safe.t, string) result

val dispatch_rebalance_json :
  Room.config -> actor:string -> Yojson.Safe.t -> (Yojson.Safe.t, string) result

val dispatch_escalate_json :
  Room.config -> actor:string -> Yojson.Safe.t -> (Yojson.Safe.t, string) result

val dispatch_recall_json :
  Room.config -> actor:string -> Yojson.Safe.t -> (Yojson.Safe.t, string) result

(** {1 Unit management} *)

val unit_update_json :
  Room.config -> actor:string -> Yojson.Safe.t -> (Yojson.Safe.t, string) result

val unit_reparent_json :
  Room.config -> actor:string -> Yojson.Safe.t -> (Yojson.Safe.t, string) result

val unit_reassign_json :
  Room.config -> actor:string -> Yojson.Safe.t -> (Yojson.Safe.t, string) result

(** {1 Policy decisions} *)

val policy_status_json : Room.config -> Yojson.Safe.t

val policy_freeze_unit_json :
  Room.config -> actor:string -> Yojson.Safe.t -> (Yojson.Safe.t, string) result

val policy_kill_switch_json :
  Room.config -> actor:string -> Yojson.Safe.t -> (Yojson.Safe.t, string) result

val policy_update_json :
  Room.config -> actor:string -> Yojson.Safe.t -> (Yojson.Safe.t, string) result

val policy_approve_json :
  Room.config -> actor:string -> Yojson.Safe.t -> (Yojson.Safe.t, string) result

val policy_deny_json :
  Room.config -> actor:string -> Yojson.Safe.t -> (Yojson.Safe.t, string) result

(** {1 Detachment status} *)

val detachment_status_json :
  Room.config -> Yojson.Safe.t -> (Yojson.Safe.t, string) result

(** {1 Tick automation} *)

val dispatch_tick_json :
  Room.config -> actor:string -> Yojson.Safe.t -> (Yojson.Safe.t, string) result

(** {1 Observation} *)

val observe_operations_json : Room.config -> Yojson.Safe.t

val observe_capacity_json : Room.config -> Yojson.Safe.t

(** {1 Failover} *)

val pick_failover_leader : string list -> Cp_types.detachment_record -> string option
