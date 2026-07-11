(** Shared readiness predicates for autonomous keeper work.

    Used by both keeper preflight tools and dashboard fleet projections so
    operator-visible readiness does not drift from execution gates. *)

type autonomous_blocker =
  | Lifecycle_denied of Keeper_lifecycle_admission.autonomous_denial
  | Autoboot_disabled
  | Proactive_disabled

type autonomous_activation =
  { ok : bool
  ; autoboot_enabled : bool
  ; proactive_enabled : bool
  ; paused : bool
  ; lifecycle_state : Keeper_lifecycle_admission.state
  ; blocker : autonomous_blocker option
  ; hint : string option
  }

type t =
  { ok : bool
  ; ready_for_unclaimed_backlog : bool
  ; autonomous_activation : autonomous_activation
  }

val of_meta : Keeper_meta_contract.keeper_meta -> t

val ready_for_unclaimed_backlog : Keeper_meta_contract.keeper_meta -> bool

val autonomous_check_value : autonomous_activation -> string

val autonomous_blocker_to_wire : autonomous_blocker -> string

val to_yojson : t -> Yojson.Safe.t
