(** Lane-lifetime access to the private publication recovery store.

    A lane opens one recovery store and keeps its capabilities pinned for the
    whole callback passed to [with_lane]. Individual publications borrow that
    store through [with_store]. Closing rejects new borrows and drains all
    borrows already in flight before the underlying capabilities are released. *)

type registry
type t
type owner

type owner_inventory_row =
  | Valid_owner of owner
  | Invalid_owner_name of string
  | Unexpected_owner_kind of
      { owner : owner
      ; kind : Eio.File.Stat.kind
      }
  | Missing_owner_entry of owner
  | Owner_entry_unavailable of
      { owner : owner
      ; error : Capability_recovery_obligation.transition_error
      }

type owner_inventory = owner_inventory_row list

type inventory_error =
  | Registry_inventory_in_progress
  | Registry_inventory_failed of Capability_recovery_obligation.transition_error

type owner_block =
  | Owner_inventory_block of owner_inventory_row
  | Owner_reconciliation_block of Capability_recovery_reconciler.report
  | Owner_reconciliation_crash of
      { owner : owner
      ; exception_ : exn
      ; backtrace : Printexc.raw_backtrace
      }
  | Owner_reconciliation_cancelled_block of
      { owner : owner
      ; reason : exn
      ; backtrace : Printexc.raw_backtrace
      }
  | Owner_activation_rejected_block of owner

type reconciliation_error =
  | Owner_inventory_required of owner
  | Owner_inventory_in_progress of owner
  | Owner_not_in_inventory of owner
  | Owner_reconciliation_in_progress of owner
  | Owner_inventory_prevents_reconciliation of owner_inventory_row
  | Owner_reconciliation_crashed of
      { owner : owner
      ; exception_ : exn
      ; backtrace : Printexc.raw_backtrace
      }
  | Owner_reconciliation_cancelled of
      { owner : owner
      ; reason : exn
      ; backtrace : Printexc.raw_backtrace
      }
  | Owner_activation_rejected of owner

type activation_rejection_error =
  | Activation_inventory_required of owner
  | Activation_inventory_in_progress of owner
  | Activation_owner_not_in_inventory of owner
  | Activation_owner_reconciliation_running of owner
  | Activation_owner_already_ready of owner
  | Activation_owner_already_blocked of owner_block

type access_error = Keeper_lane_not_available

type lane_open_error =
  | Invalid_owner of Capability_recovery_obligation.validation_error
  | Reconciliation_required of owner
  | Reconciliation_in_progress of owner
  | Reconciliation_blocked of owner_block
  | Store_failed of Capability_recovery_obligation.transition_error

type invariant_violation =
  | Borrow_count_underflow
  | Borrow_count_overflow
  | Closing_without_active_borrows
  | Closed_with_active_borrows of int
  | Closed_without_drain_signal
  | Drain_signal_already_resolved
  | Inventory_finished_outside_running
  | Reconciliation_finished_before_inventory
  | Reconciliation_owner_not_running of string
  | Reconciliation_settled_twice of string
  | Reconciliation_settled_before_terminal of string
  | Cleanup_body_outcome_lost

(** Raised when the private lifetime state becomes internally inconsistent.
    These states are programming errors and are never repaired silently. *)
exception Invariant_violation of invariant_violation

type cleanup_failure =
  { body : Eio.Exn.with_bt option
  ; cancellation : Eio.Exn.with_bt option
  ; cleanup : Eio.Exn.with_bt
  }

(** Raised directly for a non-cancelled body, or as the reason inside
    [Eio.Cancel.Cancelled] when cancellation remains primary. All body,
    cancellation, and cleanup backtraces are retained. *)
exception Cleanup_failed of cleanup_failure

type body_failed_during_cancellation =
  { body : Eio.Exn.with_bt
  ; cancellation : Eio.Exn.with_bt
  }

exception Body_failed_during_cancellation of
  body_failed_during_cancellation

type reconciliation_crash_terminalization_failure =
  { reconciliation : Eio.Exn.with_bt
  ; terminalization : Eio.Exn.with_bt
  }

(** Internal terminal publication failed while retaining a reconciliation
    crash. Both exception/backtrace pairs remain explicit. *)
exception Reconciliation_crash_terminalization_failed of
  reconciliation_crash_terminalization_failure

type reconciliation_cancellation_terminalization_failure =
  { cancellation : Eio.Exn.with_bt
  ; terminalization : Eio.Exn.with_bt
  }

(** Terminal publication failed after a live-context reconciliation callback
    raised [Cancelled]. Both exception/backtrace pairs remain explicit. *)
exception Reconciliation_cancellation_terminalization_failed of
  reconciliation_cancellation_terminalization_failure

(** Open the process-lifetime registry below a caller-owned MASC root
    capability. The registry remains valid for exactly the lifetime of [sw]. *)
val open_registry
  :  sw:Eio.Switch.t
  -> registry_root:Eio.Fs.dir_ty Eio.Path.t
  -> (registry, Capability_recovery_obligation.transition_error) result

(** Exact, non-recursive owner inventory. The registry enters a typed global
    inventory phase before filesystem observation, so concurrent lane opening
    fails without waiting. The first completed inventory becomes immutable for
    this process-lifetime registry; later callers receive those same rows.
    Every valid owner is atomically marked as requiring reconciliation.
    Invalid, missing, unexpected-kind, and unavailable rows remain explicit;
    rows that identify an exact valid owner block only that owner. *)
val inventory_owners
  :  registry
  -> (owner_inventory, inventory_error) result

val owner_to_string : owner -> string

(** Reconcile one owner previously accepted by the caller's stricter identity
    boundary. Concurrent lane opening observes [Reconciliation_in_progress]
    instead of waiting. A clean report marks this exact owner ready; every
    report with unresolved evidence blocks only this owner. *)
val reconcile_owner
  :  fs:Eio.Fs.dir_ty Eio.Path.t
  -> registry:registry
  -> owner:owner
  -> (Capability_recovery_reconciler.report, reconciliation_error) result

(** Atomically terminal-block one exact Pending owner after a caller's stricter
    activation identity boundary rejects it. The rejection reason remains at
    the caller boundary; this API records no MASC-specific value or string. *)
val reject_owner_activation
  :  registry:registry
  -> owner:owner
  -> (unit, activation_rejection_error) result

(** Internal fixture boundary. Production callers must use [with_lane]. *)
val with_core_store_for_testing
  :  registry:registry
  -> owner:string
  -> (Capability_recovery_obligation.store -> 'a)
  -> ('a, lane_open_error) result

(** Validate [owner], pin its recovery store, and call [f]. The store remains
    pinned until [f] has returned or raised and every already-started
    [with_store] callback has completed. No timeout, retry budget, or polling
    policy is applied while draining. Callback exceptions and cancellation
    remain primary. A simultaneous close failure is retained as typed
    {!Cleanup_failed} evidence with every available backtrace. *)
val with_lane
  :  registry:registry
  -> owner:string
  -> (t -> 'a)
  -> ('a, lane_open_error) result

(** Await the exact owner's one-shot reconciliation settlement, then evaluate
    the typed gate again. Pending/running owners wait without timeout, polling,
    retry, or a shared-server barrier. Invalid and terminal-blocked owners
    return immediately. *)
val await_lane_reconciliation
  :  registry:registry
  -> owner:string
  -> (unit, lane_open_error) result

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

val owner_inventory_row_to_string : owner_inventory_row -> string
val inventory_error_to_string : inventory_error -> string
val owner_block_to_string : owner_block -> string
val reconciliation_error_to_string : reconciliation_error -> string
val activation_rejection_error_to_string : activation_rejection_error -> string

(** Exact delegations to the recovery-obligation error SSOT. *)
val validation_error_to_string
  :  Capability_recovery_obligation.validation_error
  -> string

val transition_error_to_string
  :  Capability_recovery_obligation.transition_error
  -> string

module For_testing : sig
  type reconciliation_interruption =
    | Cancel_reconciliation of exn
    | Crash_reconciliation of exn

  type cleanup_body =
    | Return_cleanup_value of string
    | Raise_cleanup_body of exn
    | Cancel_cleanup_body of exn

  type observed_failure =
    { exception_ : exn
    ; backtrace : Printexc.raw_backtrace
    }

  type cleanup_evidence =
    | Cleanup_returned of string
    | Cleanup_failed_without_cancellation of
        { body : observed_failure option
        ; cleanup : observed_failure
        }
    | Cancellation_primary_with_cleanup_failure of
        { body : observed_failure option
        ; cancellation : observed_failure
        ; cleanup : observed_failure
        }
    | Body_failure_during_cancellation of
        { body : observed_failure
        ; cancellation : observed_failure
        }
    | Cancellation_primary of observed_failure
    | Cleanup_boundary_raised of observed_failure

  type single_borrow_evidence =
    | Single_borrow_balance of
        { during_borrow : int
        ; after_release : int
        ; close_completed : bool
        }
    | Single_borrow_rejected
    | Single_borrow_invariant of invariant_violation
    | Single_borrow_raised of observed_failure

  type owner_settlement =
    | Owner_untracked
    | Owner_unsettled
    | Owner_settled

  (** Deterministic fault injection around the production owner state machine.
      The injected callback runs only after the exact owner moves to Running;
      cancellation and crash handling are the same paths used by
      {!reconcile_owner}. *)
  val interrupt_reconciliation
    :  fs:Eio.Fs.dir_ty Eio.Path.t
    -> registry:registry
    -> owner:owner
    -> reconciliation_interruption
    -> (Capability_recovery_reconciler.report, reconciliation_error) result

  (** Executes the real lane cleanup combinator and projects its typed result
      without relying on exception messages. *)
  val run_cleanup_boundary
    :  body:cleanup_body
    -> cleanup_failure:exn option
    -> cleanup_evidence

  (** Exercises the production create/borrow/release/close path. When a release
      leaves a non-zero count it records the imbalance and deliberately avoids
      awaiting the impossible drain, making count leaks deterministic. *)
  val single_borrow_balance
    :  registry:registry
    -> owner:string
    -> (single_borrow_evidence, lane_open_error) result

  val owner_settlement : registry -> owner -> owner_settlement
end
