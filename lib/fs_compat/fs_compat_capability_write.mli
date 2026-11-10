(** Capability writes of [Fs_compat]: the publication target and directory
    payload types, [Publication_recovery], the write, cleanup and recovery
    failure types, the exclusive create and replace entry points, and the
    cleanup of orphaned atomic temp files. [Fs_compat] includes this module. *)
open Fs_compat_internal

val open_atomic_temp_file : temp_dir:string -> unit -> string * out_channel

val is_capability_leaf : string -> bool

type capability_publication_target = Atomic_write.capability_publication_target

type capability_publication_target_error =
  Atomic_write.capability_publication_target_error

type directory_file = Atomic_write.directory_file =
  { leaf : string
  ; content : string
  ; permissions : int
  }

type directory_payload = Atomic_write.directory_payload

type directory_payload_error = Atomic_write.directory_payload_error =
  | Invalid_directory_leaf of string
  | Duplicate_directory_leaf of string
  | Invalid_directory_file_permissions of { leaf : string; permissions : int }

val directory_payload :
  directory_file list -> (directory_payload, directory_payload_error) result

val directory_payload_error_to_string : directory_payload_error -> string

module Publication_recovery :
  sig
    type registry = Publication_recovery_access.registry
    type t = Publication_recovery_access.t
    type owner = Publication_recovery_access.owner
    type registry_error =
        Publication_recovery_access.registry_error
    type owner_discovery_row =
      Publication_recovery_access.owner_discovery_row =
        Discovered_owner of owner
      | Invalid_owner_name of string
    type owner_inventory_row =
      Publication_recovery_access.owner_inventory_row =
        Valid_owner of owner
      | Unexpected_owner_kind of { owner : owner; kind : Eio.File.Stat.kind;
        }
      | Missing_owner_entry of owner
      | Owner_entry_unavailable of { owner : owner; error : registry_error; }
      | Owner_inventory_cancelled of { owner : owner; reason : exn;
          backtrace : Printexc.raw_backtrace;
        }
      | Owner_inventory_crashed of { owner : owner; exception_ : exn;
          backtrace : Printexc.raw_backtrace;
        }
    type discovery_failure =
      Publication_recovery_access.discovery_failure =
        Registry_discovery_failed of registry_error
      | Registry_discovery_cancelled of { reason : exn;
          backtrace : Printexc.raw_backtrace;
        }
      | Registry_discovery_crashed of { exception_ : exn;
          backtrace : Printexc.raw_backtrace;
        }
    type discovery_error =
      Publication_recovery_access.discovery_error =
        Registry_discovery_in_progress
      | Registry_discovery_terminal of discovery_failure
    type inspection_error =
      Publication_recovery_access.inspection_error =
        Inspection_owner_in_progress of owner
      | Inspection_owner_already_terminal of owner_block
    and owner_block =
      Publication_recovery_access.owner_block =
        Owner_inventory_block of owner_inventory_row
      | Owner_reconciliation_block of
          Capability_recovery_reconciler.report
      | Owner_reconciliation_crash of { owner : owner; exception_ : exn;
          backtrace : Printexc.raw_backtrace;
        }
      | Owner_reconciliation_cancelled_block of { owner : owner;
          reason : exn; backtrace : Printexc.raw_backtrace;
        }
    type reconciliation_error =
      Publication_recovery_access.reconciliation_error =
        Owner_inventory_pending of owner
      | Owner_inventory_in_progress of owner
      | Owner_reconciliation_not_required of owner
      | Owner_reconciliation_in_progress of owner
      | Owner_inventory_prevents_reconciliation of owner_inventory_row
      | Owner_reconciliation_crashed of { owner : owner; exception_ : exn;
          backtrace : Printexc.raw_backtrace;
        }
      | Owner_reconciliation_cancelled of { owner : owner; reason : exn;
          backtrace : Printexc.raw_backtrace;
        }
    type access_error =
      Publication_recovery_access.access_error =
        Keeper_lane_not_available
    type lane_open_error =
      Publication_recovery_access.lane_open_error =
        Invalid_owner of
          Capability_recovery_obligation.validation_error
      | Reconciliation_blocked of owner_block
      | Store_failed of registry_error
    type discovery_snapshot =
      Publication_recovery_access.discovery_snapshot =
        Snapshot_discovery_required
      | Snapshot_discovery_running
      | Snapshot_discovery_failed of discovery_failure
      | Snapshot_discovery_complete of owner_discovery_row list
    type owner_activation_snapshot =
      Publication_recovery_access.owner_activation_snapshot =
        Snapshot_owner_inventory_pending of owner
      | Snapshot_owner_inventory_running of owner
      | Snapshot_owner_reconciliation_pending of owner
      | Snapshot_owner_reconciliation_running of owner
      | Snapshot_owner_ready_without_obligation of owner
      | Snapshot_owner_ready of owner *
          Capability_recovery_reconciler.report
      | Snapshot_owner_blocked of owner * owner_block
    type registry_snapshot =
      Publication_recovery_access.registry_snapshot = {
      discovery : discovery_snapshot;
      owners : owner_activation_snapshot list;
    }
    type discovery_health_phase =
      Publication_recovery_access.discovery_health_phase =
        Health_discovery_required
      | Health_discovery_running
      | Health_discovery_failed
      | Health_discovery_complete
    type owner_health_counts =
      Publication_recovery_access.owner_health_counts = {
      inspection_pending : int;
      inspection_running : int;
      reconciliation_pending : int;
      reconciliation_running : int;
      ready_without_obligation : int;
      ready : int;
      blocked : int;
    }
    type health_snapshot =
      Publication_recovery_access.health_snapshot = {
      discovery_phase : discovery_health_phase;
      discovery_row_count : int;
      discovered_owner_count : int;
      invalid_owner_name_count : int;
      retryable_lane_failure_count : int;
      owners : owner_health_counts;
    }
    type health_counter =
      Publication_recovery_access.health_counter =
        Discovery_row_counter
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
      Publication_recovery_access.health_counter_change =
        Increment_health_counter
      | Decrement_health_counter
    type invariant_violation =
      Publication_recovery_access.invariant_violation =
        Borrow_count_underflow
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
      Publication_recovery_access.cleanup_failure = {
      body : Eio.Exn.with_bt option;
      cancellation : Eio.Exn.with_bt option;
      cleanup : Eio.Exn.with_bt;
    }
    exception Cleanup_failed of cleanup_failure
    type body_failed_during_cancellation =
      Publication_recovery_access.body_failed_during_cancellation = {
      body : Eio.Exn.with_bt;
      cancellation : Eio.Exn.with_bt;
    }
    exception Body_failed_during_cancellation of
                body_failed_during_cancellation
    type reconciliation_crash_terminalization_failure =
      Publication_recovery_access.reconciliation_crash_terminalization_failure = {
      reconciliation : Eio.Exn.with_bt;
      terminalization : Eio.Exn.with_bt;
    }
    exception Reconciliation_crash_terminalization_failed of
                reconciliation_crash_terminalization_failure
    type reconciliation_cancellation_terminalization_failure =
      Publication_recovery_access.reconciliation_cancellation_terminalization_failure = {
      cancellation : Eio.Exn.with_bt;
      terminalization : Eio.Exn.with_bt;
    }
    exception Reconciliation_cancellation_terminalization_failed of
                reconciliation_cancellation_terminalization_failure
    val open_registry :
      sw:Eio.Switch.t ->
      fs:Eio.Fs.dir_ty Eio.Path.t ->
      registry_root:Eio.Fs.dir_ty Eio.Path.t ->
      (registry, registry_error) result
    val open_namespaced_registry :
      sw:Eio.Switch.t ->
      fs:Eio.Fs.dir_ty Eio.Path.t ->
      registry_root:Eio.Fs.dir_ty Eio.Path.t ->
      namespace:string -> (registry, registry_error) result
    val discover_owners :
      registry -> (owner_discovery_row list, discovery_error) result
    val inspect_owner :
      registry:registry ->
      owner:owner -> (owner_inventory_row, inspection_error) result
    val health_snapshot : registry -> health_snapshot
    val ensure_owner_ready :
      registry:registry -> owner:string -> (unit, lane_open_error) result
    val owner_to_string : owner -> string
    val reconcile_owner :
      registry:registry ->
      owner:owner ->
      (Capability_recovery_reconciler.report,
       reconciliation_error)
      result
    val report_is_ready :
      Capability_recovery_reconciler.report -> bool
    val report_to_yojson :
      Capability_recovery_reconciler.report ->
      Yojson.Safe.t
    type lane_release_failure =
        Publication_recovery_access.lane_release_failure
    type 'a lane_outcome =
      'a Publication_recovery_access.lane_outcome =
        Lane_released of 'a
      | Lane_release_failed of { value : 'a;
          release_failure : lane_release_failure;
        }
    val with_lane :
      registry:registry ->
      owner:string -> (t -> 'a) -> ('a lane_outcome, lane_open_error) result
    val with_store :
      t ->
      (Capability_recovery_obligation.store -> 'a) ->
      ('a, access_error) result
    val registry_error_to_string : registry_error -> string
    val lane_open_error_to_string : lane_open_error -> string
    val lane_release_failure_to_string : lane_release_failure -> string
    val owner_inventory_row_to_string : owner_inventory_row -> string
    val owner_discovery_row_to_string : owner_discovery_row -> string
    val discovery_failure_to_string : discovery_failure -> string
    val discovery_error_to_string : discovery_error -> string
    val inspection_error_to_string : inspection_error -> string
    val reconciliation_error_to_string : reconciliation_error -> string
    val validation_error_to_string :
      Capability_recovery_obligation.validation_error ->
      string
    val transition_error_to_string : registry_error -> string
    module For_testing =
      Publication_recovery_access.For_testing
    val directory_leaf : string
    type lane_open_error_category =
        Invalid_owner_category
      | Reconciliation_blocked_category
      | Store_failed_category
    val lane_open_error_category :
      lane_open_error -> lane_open_error_category
    module Core = Capability_recovery_obligation
    val safe_exception : exn -> string
    val safe_failure : Core.failure -> string
    val safe_registry_error : registry_error -> string
    val safe_lane_open_error : lane_open_error -> string
    val safe_lane_release_failure : lane_release_failure -> string
  end

val capability_publication_target :
  allowed_root_path:string ->
  allowed_root_device:int64 ->
  allowed_root_inode:int64 ->
  parent_components:string list ->
  target_leaf:string ->
  permissions:int ->
  (capability_publication_target, capability_publication_target_error) result

val capability_publication_target_error_to_string :
  capability_publication_target_error -> string

type capability_write_operation = Atomic_write.capability_write_operation =
  | Atomic_replace_operation
  | Create_exclusive_operation

type capability_write_stage = Atomic_write.capability_write_stage =
  | Acquire_mutation_lease
  | Acquire_publication_lease
  | Inspect_target_entry
  | Verify_target_binding
  | Prepare_recovery_obligation
  | Create_staging_directory
  | Inspect_staging_directory
  | Acquire_staging_directory
  | Apply_staging_directory_permissions
  | Verify_staging_directory_identity
  | Preserve_unbound_recovery_obligation
  | Bind_recovery_obligation
  | Create_staging_entry
  | Inspect_open_resource
  | Write_payload
  | Apply_permissions
  | Sync_payload
  | Close_payload
  | Verify_entry_identity
  | Publish_replace
  | Publish_exclusive
  | Sync_staging_directory
  | Sync_parent
  | Remove_staging_directory
  | Close_staging_directory
  | Discharge_bound_recovery_obligation
  | Cleanup_close
  | Cleanup_verify_identity
  | Cleanup_unlink
  | Cleanup_sync_staging_directory
  | Cleanup_verify_staging_directory_identity
  | Cleanup_remove_staging_directory
  | Cleanup_close_staging_directory
  | Cleanup_sync_parent

type capability_write_target_effect = Atomic_write.capability_write_target_effect =
  | Target_unchanged
  | Target_created
  | Target_replaced
  | Target_state_unknown

type capability_write_operation_failure =
  Atomic_write.capability_write_operation_failure =
  { exception_ : exn
  ; backtrace : Printexc.raw_backtrace
  }

type capability_write_payload_failure = Atomic_write.capability_write_payload_failure =
  { exception_ : exn
  ; backtrace : Printexc.raw_backtrace
  ; bytes_written : int
  }

type capability_write_cause = Atomic_write.capability_write_cause =
  | Invalid_recovery_target of capability_publication_target_error
  | Mutation_contended
  | Target_already_exists
  | Posix_descriptor_unavailable
  | Unexpected_resource_kind of Eio.File.Stat.kind
  | Resource_identity_unavailable
  | Resource_identity_changed
  | Payload_write_failed of capability_write_payload_failure
  | Operation_failed of capability_write_operation_failure

type capability_write_failure = Atomic_write.capability_write_failure =
  { stage : capability_write_stage
  ; cause : capability_write_cause
  }

type capability_recovery_phase = Atomic_write.capability_recovery_phase =
  | Recovery_prepare
  | Recovery_preserve_unbound
  | Recovery_bind
  | Recovery_discharge_prepared
  | Recovery_discharge_bound

type capability_recovery_removal_transition =
  Atomic_write.capability_recovery_removal_transition =
  | Recovery_discharge_active
  | Recovery_discharge_owned
  | Recovery_active_to_owned
  | Recovery_active_to_forensic
  | Recovery_owned_to_forensic

type capability_recovery_effect = Atomic_write.capability_recovery_effect =
  | Recovery_no_record_change
  | Recovery_layout_may_be_incomplete
  | Recovery_layout_ready
  | Recovery_active_record_state_unknown
  | Recovery_active_record_durable
  | Recovery_active_record_discharged
  | Recovery_owned_record_state_unknown_with_active
  | Recovery_owned_record_durable_with_active
  | Recovery_owned_record_durable
  | Recovery_owned_record_discharged
  | Recovery_forensic_record_state_unknown_with_source
  | Recovery_forensic_record_durable_with_source
  | Recovery_forensic_record_durable
  | Recovery_source_removal_durability_unknown of
      capability_recovery_removal_transition

type capability_recovery_failure = Atomic_write.capability_recovery_failure

val capability_recovery_phase_to_string : capability_recovery_phase -> string

val capability_recovery_effect_to_string : capability_recovery_effect -> string

val capability_recovery_failure_phase :
  capability_recovery_failure -> capability_recovery_phase

val capability_recovery_failure_effect :
  capability_recovery_failure -> capability_recovery_effect

val capability_recovery_failure_to_string :
  capability_recovery_failure -> string

type capability_recovery_access_failure =
  Atomic_write.capability_recovery_access_failure =
  | Recovery_access_not_available

type capability_write_primary_failure =
  Atomic_write.capability_write_primary_failure =
  | Write_primary_failure of capability_write_failure
  | Recovery_primary_failure of capability_recovery_failure
  | Recovery_access_primary_failure of capability_recovery_access_failure

type capability_write_cleanup_failure =
  Atomic_write.capability_write_cleanup_failure =
  | Write_cleanup_failure of capability_write_failure
  | Recovery_cleanup_failure of capability_recovery_failure

type capability_write_error = Atomic_write.capability_write_error =
  { operation : capability_write_operation
  ; target_effect : capability_write_target_effect
  ; primary_failure : capability_write_primary_failure
  ; cleanup_failures : capability_write_cleanup_failure list
  }

type capability_directory_sync_error = Atomic_write.capability_directory_sync_error =
  { failure : capability_write_failure
  ; cleanup_failures : capability_write_failure list
  }

type capability_write_cancellation = Atomic_write.capability_write_cancellation =
  { operation : capability_write_operation
  ; target_effect : capability_write_target_effect
  ; interrupted_primary_failure : capability_write_primary_failure option
  ; interrupted_recovery : capability_recovery_failure option
  ; cleanup_failures : capability_write_cleanup_failure list
  }

exception Capability_write_cancelled of exn * capability_write_cancellation

val replace_capability_file :
  recovery:Publication_recovery.t ->
  parent:Eio.Fs.dir_ty Eio.Path.t ->
  target:capability_publication_target ->
  string -> (unit, capability_write_error) result

val create_capability_file_exclusive :
  recovery:Publication_recovery.t ->
  parent:Eio.Fs.dir_ty Eio.Path.t ->
  target:capability_publication_target ->
  string -> (unit, capability_write_error) result

val create_capability_directory_exclusive :
  recovery:Publication_recovery.t ->
  parent:Eio.Fs.dir_ty Eio.Path.t ->
  target:capability_publication_target ->
  directory_payload -> (unit, capability_write_error) result

val capability_write_error_to_string : capability_write_error -> string

type create_file_failure =
  | Target_rejected of capability_publication_target_error
  | Registry_failed of Publication_recovery.registry_error
  | Lane_failed of Publication_recovery.lane_open_error
  | Publication_failed of capability_write_error
  | Lane_release_failed of {
      value : (unit, capability_write_error) result;
      release_failure : Publication_recovery.lane_release_failure;
    }

type create_file_error =
  | Create_failed of create_file_failure
  | Boundary_failed of {
      observed : (unit, create_file_failure) result option;
      failure : Eio.Exn.with_bt;
    }

val create_file_error_target_effect :
  create_file_error -> capability_write_target_effect option
(** [None] means no target-effect evidence was received. Preparation errors do
    not establish the destination's state. A returned write or lane-release
    failure retains its original publication result, including creation. *)
val create_file_error_to_string : create_file_error -> string

type create_file_cancellation
val create_file_cancellation : exn -> create_file_cancellation option
(** Recognize cancellation structurally, retaining the original exception and
    nested publication/recovery/cleanup evidence. Does not consume or re-raise it. *)
val create_file_cancellation_effect :
  create_file_cancellation -> capability_write_target_effect option
(** [None] is unobserved, never proof that the destination was unchanged. *)
val create_file_cancellation_to_string : create_file_cancellation -> string

val create_file_exclusive :
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  owner:string ->
  path:string -> permissions:int -> string -> (unit, create_file_error) result
(** Preserve typed publication and lane-release results. Expected path-boundary
    failures retain any result already observed before cleanup. Cancellation
    and fatal exceptions propagate with their original backtraces. *)

val capability_write_operation_to_string : capability_write_operation -> string

val capability_write_stage_to_string : capability_write_stage -> string

val capability_write_target_effect_to_string :
  capability_write_target_effect -> string

val capability_write_cause_to_string : capability_write_cause -> string

val capability_write_failure_to_string : capability_write_failure -> string

val sync_directory_capability :
  [> Eio.Fs.dir_ty ] Eio.Path.t ->
  (unit, capability_directory_sync_error) result

val is_atomic_orphan_name : string -> bool

type atomic_orphan_cleanup_operation = Atomic_orphan_cleanup.atomic_orphan_cleanup_operation =
  | Inspect_cleanup_root
  | Read_cleanup_directory
  | Inspect_orphan
  | Create_recovery_directory
  | Sync_recovery_parent
  | Link_preserved_orphan
  | Verify_preserved_orphan
  | Sync_preserved_orphan
  | Sync_recovery_directory
  | Delete_empty_orphan
  | Delete_preserved_source
  | Sync_source_directory
  | Close_cleanup_descriptor

type atomic_orphan_cleanup_cause = Atomic_orphan_cleanup.atomic_orphan_cleanup_cause =
  | Unix_failure of Unix.error * string * string
  | Sys_failure of string
  | Unexpected_file_kind of Unix.file_kind
  | Outside_ownership_root of { ownership_root : string }
  | Identity_changed
  | Other_failure of exn

type atomic_orphan_cleanup_failure = Atomic_orphan_cleanup.atomic_orphan_cleanup_failure =
  { operation : atomic_orphan_cleanup_operation
  ; path : string
  ; cause : atomic_orphan_cleanup_cause
  }

type atomic_orphan_cleanup_report = Atomic_orphan_cleanup.atomic_orphan_cleanup_report =
  { inspected : int
  ; deleted : int
  ; preserved : int
  ; failures : atomic_orphan_cleanup_failure list
  }

val atomic_orphan_cleanup_failure_to_string :
  atomic_orphan_cleanup_failure -> string

val cleanup_atomic_orphans :
  ownership_root:string ->
  base_path:string -> unit -> atomic_orphan_cleanup_report
