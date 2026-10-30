open Fs_compat_internal

include Publication_recovery_access

type discharge_record =
  Capability_recovery_obligation.For_testing.discharge_record =
  | Prepared_record
  | Bound_record

type discharge_cancellation =
  Capability_recovery_obligation.For_testing.discharge_cancellation

let discharge_cancellation =
  Capability_recovery_obligation.For_testing.discharge_cancellation
;;

let with_discharge_cancellation =
  Capability_recovery_obligation.For_testing.with_discharge_cancellation
;;

type lane_scope_release_fault =
  Capability_recovery_obligation.For_testing.lane_scope_release_fault

let lane_scope_release_fault =
  Capability_recovery_obligation.For_testing.lane_scope_release_fault
;;

let with_lane_scope_release_fault =
  Capability_recovery_obligation.For_testing.with_lane_scope_release_fault
;;

type replace_dispatch_fault =
  Atomic_write.Capability_write_for_testing.replace_dispatch_fault

type replace_dispatch_fault_stage =
  | Before_publish_replace
  | Before_parent_sync

(* TEL-OK: this workspace-only constructor maps a typed test stage; no write occurs. *)
let replace_dispatch_fault ~stage ~exception_ =
  let stage =
    match stage with
    | Before_publish_replace -> Atomic_write.Publish_replace
    | Before_parent_sync -> Atomic_write.Sync_parent
  in
  Atomic_write.Capability_write_for_testing.replace_dispatch_fault
    ~stage
    ~exception_
;;

(* TEL-OK: the internal fiber binding is exercised through the real write operation. *)
let with_replace_dispatch_fault =
  Atomic_write.Capability_write_for_testing.with_replace_dispatch_fault
;;

let parent_sync_dispatch_fault =
  Atomic_write.Capability_write_for_testing.parent_sync_dispatch_fault

let before_parent_sync_dispatch =
  Atomic_write.Capability_write_for_testing.before_parent_sync_dispatch

let remove_staging_payload_before_publish =
  Atomic_write.Capability_write_for_testing.remove_staging_payload_before_publish
;;

type record_area =
  | Active
  | Owned
  | Forensic

let record_names access ~area =
  let area = match area with
    | Active -> Capability_recovery_obligation.Active
    | Owned -> Capability_recovery_obligation.Owned
    | Forensic -> Capability_recovery_obligation.Forensic
  in
  with_store access (fun store ->
    Eio.Path.read_dir
      (Capability_recovery_obligation.For_testing.area_directory store area))
;;

type fixture_error = Atomic_write.publication_recovery_fixture_error

type resource_scope_callback =
  Atomic_write.Capability_write_for_testing.resource_scope_callback =
  | Return_completed_rows of string list
  | Cancel_callback of exn

type resource_scope_evidence =
  Atomic_write.Capability_write_for_testing.resource_scope_evidence =
  | Returned_rows of
      { completed_rows : string list
      ; release_failure : exn option
      }
  | Cancelled_callback of
      { reason : exn
      ; release_failure : exn option
      }
  | Raised_callback of
      { exception_ : exn
      ; release_failure : exn option
      }

let fixture_error_to_string =
  Atomic_write.publication_recovery_fixture_error_to_string
;;

let run_resource_scope =
  Atomic_write.Capability_write_for_testing.run_publication_recovery_resource_scope
;;

let stage_name =
  Atomic_write.Capability_write_for_testing.publication_recovery_stage_name
;;

let seed_prepared =
  Atomic_write.Capability_write_for_testing.seed_prepared_publication_recovery
;;

let seed_bound =
  Atomic_write.Capability_write_for_testing.seed_bound_publication_recovery
;;

let write_raw_record ~registry ~owner ~area ~record_name ~raw =
  let area =
    match area with
    | Active -> Atomic_write.Publication_recovery_active
    | Owned -> Atomic_write.Publication_recovery_owned
    | Forensic -> Atomic_write.Publication_recovery_forensic
  in
  Atomic_write.Capability_write_for_testing.write_raw_publication_recovery_record
    ~registry
    ~owner
    ~area
    ~record_name
    ~raw
;;
