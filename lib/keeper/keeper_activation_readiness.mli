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

type t =
  { ok : bool
  ; ready_for_unclaimed_backlog : bool
  ; autonomous_activation : autonomous_activation
  }

val of_meta : Keeper_meta_contract.keeper_meta -> t

val ready_for_unclaimed_backlog : Keeper_meta_contract.keeper_meta -> bool

val autonomous_check_value : autonomous_activation -> string

val to_yojson : t -> Yojson.Safe.t
