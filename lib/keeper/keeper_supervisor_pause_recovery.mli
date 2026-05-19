(** Supervisor recovery policy for auto-recoverable durable keeper pauses.

    When a keeper enters a paused state (operator pause, supervisor pause,
    or auto-recover pause), the supervisor scans for keepers whose pause
    reason has been resolved and can be safely resumed. This module
    implements that recovery policy.

    A "durable pause" is a persisted pause state that survives supervisor
    restarts. An "auto-recoverable" pause is one where:
      - The pause was caused by a transient condition (not operator action)
      - The triggering condition has resolved
      - Sufficient cooldown time has elapsed
      - The keeper's health indicators allow resumption

    This module is the backend complement to the dashboard's
    keeper-operational-state.ts PausedCause = 'auto_recover'. *)

(** Pause reason categories, paralleling the dashboard's PausedCause. *)
type pause_reason =
  | Operator_pause          (** Explicit operator action *)
  | Supervisor_pause        (** Supervisor-initiated for safety *)
  | Auto_recover_pause      (** Automatic, recoverable pause *)

(** Outcome of evaluating a single paused keeper. *)
type recovery_evaluation =
  | Not_paused
  | Paused_not_recoverable of pause_reason
  | Paused_recoverable of
      { reason : pause_reason
      ; cooldown_elapsed : bool
      ; health_ok : bool
      }

(** Result of a recovery attempt for one keeper. *)
type recovery_outcome =
  | Recovery_not_needed
  | Recovery_skipped of string  (** reason string *)
  | Recovery_resumed of string  (** keeper name *)
  | Recovery_failed of string   (** keeper name + error detail *)

val pause_reason_to_label : pause_reason -> string

val evaluate_pause
  :  paused_at:float option
  -> pause_state:string option
  -> auto_recoverable:bool
  -> now:float
  -> recovery_evaluation

(** Minimum cooldown in seconds before auto-recovery is attempted.
    Default: 300 seconds (5 minutes). *)
val default_cooldown_sec : float

(** Scan all registered keepers and attempt auto-recovery for those
    in an auto-recoverable paused state.

    This should be called on each supervisor tick, after the liveness
    recovery scan. *)
val scan
  :  resume_keeper:(string -> unit)
  -> publish_lifecycle:
       (event:Keeper_lifecycle_events.lifecycle_event -> string -> string -> unit -> unit)
  -> (Keeper_registry.registry_entry * string) list
  -> recovery_outcome list