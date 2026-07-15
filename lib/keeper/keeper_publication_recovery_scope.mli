(** Binds one durable publication-recovery store to one Keeper lane lifetime. *)

type failure =
  | Registry_not_provided
  | Registry_entry_not_found of
      { base_path : string
      ; keeper_name : string
      }
  | Registry_entry_unhealthy of Keeper_registry.registry_entry_health
  | Lane_open_failed of Fs_compat.publication_recovery_lane_open_error
  | Access_already_attached
  | Access_not_attached
  | Body_and_detach_failed of
      { body : exn
      ; body_backtrace : Printexc.raw_backtrace
      ; detach : failure
      }

exception Scope_failed of failure
exception Scope_detach_failed_on_cancellation of exn * failure

val failure_to_string : failure -> string

type turn_resources =
  { entry : Keeper_registry.registry_entry
  ; registry : Fs_compat.publication_recovery_registry
  ; access : Fs_compat.publication_recovery_access
  }

val resolve_turn_resources
  :  registry:Fs_compat.publication_recovery_registry option
  -> base_path:string
  -> keeper_name:string
  -> (turn_resources, failure) result
(** Performs one exact registry-entry lookup at the admitted turn boundary.
    The returned immutable capabilities are then threaded through the turn;
    individual tools neither repeat the lookup nor reopen the lane store. *)

val with_lane_scope :
  registry:Fs_compat.publication_recovery_registry option ->
  entry:Keeper_registry.registry_entry ->
  (unit -> 'a) ->
  'a
(** [with_lane_scope] first awaits exactly [entry.name]'s one-shot
    reconciliation settlement, then opens that lane store, publishes its opaque
    access on the exact registry entry, runs [body], detaches the access, and
    only then allows the store to close. It never waits on another owner, a
    timeout, or a global activation barrier. Cancellation and a simultaneous
    detach invariant failure retain both causes. *)
