(** Store model of the publication recovery obligations: the fixed directory
    names and permissions, the areas, subjects and operations a store failure
    names, the failure and transition-error values, their string renderings,
    the exceptions that carry them, and the fiber keys that hold cancellation
    evidence.

    This module is private to [fs_compat_internal] and has no interface file.
    [Capability_recovery_obligation] includes it, and its interface keeps the
    parts callers use. *)

open Capability_recovery_record

type area =
  | Active
  | Owned
  | Forensic

type subject =
  | Registry_root
  | Recovery_root
  | Lanes_root
  | Staging_root
  | Staged_lane of owner
  | Lane_root of owner
  | Lane_entry of owner * string
  | Area of area * owner
  | Record of area * owner * operation_id

type operation =
  | Inspect_directory
  | Create_directory
  | Open_directory
  | Close_directory
  | Sync_directory
  | Read_directory
  | Rename_directory
  | Remove_directory
  | Inspect_record
  | Open_record
  | Read_record
  | Decode_record
  | Create_record
  | Apply_permissions
  | Write_record
  | Sync_record
  | Close_record
  | Verify_record_identity
  | Remove_record

type failure_cause =
  | Validation_failed of validation_error
  | Io_failed of
      { exception_ : exn
      ; backtrace : Printexc.raw_backtrace
      }
  | Write_failed of
      { exception_ : exn
      ; backtrace : Printexc.raw_backtrace
      ; bytes_written : int
      }
  | Unexpected_resource_kind of Eio.File.Stat.kind
  | Resource_identity_changed of
      { expected : identity
      ; actual : identity
      }
  | Posix_descriptor_unavailable
  | Existing_record_does_not_match
  | Created_record_identity_unavailable
  | Missing_record

type failure =
  { operation : operation
  ; subject : subject
  ; cause : failure_cause
  }

type transition_effect =
  | No_record_change
  | Layout_may_be_incomplete
  | Layout_ready
  | Active_record_state_unknown
  | Active_record_durable
  | Active_record_discharged
  | Owned_record_state_unknown_with_active
  | Owned_record_durable_with_active
  | Owned_record_durable
  | Owned_record_discharged
  | Forensic_record_state_unknown_with_source
  | Forensic_record_durable_with_source
  | Forensic_record_durable
  | Source_removal_durability_unknown of removal_transition

and removal_transition =
  | Discharge_active
  | Discharge_owned
  | Active_to_owned
  | Active_to_forensic
  | Owned_to_forensic

type transition_error =
  { store_effect : transition_effect
  ; failure : failure
  ; cleanup_failures : failure list
  }

type registry =
  { recovery : Eio.Fs.dir_ty Eio.Path.t
  ; lanes : Eio.Fs.dir_ty Eio.Path.t
  }

type area_capability =
  | Area_available of Eio.Fs.dir_ty Eio.Path.t
  | Area_unavailable of transition_error

type lane_residue =
  | Lane_residue_present of
      { name : string
      ; kind : Eio.File.Stat.kind
      }
  | Lane_residue_missing of { name : string }
  | Lane_residue_unavailable of
      { name : string
      ; error : transition_error
      }

type store =
  { owner : owner
  ; active : area_capability
  ; owned : area_capability
  ; forensic : area_capability
  ; lane_residues : lane_residue list
  }

type resource_release_failure =
  { failure : failure
  ; exception_ : exn
  ; backtrace : Printexc.raw_backtrace
  }

type 'a store_scope_outcome =
  | Store_scope_released of 'a
  | Store_scope_release_failed of
      { value : 'a
      ; release_failure : resource_release_failure
      }

type 'a existing_store_scope_outcome =
  | Existing_store_scope_released of 'a
  | Existing_store_scope_release_failed of
      { value : 'a
      ; release_failure : resource_release_failure
      }
  | Existing_store_scope_cancelled of
      { value : 'a option
      ; reason : exn
      ; backtrace : Printexc.raw_backtrace
      ; release_failure : resource_release_failure option
      }

exception Recovery_store_cancelled of
  exn * transition_effect * failure list

exception Store_failure of failure
exception Internal_unexpected_resource_kind of Eio.File.Stat.kind
exception Internal_resource_identity_changed of identity * identity
exception Internal_posix_descriptor_unavailable
exception Internal_existing_record_does_not_match
exception Internal_created_record_identity_unavailable
exception Internal_missing_record
exception Internal_resource_scope_callback_not_entered
exception Transition_failed of transition_error

let recovery_directory_leaf = "fs-publication-recovery"
let lanes_directory_leaf = "lanes"
let staging_directory_leaf = "staging"
let active_directory_leaf = "active"
let owned_directory_leaf = "owned"
let forensic_directory_leaf = "forensic"
let directory_permissions = 0o700
let record_permissions = 0o600

type lane_scope_release_fault =
  { fault_owner : owner
  ; fault_exception : exn
  }

let lane_scope_release_fault_key
      : lane_scope_release_fault Eio.Fiber.key
  =
  Eio.Fiber.create_key ()
;;

let matching_lane_scope_release_fault owner =
  match Eio.Fiber.get lane_scope_release_fault_key with
  | Some fault when equal_owner owner fault.fault_owner -> Some fault
  | None | Some _ -> None
;;

type discharge_record = Prepared_record | Bound_record

type discharge_cancellation =
  { discharge_owner : owner
  ; discharge_transition : removal_transition
  ; discharge_reason : exn
  ; discharge_backtrace : Printexc.raw_backtrace
  }

let discharge_cancellation_key : discharge_cancellation Eio.Fiber.key =
  Eio.Fiber.create_key ()
;;

let record_name = operation_id_to_string

let store_owner (store : store) = store.owner

let identity_of_stat (stat : Eio.File.Stat.t) =
  { dev = stat.dev; ino = stat.ino }
;;

let area_to_string = function
  | Active -> "active"
  | Owned -> "owned"
  | Forensic -> "forensic"
;;

let area_directory_leaf = function
  | Active -> active_directory_leaf
  | Owned -> owned_directory_leaf
  | Forensic -> forensic_directory_leaf
;;

let subject_to_string = function
  | Registry_root -> "registry_root"
  | Recovery_root -> "recovery_root"
  | Lanes_root -> "lanes_root"
  | Staging_root -> "staging_root"
  | Staged_lane owner ->
    Printf.sprintf "staged_lane(%S)" (owner_to_string owner)
  | Lane_root owner -> Printf.sprintf "lane(%S)" (owner_to_string owner)
  | Lane_entry (owner, name) ->
    Printf.sprintf "lane(%S)/%S" (owner_to_string owner) name
  | Area (area, owner) ->
    Printf.sprintf "%s(%S)" (area_to_string area) (owner_to_string owner)
  | Record (area, owner, operation_id) ->
    Printf.sprintf
      "%s(%S)/%s"
      (area_to_string area)
      (owner_to_string owner)
      (record_name operation_id)
;;

let operation_to_string = function
  | Inspect_directory -> "inspect_directory"
  | Create_directory -> "create_directory"
  | Open_directory -> "open_directory"
  | Close_directory -> "close_directory"
  | Sync_directory -> "sync_directory"
  | Read_directory -> "read_directory"
  | Rename_directory -> "rename_directory"
  | Remove_directory -> "remove_directory"
  | Inspect_record -> "inspect_record"
  | Open_record -> "open_record"
  | Read_record -> "read_record"
  | Decode_record -> "decode_record"
  | Create_record -> "create_record"
  | Apply_permissions -> "apply_permissions"
  | Write_record -> "write_record"
  | Sync_record -> "sync_record"
  | Close_record -> "close_record"
  | Verify_record_identity -> "verify_record_identity"
  | Remove_record -> "remove_record"
;;

let transition_effect_to_string = function
  | No_record_change -> "no_record_change"
  | Layout_may_be_incomplete -> "layout_may_be_incomplete"
  | Layout_ready -> "layout_ready"
  | Active_record_state_unknown -> "active_record_state_unknown"
  | Active_record_durable -> "active_record_durable"
  | Active_record_discharged -> "active_record_discharged"
  | Owned_record_state_unknown_with_active ->
    "owned_record_state_unknown_with_active"
  | Owned_record_durable_with_active -> "owned_record_durable_with_active"
  | Owned_record_durable -> "owned_record_durable"
  | Owned_record_discharged -> "owned_record_discharged"
  | Forensic_record_state_unknown_with_source ->
    "forensic_record_state_unknown_with_source"
  | Forensic_record_durable_with_source ->
    "forensic_record_durable_with_source"
  | Forensic_record_durable -> "forensic_record_durable"
  | Source_removal_durability_unknown transition ->
    let source_area, destination =
      match transition with
      | Discharge_active -> Active, "none"
      | Discharge_owned -> Owned, "none"
      | Active_to_owned -> Active, area_to_string Owned
      | Active_to_forensic -> Active, area_to_string Forensic
      | Owned_to_forensic -> Owned, area_to_string Forensic
    in
    Printf.sprintf
      "source_removal_durability_unknown(source=%s,destination=%s)"
      (area_to_string source_area)
      destination
;;

let failure_to_string (failure : failure) =
  let cause =
    match failure.cause with
    | Validation_failed error -> validation_error_to_string error
    | Io_failed { exception_; _ } -> Printexc.to_string exception_
    | Write_failed { exception_; bytes_written; _ } ->
      Printf.sprintf
        "write failed after bytes_written=%d: %s"
        bytes_written
        (Printexc.to_string exception_)
    | Unexpected_resource_kind kind ->
      Format.asprintf "unexpected resource kind %a" Eio.File.Stat.pp_kind kind
    | Resource_identity_changed { expected; actual } ->
      Printf.sprintf
        "resource identity changed expected=%Ld:%Ld actual=%Ld:%Ld"
        expected.dev
        expected.ino
        actual.dev
        actual.ino
    | Posix_descriptor_unavailable -> "POSIX descriptor unavailable"
    | Existing_record_does_not_match -> "existing record does not match"
    | Created_record_identity_unavailable ->
      "created record identity unavailable"
    | Missing_record -> "record is missing"
  in
  Printf.sprintf
    "operation=%s subject=%s cause=%s"
    (operation_to_string failure.operation)
    (subject_to_string failure.subject)
    cause
;;

let transition_error_to_string (error : transition_error) =
  let cleanup =
    match error.cleanup_failures with
    | [] -> ""
    | failures ->
      failures
      |> List.map failure_to_string
      |> String.concat "; "
      |> Printf.sprintf " cleanup_failures=[%s]"
  in
  Printf.sprintf
    "effect=%s failure=(%s)%s"
    (transition_effect_to_string error.store_effect)
    (failure_to_string error.failure)
    cleanup
;;

let cause_of_exception exception_ backtrace =
  match exception_ with
  | Record_validation_failed error -> Validation_failed error
  | Internal_unexpected_resource_kind kind -> Unexpected_resource_kind kind
  | Internal_resource_identity_changed (expected, actual) ->
    Resource_identity_changed { expected; actual }
  | Internal_posix_descriptor_unavailable -> Posix_descriptor_unavailable
  | Internal_existing_record_does_not_match ->
    Existing_record_does_not_match
  | Internal_created_record_identity_unavailable ->
    Created_record_identity_unavailable
  | Internal_missing_record -> Missing_record
  | exception_ -> Io_failed { exception_; backtrace }
;;

let make_failure ~operation ~subject exception_ backtrace =
  { operation; subject; cause = cause_of_exception exception_ backtrace }
;;

let raise_io ~operation ~subject f =
  try f () with
  | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
  | Store_failure _ as failure -> raise failure
  | exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    raise
      (Store_failure
         (make_failure ~operation ~subject exception_ backtrace))
;;

let raise_validation ~operation ~subject validation_error =
  raise
    (Store_failure
       { operation; subject; cause = Validation_failed validation_error })
;;

let transition_error ~store_effect failure =
  { store_effect; failure; cleanup_failures = [] }
;;
