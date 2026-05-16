(** Shared readiness predicates for autonomous keeper work.

    Used by both keeper preflight tools and dashboard fleet projections so
    operator-visible readiness does not drift from execution gates. *)

type autonomous_activation =
  { ok : bool
  ; autoboot_enabled : bool
  ; proactive_enabled : bool
  ; paused : bool
  ; blocker : string option
  ; hint : string option
  }

type work_discovery_activation =
  { ok : bool
  ; work_discovery_enabled : bool option
  ; current_task_id : string option
  ; blocker : string option
  ; hint : string option
  }

type t =
  { ok : bool
  ; ready_for_unclaimed_backlog : bool
  ; autonomous_activation : autonomous_activation
  ; work_discovery_activation : work_discovery_activation
  }

val of_meta : Keeper_types.keeper_meta -> t

val ready_for_unclaimed_backlog : Keeper_types.keeper_meta -> bool

val autonomous_check_value : autonomous_activation -> string

val work_discovery_check_value : work_discovery_activation -> string

val to_yojson : t -> Yojson.Safe.t
