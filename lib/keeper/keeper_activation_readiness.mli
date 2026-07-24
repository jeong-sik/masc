(** Shared readiness predicates for autonomous keeper work.

    Used by both keeper preflight tools and dashboard fleet projections so
    operator-visible readiness does not drift from execution gates. *)

type autonomous_blocker =
  | Lifecycle_denied of Keeper_lifecycle_admission.autonomous_denial
  | Autoboot_disabled
  | Proactive_disabled

type owner_activation_blocker =
  | Autonomous_blocked of autonomous_blocker
  | Shutdown_fenced of Keeper_shutdown_types.Operation_id.t

type owner_activation =
  | Activation_allowed
  | Activation_blocked of owner_activation_blocker
  | Activation_unknown of string

(** Typed operator-facing projection of the persisted Keeper lifecycle and
    supervisor recovery policy. Server/dashboard code consumes this value; it
    must not reclassify pause/dead states independently. *)
type pause_kind =
  | Active
  | Operator_paused
  | Unclassified_paused
  | Dead_tombstone
  | Transcript_corruption_reset_required

val pause_kind : Keeper_meta_contract.keeper_meta -> pause_kind
val pause_kind_to_wire : pause_kind -> string

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

val owner_activation_blocker_to_wire : owner_activation_blocker -> string

val classify_owner_activation :
  shutdown_operation_id:Keeper_shutdown_types.Operation_id.t option ->
  (Keeper_meta_contract.keeper_meta, string) result ->
  owner_activation
(** Pure, closed owner activation verdict shared by supervisor and health.
    [Activation_allowed] means policy permits either signaling an existing
    lane or supervisor boot; it does not assert that a live lane exists.
    Missing/unreadable metadata fails closed as [Activation_unknown]. *)

val to_yojson : t -> Yojson.Safe.t
