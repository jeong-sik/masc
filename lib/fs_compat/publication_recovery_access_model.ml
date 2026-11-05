(** Vocabulary of publication recovery access: the rows and errors of owner
    discovery, inspection, reconciliation and lane opening, the registry with
    its readiness entries and health counters, the snapshots taken of it, the
    invariant and cleanup failures with their exceptions, and the types of the
    store-handle lease.

    This module is private to [fs_compat_internal] and has no interface file.
    [Publication_recovery_access] includes it. *)

module Core = Capability_recovery_obligation
module Reconciler = Capability_recovery_reconciler

type registry_error = Core.transition_error
type owner = Core.owner

type owner_discovery_row =
  | Discovered_owner of owner
  | Invalid_owner_name of string

type owner_inventory_row =
  | Valid_owner of owner
  | Unexpected_owner_kind of
      { owner : owner
      ; kind : Eio.File.Stat.kind
      }
  | Missing_owner_entry of owner
  | Owner_entry_unavailable of
      { owner : owner
      ; error : Core.transition_error
      }
  | Owner_inventory_cancelled of
      { owner : owner
      ; reason : exn
      ; backtrace : Printexc.raw_backtrace
      }
  | Owner_inventory_crashed of
      { owner : owner
      ; exception_ : exn
      ; backtrace : Printexc.raw_backtrace
      }

type discovery_failure =
  | Registry_discovery_failed of Core.transition_error
  | Registry_discovery_cancelled of
      { reason : exn
      ; backtrace : Printexc.raw_backtrace
      }
  | Registry_discovery_crashed of
      { exception_ : exn
      ; backtrace : Printexc.raw_backtrace
      }

type discovery_error =
  | Registry_discovery_in_progress
  | Registry_discovery_terminal of discovery_failure

type inspection_error =
  | Inspection_owner_in_progress of owner
  | Inspection_owner_already_terminal of owner_block

and owner_block =
  | Owner_inventory_block of owner_inventory_row
  | Owner_reconciliation_block of Reconciler.report
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

type reconciliation_error =
  | Owner_inventory_pending of owner
  | Owner_inventory_in_progress of owner
  | Owner_reconciliation_not_required of owner
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

type readiness =
  | Owner_inventory_pending_state
  | Owner_inventory_running_state
  | No_recovery_obligation of owner_inventory_row
  | Reconciliation_pending
  | Reconciliation_running
  | Reconciliation_ready of Reconciler.report
  | Reconciliation_blocked_state of owner_block

type readiness_entry =
  { owner : owner
  ; readiness : readiness
  ; settled : unit Eio.Promise.t
  ; resolve_settled : unit Eio.Promise.u
  }

module Owner_map = Map.Make (String)

type registry_phase =
  | Discovery_required_state
  | Discovery_running_state
  | Discovery_failed_state of discovery_failure
  | Discovery_complete_state of owner_discovery_row list

type discovery_health_phase =
  | Health_discovery_required
  | Health_discovery_running
  | Health_discovery_failed
  | Health_discovery_complete

type owner_health_counts =
  { inspection_pending : int
  ; inspection_running : int
  ; reconciliation_pending : int
  ; reconciliation_running : int
  ; ready_without_obligation : int
  ; ready : int
  ; blocked : int
  }

type health_snapshot =
  { discovery_phase : discovery_health_phase
  ; discovery_row_count : int
  ; discovered_owner_count : int
  ; invalid_owner_name_count : int
  ; retryable_lane_failure_count : int
  ; owners : owner_health_counts
  }

type lane_store_failure =
  | Lane_store_open_failed of Core.transition_error
  | Lane_store_release_failed of Core.resource_release_failure

type registry =
  { core : Core.registry
  ; fs : Eio.Fs.dir_ty Eio.Path.t
  ; readiness_mutex : Eio.Mutex.t
  ; discovery_settled : unit Eio.Promise.t
  ; resolve_discovery_settled : unit Eio.Promise.u
  ; mutable registry_phase : registry_phase
  ; mutable readiness : readiness_entry Owner_map.t
  ; mutable lane_store_failures : lane_store_failure Owner_map.t
  ; mutable health : health_snapshot
  }

type access_error = Keeper_lane_not_available

type lane_open_error =
  | Invalid_owner of Core.validation_error
  | Reconciliation_blocked of owner_block
  | Store_failed of Core.transition_error

type lane_release_failure = Core.resource_release_failure

type 'a lane_outcome =
  | Lane_released of 'a
  | Lane_release_failed of
      { value : 'a
      ; release_failure : lane_release_failure
      }

type discovery_snapshot =
  | Snapshot_discovery_required
  | Snapshot_discovery_running
  | Snapshot_discovery_failed of discovery_failure
  | Snapshot_discovery_complete of owner_discovery_row list

type owner_activation_snapshot =
  | Snapshot_owner_inventory_pending of owner
  | Snapshot_owner_inventory_running of owner
  | Snapshot_owner_reconciliation_pending of owner
  | Snapshot_owner_reconciliation_running of owner
  | Snapshot_owner_ready_without_obligation of owner
  | Snapshot_owner_ready of owner * Reconciler.report
  | Snapshot_owner_blocked of owner * owner_block

type registry_snapshot =
  { discovery : discovery_snapshot
  ; owners : owner_activation_snapshot list
  }

type health_counter =
  | Discovery_row_counter
  | Discovered_owner_counter
  | Invalid_owner_name_counter
  | Inspection_pending_counter
  | Inspection_running_counter
  | Reconciliation_pending_counter
  | Reconciliation_running_counter
  | Ready_without_obligation_counter
  | Ready_counter
  | Blocked_counter
  | Retryable_lane_failure_counter

type health_counter_change =
  | Increment_health_counter
  | Decrement_health_counter

type invariant_violation =
  | Borrow_count_underflow
  | Borrow_count_overflow
  | Closing_without_active_borrows
  | Closed_with_active_borrows of int
  | Closed_without_drain_signal
  | Drain_signal_already_resolved
  | Discovery_settled_twice
  | Discovery_finished_outside_running
  | Owner_inventory_owner_not_running of string
  | Reconciliation_owner_not_running of string
  | Owner_generation_settled_twice of string
  | Owner_generation_settled_before_terminal of string
  | Health_counter_underflow of health_counter
  | Health_counter_overflow of health_counter
  | Cleanup_body_outcome_lost

exception Invariant_violation of invariant_violation

type cleanup_failure =
  { body : Eio.Exn.with_bt option
  ; cancellation : Eio.Exn.with_bt option
  ; cleanup : Eio.Exn.with_bt
  }

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

exception Reconciliation_crash_terminalization_failed of
  reconciliation_crash_terminalization_failure

type reconciliation_cancellation_terminalization_failure =
  { cancellation : Eio.Exn.with_bt
  ; terminalization : Eio.Exn.with_bt
  }

exception Reconciliation_cancellation_terminalization_failed of
  reconciliation_cancellation_terminalization_failure

type phase =
  | Open
  | Closing
  | Closed

type t =
  { store : Core.store
  ; mutex : Eio.Mutex.t
  ; mutable phase : phase
  ; mutable in_flight : int
  ; drained : unit Eio.Promise.t
  ; resolve_drained : unit Eio.Promise.u
  }

type 'a outcome =
  | Returned of 'a
  | Raised of Eio.Exn.with_bt

type borrow_decision =
  | Borrowed of Core.store
  | Borrow_rejected
  | Borrow_invariant of invariant_violation

type release_decision =
  | Released
  | Release_and_signal
  | Release_invariant of invariant_violation

type close_decision =
  | Close_and_signal
  | Await_drain
  | Already_drained
  | Close_invariant of invariant_violation
