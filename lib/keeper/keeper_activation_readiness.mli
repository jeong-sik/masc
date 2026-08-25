(** Shared readiness predicates for autonomous keeper work.

    Used by both keeper preflight tools and dashboard fleet projections so
    operator-visible readiness does not drift from execution gates. *)

type autonomous_blocker =
  | Lifecycle_denied of Keeper_lifecycle_admission.autonomous_denial
  | Autoboot_disabled
  | Proactive_disabled

type owner_runtime =
  | Owner_unregistered
  | Owner_registered of
      { phase : Keeper_state_machine.phase
      ; live_fiber : bool
      ; lane_exited : bool
      }

type retained_disabled_reason =
  | Retained_autoboot_disabled
  | Retained_proactive_disabled

type paused_dead_reason =
  | Persisted_lifecycle_denied of Keeper_lifecycle_admission.autonomous_denial
  | Runtime_terminal of Keeper_state_machine.phase

type owner_execution_truth =
  | Executable
  | Recoverable
  | Retained_disabled of retained_disabled_reason
  | Paused_dead of paused_dead_reason
  | Shutdown_fenced of Keeper_shutdown_types.Operation_id.t
  | Unknown of string

(** Typed operator-facing projection of the persisted Keeper lifecycle and
    supervisor recovery policy. Server/dashboard code consumes this value; it
    must not reclassify pause/dead states independently. *)
type pause_kind =
  | Active
  | Operator_paused
  | Unclassified_paused

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

val owner_runtime_of_registry_entry :
  Keeper_registry.registry_entry option -> owner_runtime
(** Observe the live registry without deriving executability from phase or
    permission alone. A live fiber requires the registry condition, an open
    lane, and an unresolved lane completion promise. *)

val retained_disabled_reason_to_wire : retained_disabled_reason -> string
val paused_dead_reason_to_wire : paused_dead_reason -> string
val owner_execution_truth_to_wire : owner_execution_truth -> string

val classify_owner_execution :
  shutdown_operation_id:Keeper_shutdown_types.Operation_id.t option ->
  runtime:owner_runtime ->
  (Keeper_meta_contract.keeper_meta, string) result ->
  owner_execution_truth
(** Pure, closed execution verdict shared by supervisor, maintenance, schedule
    activation, and health. [Executable] requires a live registry fiber.
    Policy permission without one is [Recoverable], never runnable.
    Missing/unreadable metadata fails closed as [Unknown]. *)

val classify_durable_demand_execution :
  shutdown_operation_id:Keeper_shutdown_types.Operation_id.t option ->
  runtime:owner_runtime ->
  (Keeper_meta_contract.keeper_meta, string) result ->
  owner_execution_truth
(** Classify activation for an already-persisted explicit demand such as a due
    schedule or HITL continuation. Lifecycle and shutdown policy still apply.
    [autoboot_enabled] controls recovery of an absent owner, but does not block
    an owner that is already running. [proactive_enabled] does not apply: that
    flag controls unsolicited scheduled-autonomous turns, not reactive durable
    work. *)

val to_yojson : t -> Yojson.Safe.t
