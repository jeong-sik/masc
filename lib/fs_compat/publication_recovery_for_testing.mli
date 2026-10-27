(** Explicit fixture and state-machine surface for repository tests.

    Production code must use the narrow [Fs_compat.Publication_recovery]
    facade. This module belongs to a workspace-only Dune library and is not
    installed with [masc.fs_compat]. *)

open Fs_compat_internal

include module type of Publication_recovery_access

type discharge_record = Prepared_record | Bound_record
type discharge_cancellation

val discharge_cancellation
  : owner:string -> record:discharge_record -> reason:exn
  -> backtrace:Printexc.raw_backtrace
  -> (discharge_cancellation,
      Capability_recovery_obligation.validation_error) result

val with_discharge_cancellation
  : discharge_cancellation -> (unit -> 'a) -> 'a
(** Cancel after the real matching record unlink and before directory sync.
    Scoped to the invoking fiber and exact owner/record kind. No writer or
    recovery effect can be supplied by the fixture. *)

type lane_scope_release_fault

val lane_scope_release_fault
  :  owner:string
  -> exception_:exn
  -> (lane_scope_release_fault,
      Capability_recovery_obligation.validation_error)
       result

val with_lane_scope_release_fault
  :  lane_scope_release_fault
  -> (unit -> 'a)
  -> 'a

type replace_dispatch_fault

type replace_dispatch_fault_stage =
  | Before_publish_replace
  | Before_parent_sync

val replace_dispatch_fault
  :  stage:replace_dispatch_fault_stage
  -> exception_:exn
  -> replace_dispatch_fault

val parent_sync_dispatch_fault : exception_:exn -> replace_dispatch_fault
(** Fail the real post-publication parent sync and its cleanup retry. *)

val before_parent_sync_dispatch : before_sync:(unit -> unit) -> replace_dispatch_fault
(** Interleave in the invoking fiber after actual publication and immediately
    before the actual parent fsync. Used with [with_replace_dispatch_fault];
    it preserves the production writer and performs no replacement effect. *)

val with_replace_dispatch_fault
  :  replace_dispatch_fault
  -> (unit -> 'a)
  -> 'a

val remove_staging_payload_before_publish
  :  unit
  -> replace_dispatch_fault

type record_area =
  | Active
  | Owned
  | Forensic

val record_names : t -> area:record_area -> (string list, access_error) result
(** Read the real owner-area directory through the borrowed store capability.
    No path reconstruction, mutation or record repair is performed. *)

type fixture_error

type resource_scope_callback =
  | Return_completed_rows of string list
  | Cancel_callback of exn

type resource_scope_evidence =
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

val fixture_error_to_string : fixture_error -> string

val run_resource_scope
  :  callback:resource_scope_callback
  -> release_failure:exn option
  -> resource_scope_evidence

val stage_name : Uuidm.t -> string

val seed_prepared
  :  registry:registry
  -> owner:string
  -> operation_id:Uuidm.t
  -> allowed_root_path:string
  -> allowed_root_device:int64
  -> allowed_root_inode:int64
  -> parent_components:string list
  -> parent_device:int64
  -> parent_inode:int64
  -> target_leaf:string
  -> permissions:int
  -> (unit, fixture_error) result

val seed_bound
  :  registry:registry
  -> owner:string
  -> operation_id:Uuidm.t
  -> allowed_root_path:string
  -> allowed_root_device:int64
  -> allowed_root_inode:int64
  -> parent_components:string list
  -> parent_device:int64
  -> parent_inode:int64
  -> target_leaf:string
  -> permissions:int
  -> stage_device:int64
  -> stage_inode:int64
  -> (unit, fixture_error) result

val write_raw_record
  :  registry:registry
  -> owner:string
  -> area:record_area
  -> record_name:string
  -> raw:string
  -> (unit, fixture_error) result
