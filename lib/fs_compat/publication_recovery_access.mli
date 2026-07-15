(** Lane-lifetime access to the private publication recovery store.

    A lane opens one recovery store and keeps its capabilities pinned for the
    whole callback passed to [with_lane]. Individual publications borrow that
    store through [with_store]. Closing rejects new borrows and drains all
    borrows already in flight before the underlying capabilities are released. *)

type registry
type t
type owner

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
      ; error : Capability_recovery_obligation.transition_error
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
  | Registry_discovery_failed of
      Capability_recovery_obligation.transition_error
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

type access_error = Keeper_lane_not_available

type lane_open_error =
  | Invalid_owner of Capability_recovery_obligation.validation_error
  | Reconciliation_blocked of owner_block
  | Store_failed of Capability_recovery_obligation.transition_error

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
  | Snapshot_owner_ready of
      owner * Capability_recovery_reconciler.report
  | Snapshot_owner_blocked of owner * owner_block

type registry_snapshot =
  { discovery : discovery_snapshot
  ; owners : owner_activation_snapshot list
  }

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
  ; owners : owner_health_counts
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
  -> fs:Eio.Fs.dir_ty Eio.Path.t
  -> registry_root:Eio.Fs.dir_ty Eio.Path.t
  -> (registry, Capability_recovery_obligation.transition_error) result

(** Discover exact child names without inspecting any child. Discovery rows
    remain observational and never populate the exact-demand registry. Root
    discovery failure is retained as a typed degraded observation; it never
    authorizes or blocks an exact owner demand. *)
val discover_owners
  :  registry
  -> (owner_discovery_row list, discovery_error) result

(** Inspect exactly one demanded owner. A valid directory installs a fresh
    reconciliation-pending generation and settles the retired inspection
    promise, so every concurrent demander can continue even if the inspection
    winner is cancelled before it claims reconciliation.
    Missing means that this exact owner has no recovery obligation. Wrong-kind,
    I/O, non-current cancellation, and crash evidence terminalize and resolve
    this owner only. Current-context cancellation retires the running promise,
    installs a fresh pending generation, and then propagates cancellation. *)
val inspect_owner
  :  registry:registry
  -> owner:owner
  -> (owner_inventory_row, inspection_error) result

(** Constant-time immutable aggregate captured under the transition mutex.
    Counts are maintained by the same closed transition functions that mutate
    exact owner readiness; health polling performs no owner/discovery traversal
    or filesystem I/O. *)
val health_snapshot : registry -> health_snapshot

(** Demand-driven activation for one exact lane. Discovery is observational:
    demand performs exact owner inspection even while discovery is running or
    after it failed. At most one caller wins each
    inventory/reconciliation transition; concurrent callers await the same
    owner-generation settlement promise. No timeout, polling, retry budget,
    eager owner fan-out, or numeric concurrency cap is applied. *)
val ensure_owner_ready
  :  registry:registry
  -> owner:string
  -> (unit, lane_open_error) result

val owner_to_string : owner -> string

(** Reconcile one owner previously accepted by the caller's stricter identity
    boundary. Direct concurrent reconciliation observes
    [Owner_reconciliation_in_progress]; demand-driven lane opening waits on the
    exact owner generation. A clean report marks this exact owner ready; every
    report with unresolved evidence blocks only this owner. *)
val reconcile_owner
  :  registry:registry
  -> owner:owner
  -> (Capability_recovery_reconciler.report, reconciliation_error) result

val report_owner : Capability_recovery_reconciler.report -> string
val report_is_ready : Capability_recovery_reconciler.report -> bool
val report_to_yojson : Capability_recovery_reconciler.report -> Yojson.Safe.t

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
val owner_discovery_row_to_string : owner_discovery_row -> string
val discovery_failure_to_string : discovery_failure -> string
val discovery_error_to_string : discovery_error -> string
val inspection_error_to_string : inspection_error -> string
val owner_block_to_string : owner_block -> string
val reconciliation_error_to_string : reconciliation_error -> string

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

  type discovery_phase =
    | Discovery_required
    | Discovery_running
    | Discovery_failed
    | Discovery_complete

  type discovery_settlement =
    | Discovery_unsettled
    | Discovery_settled

  (** Deterministic suspension/fault injection immediately after discovery
      enters Running and immediately after one owner enters inventory Running.
      The production state-transition and terminalization paths are unchanged. *)
  val discover_owners
    :  before_discovery:(unit -> unit)
    -> registry
    -> (owner_discovery_row list, discovery_error) result

  val discover_owners_terminalization
    :  before_terminalization:(unit -> unit)
    -> registry
    -> (owner_discovery_row list, discovery_error) result

  val inspect_owner
    :  before_inspection:(unit -> unit)
    -> registry:registry
    -> owner:owner
    -> (owner_inventory_row, inspection_error) result

  val inspect_owner_terminalization
    :  before_terminalization:(unit -> unit)
    -> registry:registry
    -> owner:owner
    -> (owner_inventory_row, inspection_error) result

  (** Deterministic fault injection around the production owner state machine.
      The injected callback runs only after the exact owner moves to Running;
      cancellation and crash handling are the same paths used by
      {!reconcile_owner}. *)
  val interrupt_reconciliation
    :  registry:registry
    -> owner:owner
    -> reconciliation_interruption
    -> (Capability_recovery_reconciler.report, reconciliation_error) result

  val reconcile_owner
    :  before_reconciliation:(unit -> unit)
    -> registry:registry
    -> owner:owner
    -> (Capability_recovery_reconciler.report, reconciliation_error) result

  val reconcile_owner_terminalization
    :  before_terminalization:(unit -> unit)
    -> registry:registry
    -> owner:owner
    -> (Capability_recovery_reconciler.report, reconciliation_error) result

  val with_readiness_lock : registry -> (unit -> 'a) -> 'a
  (** Hold the exact state-transition mutex for deterministic cancellation
      choreography. No production lock or mutex value is exposed. *)

  val ensure_owner_ready
    :  before_owner_settlement_wait:(unit Eio.Promise.t -> unit)
    -> after_owner_settlement:(unit Eio.Promise.t -> unit)
    -> registry:registry
    -> owner:string
    -> (unit, lane_open_error) result

  val snapshot : registry -> registry_snapshot
  (** Exact evidence projection for deterministic tests only. *)

  val health_counter_transition
    :  counter:health_counter
    -> change:health_counter_change
    -> value:int
    -> (int, invariant_violation) result
  (** Exercise one checked aggregate-counter transition without mutating a
      registry. This boundary verifies invariant classification; it never
      repairs an invalid count. *)

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
  val discovery_phase : registry -> discovery_phase
  val discovery_settlement : registry -> discovery_settlement
  val await_discovery_settlement : registry -> unit
end
