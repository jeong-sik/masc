(** Lane-lifetime access to the private publication recovery store.

    A lane opens one recovery store and keeps its capabilities pinned for the
    whole callback passed to [with_lane]. Individual publications borrow that
    store through [with_store]. Closing rejects new borrows and drains all
    borrows already in flight before the underlying capabilities are released. *)

type registry
type t

type access_error = Keeper_lane_not_available

type lane_open_error =
  | Invalid_owner of Capability_recovery_obligation.validation_error
  | Store_failed of Capability_recovery_obligation.transition_error

type invariant_violation =
  | Borrow_count_underflow
  | Borrow_count_overflow
  | Closing_without_active_borrows
  | Closed_with_active_borrows of int
  | Closed_without_drain_signal
  | Drain_signal_already_resolved

(** Raised when the private lifetime state becomes internally inconsistent.
    These states are programming errors and are never repaired silently. *)
exception Invariant_violation of invariant_violation

(** Open the process-lifetime registry below a caller-owned MASC root
    capability. The registry remains valid for exactly the lifetime of [sw]. *)
val open_registry
  :  sw:Eio.Switch.t
  -> registry_root:Eio.Fs.dir_ty Eio.Path.t
  -> (registry, Capability_recovery_obligation.transition_error) result

(** Validate [owner], pin its recovery store, and call [f]. The store remains
    pinned until [f] has returned or raised and every already-started
    [with_store] callback has completed. No timeout, retry budget, or polling
    policy is applied while draining. Callback exceptions and cancellation
    propagate; a simultaneous close failure is combined with the callback
    exception using [Eio.Exn.combine]. *)
val with_lane
  :  registry:registry
  -> owner:string
  -> (t -> 'a)
  -> ('a, lane_open_error) result

(** Borrow the lane store for one publication. The callback runs outside the
    lifetime mutex. Once lane closing begins, new borrows return
    [Keeper_lane_not_available]. Callback exceptions and cancellation
    propagate after cancellation-safe release of the borrow. *)
val with_store
  :  t
  -> (Capability_recovery_obligation.store -> 'a)
  -> ('a, access_error) result

val access_error_to_string : access_error -> string
val lane_open_error_to_string : lane_open_error -> string

(** Exact delegations to the recovery-obligation error SSOT. *)
val validation_error_to_string
  :  Capability_recovery_obligation.validation_error
  -> string

val transition_error_to_string
  :  Capability_recovery_obligation.transition_error
  -> string
