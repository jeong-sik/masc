(** JSON form of a publication recovery reconciliation report: structured
    evidence for each row, observed entry, record outcome, transition error
    and cleanup failure, built constructor by constructor.

    This module is private to [fs_compat_internal] and has no interface file.
    [Capability_recovery_reconciler] includes it. *)

open Capability_recovery_reconciler_model
open Capability_recovery_reconciler_text

let file_kind_to_string kind =
  Format.asprintf "%a" Eio.File.Stat.pp_kind kind
;;

let exception_to_yojson exception_ backtrace =
  `Assoc
    [ "message", `String (Printexc.to_string exception_)
    ; "backtrace", `String (Printexc.raw_backtrace_to_string backtrace)
    ]
;;

let identity_to_yojson identity =
  `Assoc
    [ "device", `Intlit (Int64.to_string identity.device)
    ; "inode", `Intlit (Int64.to_string identity.inode)
    ]
;;

let core_identity_to_yojson identity =
  identity |> identity_of_core |> identity_to_yojson
;;

let entry_observation_to_yojson = function
  | Entry_absent -> `Assoc [ "kind", `String "absent" ]
  | Entry_present { kind; identity } ->
    `Assoc
      [ "kind", `String "present"
      ; "identity", identity_to_yojson identity
      ]
;;

let resource_mismatch_to_yojson mismatch =
  `Assoc
    [ "expected", identity_to_yojson mismatch.expected
    ; "observed", entry_observation_to_yojson mismatch.observed
    ]
;;

let prepared_outcome_to_yojson = function
  | Prepared_unmaterialized ->
    `Assoc [ "kind", `String "unmaterialized" ]
  | Prepared_allowed_root_mismatch mismatch ->
    `Assoc
      [ "kind", `String "allowed_root_mismatch"
      ; "mismatch", resource_mismatch_to_yojson mismatch
      ]
  | Prepared_parent_mismatch mismatch ->
    `Assoc
      [ "kind", `String "parent_mismatch"
      ; "mismatch", resource_mismatch_to_yojson mismatch
      ]
  | Prepared_unbound_stage_preserved { kind; identity } ->
    `Assoc
      [ "kind", `String "unbound_stage_preserved"
      ; "identity", identity_to_yojson identity
      ]
;;

let bound_outcome_to_yojson = function
  | Bound_stage_absent { observed_target } ->
    `Assoc
      [ "kind", `String "stage_absent"
      ; "observed_target", entry_observation_to_yojson observed_target
      ]
  | Bound_allowed_root_mismatch mismatch ->
    `Assoc
      [ "kind", `String "allowed_root_mismatch"
      ; "mismatch", resource_mismatch_to_yojson mismatch
      ]
  | Bound_parent_mismatch mismatch ->
    `Assoc
      [ "kind", `String "parent_mismatch"
      ; "mismatch", resource_mismatch_to_yojson mismatch
      ]
  | Bound_stage_mismatch { mismatch; observed_target } ->
    `Assoc
      [ "kind", `String "stage_mismatch"
      ; "mismatch", resource_mismatch_to_yojson mismatch
      ; "observed_target", entry_observation_to_yojson observed_target
      ]
  | Bound_stage_preserved { kind; identity; observed_target } ->
    `Assoc
      [ "kind", `String "stage_preserved"
      ; "identity", identity_to_yojson identity
      ; "observed_target", entry_observation_to_yojson observed_target
      ]
;;

let core_record_area_to_string = function
  | Core.Active -> "active"
  | Core.Owned -> "owned"
  | Core.Forensic -> "forensic"
;;

let core_removal_transition_to_string = function
  | Core.Discharge_active -> "discharge_active"
  | Core.Discharge_owned -> "discharge_owned"
  | Core.Active_to_owned -> "active_to_owned"
  | Core.Active_to_forensic -> "active_to_forensic"
  | Core.Owned_to_forensic -> "owned_to_forensic"
;;

let core_transition_effect_to_yojson = function
  | Core.No_record_change -> `Assoc [ "kind", `String "no_record_change" ]
  | Core.Layout_may_be_incomplete ->
    `Assoc [ "kind", `String "layout_may_be_incomplete" ]
  | Core.Layout_ready -> `Assoc [ "kind", `String "layout_ready" ]
  | Core.Active_record_state_unknown ->
    `Assoc [ "kind", `String "active_record_state_unknown" ]
  | Core.Active_record_durable ->
    `Assoc [ "kind", `String "active_record_durable" ]
  | Core.Active_record_discharged ->
    `Assoc [ "kind", `String "active_record_discharged" ]
  | Core.Owned_record_state_unknown_with_active ->
    `Assoc [ "kind", `String "owned_record_state_unknown_with_active" ]
  | Core.Owned_record_durable_with_active ->
    `Assoc [ "kind", `String "owned_record_durable_with_active" ]
  | Core.Owned_record_durable ->
    `Assoc [ "kind", `String "owned_record_durable" ]
  | Core.Owned_record_discharged ->
    `Assoc [ "kind", `String "owned_record_discharged" ]
  | Core.Forensic_record_state_unknown_with_source ->
    `Assoc
      [ "kind", `String "forensic_record_state_unknown_with_source" ]
  | Core.Forensic_record_durable_with_source ->
    `Assoc [ "kind", `String "forensic_record_durable_with_source" ]
  | Core.Forensic_record_durable ->
    `Assoc [ "kind", `String "forensic_record_durable" ]
  | Core.Source_removal_durability_unknown transition ->
    `Assoc
      [ "kind", `String "source_removal_durability_unknown"
      ; "transition", `String (core_removal_transition_to_string transition)
      ]
;;

let core_validation_error_to_yojson = function
  | Core.Invalid_owner value ->
    `Assoc [ "kind", `String "invalid_owner"; "value", `String value ]
  | Core.Invalid_operation_id value ->
    `Assoc
      [ "kind", `String "invalid_operation_id"; "value", `String value ]
  | Core.Invalid_identity identity ->
    `Assoc
      [ "kind", `String "invalid_identity"
      ; "identity", core_identity_to_yojson identity
      ]
  | Core.Invalid_allowed_root_path value ->
    `Assoc
      [ "kind", `String "invalid_allowed_root_path"
      ; "value", `String value
      ]
  | Core.Empty_parent_path_identity_mismatch { allowed_root; parent } ->
    `Assoc
      [ "kind", `String "empty_parent_path_identity_mismatch"
      ; "allowed_root", core_identity_to_yojson allowed_root
      ; "parent", core_identity_to_yojson parent
      ]
  | Core.Invalid_parent_component { index; value } ->
    `Assoc
      [ "kind", `String "invalid_parent_component"
      ; "index", `Int index
      ; "value", `String value
      ]
  | Core.Invalid_target_leaf value ->
    `Assoc
      [ "kind", `String "invalid_target_leaf"; "value", `String value ]
  | Core.Invalid_permissions value ->
    `Assoc
      [ "kind", `String "invalid_permissions"; "value", `Int value ]
  | Core.Invalid_record_json { exception_; backtrace } ->
    `Assoc
      [ "kind", `String "invalid_record_json"
      ; "exception", exception_to_yojson exception_ backtrace
      ]
  | Core.Invalid_record_shape ->
    `Assoc [ "kind", `String "invalid_record_shape" ]
  | Core.Unsupported_record_version version ->
    `Assoc
      [ "kind", `String "unsupported_record_version"
      ; "version", `Int version
      ]
  | Core.Record_state_mismatch ->
    `Assoc [ "kind", `String "record_state_mismatch" ]
  | Core.Record_owner_mismatch { expected; actual } ->
    `Assoc
      [ "kind", `String "record_owner_mismatch"
      ; "expected", `String (Core.owner_to_string expected)
      ; "actual", `String (Core.owner_to_string actual)
      ]
  | Core.Record_operation_id_mismatch { expected; actual } ->
    `Assoc
      [ "kind", `String "record_operation_id_mismatch"
      ; "expected", `String (Core.operation_id_to_string expected)
      ; "actual", `String (Core.operation_id_to_string actual)
      ]
  | Core.Record_stage_leaf_mismatch { expected; actual } ->
    `Assoc
      [ "kind", `String "record_stage_leaf_mismatch"
      ; "expected", `String expected
      ; "actual", `String actual
      ]
  | Core.Record_identity_mismatch { expected; actual } ->
    `Assoc
      [ "kind", `String "record_identity_mismatch"
      ; "expected", core_identity_to_yojson expected
      ; "actual", core_identity_to_yojson actual
      ]
  | Core.Record_kind_mismatch { expected; actual } ->
    `Assoc
      [ "kind", `String "record_kind_mismatch"
      ; "expected", `String (file_kind_to_string expected)
      ; "actual", `String (file_kind_to_string actual)
      ]
  | Core.Record_permissions_mismatch { expected; actual } ->
    `Assoc
      [ "kind", `String "record_permissions_mismatch"
      ; "expected", `Int expected
      ; "actual", `Int actual
      ]
  | Core.Record_outcome_observation_not_mismatch identity ->
    `Assoc
      [ "kind", `String "record_outcome_observation_not_mismatch"
      ; "identity", core_identity_to_yojson identity
      ]
  | Core.Record_field_invalid { field; value } ->
    `Assoc
      [ "kind", `String "record_field_invalid"
      ; "field", `String field
      ; "value", value
      ]
;;

let corrupt_validation_error_to_yojson error =
  let payload =
    match error.payload with
    | None -> `Null
    | Some { canonical_json_byte_count; canonical_json_sha256 } ->
      `Assoc
        [ "canonical_json_byte_count", `Int canonical_json_byte_count
        ; "canonical_json_sha256", `String canonical_json_sha256
        ]
  in
  `Assoc
    [ ( "kind"
      , `String (corrupt_validation_error_kind_to_string error.kind) )
    ; "payload", payload
    ]
;;

let core_subject_to_yojson = function
  | Core.Registry_root -> `Assoc [ "kind", `String "registry_root" ]
  | Core.Recovery_root -> `Assoc [ "kind", `String "recovery_root" ]
  | Core.Lanes_root -> `Assoc [ "kind", `String "lanes_root" ]
  | Core.Staging_root -> `Assoc [ "kind", `String "staging_root" ]
  | Core.Staged_lane owner ->
    `Assoc
      [ "kind", `String "staged_lane"
      ; "owner", `String (Core.owner_to_string owner)
      ]
  | Core.Lane_root owner ->
    `Assoc
      [ "kind", `String "lane_root"
      ; "owner", `String (Core.owner_to_string owner)
      ]
  | Core.Lane_entry (owner, name) ->
    `Assoc
      [ "kind", `String "lane_entry"
      ; "owner", `String (Core.owner_to_string owner)
      ; "name", `String name
      ]
  | Core.Area (area, owner) ->
    `Assoc
      [ "kind", `String "area"
      ; "area", `String (core_record_area_to_string area)
      ; "owner", `String (Core.owner_to_string owner)
      ]
  | Core.Record (area, owner, operation_id) ->
    `Assoc
      [ "kind", `String "record"
      ; "area", `String (core_record_area_to_string area)
      ; "owner", `String (Core.owner_to_string owner)
      ; "operation_id", `String (Core.operation_id_to_string operation_id)
      ]
;;

let core_failure_cause_to_yojson = function
  | Core.Validation_failed error ->
    `Assoc
      [ "kind", `String "validation_failed"
      ; "error", core_validation_error_to_yojson error
      ]
  | Core.Io_failed { exception_; backtrace } ->
    `Assoc
      [ "kind", `String "io_failed"
      ; "exception", exception_to_yojson exception_ backtrace
      ]
  | Core.Write_failed { exception_; backtrace; bytes_written } ->
    `Assoc
      [ "kind", `String "write_failed"
      ; "exception", exception_to_yojson exception_ backtrace
      ; "bytes_written", `Int bytes_written
      ]
  | Core.Unexpected_resource_kind kind ->
    `Assoc
      [ "kind", `String "unexpected_resource_kind"
      ]
  | Core.Resource_identity_changed { expected; actual } ->
    `Assoc
      [ "kind", `String "resource_identity_changed"
      ; "expected", core_identity_to_yojson expected
      ; "actual", core_identity_to_yojson actual
      ]
  | Core.Posix_descriptor_unavailable ->
    `Assoc [ "kind", `String "posix_descriptor_unavailable" ]
  | Core.Existing_record_does_not_match ->
    `Assoc [ "kind", `String "existing_record_does_not_match" ]
  | Core.Created_record_identity_unavailable ->
    `Assoc [ "kind", `String "created_record_identity_unavailable" ]
  | Core.Missing_record -> `Assoc [ "kind", `String "missing_record" ]
;;

let core_failure_to_yojson (failure : Core.failure) =
  `Assoc
    [ "operation", `String (Core.operation_to_string failure.operation)
    ; "subject", core_subject_to_yojson failure.subject
    ; "cause", core_failure_cause_to_yojson failure.cause
    ]
;;

let core_transition_error_to_yojson (error : Core.transition_error) =
  `Assoc
    [ "store_effect", core_transition_effect_to_yojson error.store_effect
    ; "failure", core_failure_to_yojson error.failure
    ; ( "cleanup_failures"
      , `List (List.map core_failure_to_yojson error.cleanup_failures) )
    ]
;;

let release_scope_to_yojson = function
  | Owner_store_scope -> `Assoc [ "kind", `String "owner_store" ]
  | Record_scope { source_state; operation_id } ->
    `Assoc
      [ "kind", `String "record"
      ; "source_state", `String (source_state_to_string source_state)
      ; "operation_id", `String operation_id
      ]
;;

let cleanup_failure_to_yojson = function
  | Core_cleanup_failure failure ->
    `Assoc
      [ "kind", `String "core_cleanup_failure"
      ; "failure", core_failure_to_yojson failure
      ]
  | Scope_release_failure { scope; exception_; backtrace } ->
    `Assoc
      [ "kind", `String "scope_release_failure"
      ; "scope", release_scope_to_yojson scope
      ; "exception", exception_to_yojson exception_ backtrace
      ]
;;

let observation_subject_to_yojson = function
  | Allowed_root path ->
    `Assoc [ "kind", `String "allowed_root"; "path", `String path ]
  | Parent_component { index; component } ->
    `Assoc
      [ "kind", `String "parent_component"
      ; "index", `Int index
      ; "component", `String component
      ]
  | Stage_leaf name ->
    `Assoc [ "kind", `String "stage_leaf"; "name", `String name ]
  | Target_leaf name ->
    `Assoc [ "kind", `String "target_leaf"; "name", `String name ]
;;

let observation_cause_to_yojson = function
  | Observation_io_failed { exception_; backtrace } ->
    `Assoc
      [ "kind", `String "io_failed"
      ; "exception", exception_to_yojson exception_ backtrace
      ]
  | Observation_identity_invalid error ->
    `Assoc
      [ "kind", `String "identity_invalid"
      ; "error", core_validation_error_to_yojson error
      ]
  | Opened_resource_kind_changed { observed; opened } ->
    `Assoc
      [ "kind", `String "opened_resource_kind_changed"
      ; "observed", `String (file_kind_to_string observed)
      ; "opened", `String (file_kind_to_string opened)
      ]
  | Opened_resource_identity_changed { observed; opened } ->
    `Assoc
      [ "kind", `String "opened_resource_identity_changed"
      ; "observed", identity_to_yojson observed
      ; "opened", identity_to_yojson opened
      ]
;;

let observation_failure_to_yojson failure =
  `Assoc
    [ "subject", observation_subject_to_yojson failure.subject
    ; "cause", observation_cause_to_yojson failure.cause
    ]
;;

let row_to_yojson = function
  | Unexpected_lane_entry { name; kind } ->
    `Assoc
      [ "kind", `String "unexpected_lane_entry"
      ; "name", `String name
      ]
  | Missing_lane_entry { name } ->
    `Assoc [ "kind", `String "missing_lane_entry"; "name", `String name ]
  | Lane_entry_unavailable { name; error } ->
    `Assoc
      [ "kind", `String "lane_entry_unavailable"
      ; "name", `String name
      ; "error", core_transition_error_to_yojson error
      ]
  | Area_inventory_unavailable { area; error } ->
    `Assoc
      [ "kind", `String "area_inventory_unavailable"
      ; "area", `String (record_area_to_string area)
      ; "error", core_transition_error_to_yojson error
      ]
  | Source_transition_capabilities_unavailable
      { source_state; operation_id; area_failures } ->
    `Assoc
      [ "kind", `String "source_transition_capabilities_unavailable"
      ; "source_state", `String (source_state_to_string source_state)
      ; "operation_id", `String operation_id
      ; ( "area_failures"
        , `List
            (List.map
               (fun (area, error) ->
                  `Assoc
                    [ "area", `String (record_area_to_string area)
                    ; "error", core_transition_error_to_yojson error
                    ])
               area_failures) )
      ]
  | Prepared_reconciled { operation_id; outcome } ->
    `Assoc
      [ "kind", `String "prepared_reconciled"
      ; "operation_id", `String operation_id
      ; "outcome", prepared_outcome_to_yojson outcome
      ]
  | Bound_reconciled { operation_id; outcome } ->
    `Assoc
      [ "kind", `String "bound_reconciled"
      ; "operation_id", `String operation_id
      ; "outcome", bound_outcome_to_yojson outcome
      ]
  | Existing_forensic_record { operation_id; source_state } ->
    `Assoc
      [ "kind", `String "existing_forensic_record"
      ; "operation_id", `String operation_id
      ; "source_state", `String (source_state_to_string source_state)
      ]
  | Conflicting_source_records { operation_id; areas } ->
    `Assoc
      [ "kind", `String "conflicting_source_records"
      ; "operation_id", `String operation_id
      ; ( "areas"
        , `List
            (List.map
               (fun area -> `String (record_area_to_string area))
               areas) )
      ]
  | Invalid_record_name { area; name } ->
    `Assoc
      [ "kind", `String "invalid_record_name"
      ; "area", `String (record_area_to_string area)
      ; "name", `String name
      ]
  | Unexpected_record_kind { area; operation_id; kind } ->
    `Assoc
      [ "kind", `String "unexpected_record_kind"
      ; "area", `String (record_area_to_string area)
      ; "operation_id", `String operation_id
      ]
  | Missing_record_entry { area; operation_id } ->
    `Assoc
      [ "kind", `String "missing_record_entry"
      ; "area", `String (record_area_to_string area)
      ; "operation_id", `String operation_id
      ]
  | Record_entry_unavailable { area; operation_id; error } ->
    `Assoc
      [ "kind", `String "record_entry_unavailable"
      ; "area", `String (record_area_to_string area)
      ; "operation_id", `String operation_id
      ; "error", core_transition_error_to_yojson error
      ]
  | Corrupt_record_preserved
      { area
      ; operation_id
      ; raw_byte_count
      ; raw_sha256
      ; validation_error
      } ->
    `Assoc
      [ "kind", `String "corrupt_record_preserved"
      ; "area", `String (record_area_to_string area)
      ; "operation_id", `String operation_id
      ; "raw_byte_count", `Int raw_byte_count
      ; "raw_sha256", `String raw_sha256
      ; "validation_error", corrupt_validation_error_to_yojson validation_error
      ]
  | Record_observation_failed
      { source_state; operation_id; failure } ->
    `Assoc
      [ "kind", `String "record_observation_failed"
      ; "source_state", `String (source_state_to_string source_state)
      ; "operation_id", `String operation_id
      ; "failure", observation_failure_to_yojson failure
      ]
  | Record_transition_failed { source_state; operation_id; error } ->
    `Assoc
      [ "kind", `String "record_transition_failed"
      ; "source_state", `String (source_state_to_string source_state)
      ; "operation_id", `String operation_id
      ; "error", core_transition_error_to_yojson error
      ]
  | Record_scope_release_failed { source_state; operation_id; failure } ->
    `Assoc
      [ "kind", `String "record_scope_release_failed"
      ; "source_state", `String (source_state_to_string source_state)
      ; "operation_id", `String operation_id
      ; "failure", cleanup_failure_to_yojson failure
      ]
  | Owner_store_release_failed failure ->
    `Assoc
      [ "kind", `String "owner_store_release_failed"
      ; "failure", cleanup_failure_to_yojson failure
      ]
  | Owner_store_unavailable error ->
    `Assoc
      [ "kind", `String "owner_store_unavailable"
      ; "error", core_transition_error_to_yojson error
      ]
  | Owner_inventory_unavailable error ->
    `Assoc
      [ "kind", `String "owner_inventory_unavailable"
      ; "error", core_transition_error_to_yojson error
      ]
;;

let report_to_yojson report =
  `Assoc
    [ "owner", `String report.owner
    ; "ready", `Bool (report_is_ready report)
    ; "rows", `List (List.map row_to_yojson report.rows)
    ]
;;
