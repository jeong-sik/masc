(** Text form of a publication recovery reconciliation report: one name per
    row constructor with its fields, and one line per report that joins the
    owner, the readiness and the rows.

    This module is private to [fs_compat_internal] and has no interface file.
    [Capability_recovery_reconciler] includes it. *)

open Capability_recovery_reconciler_model

let record_area_to_string = function
  | Active -> "active"
  | Owned -> "owned"
  | Forensic -> "forensic"
;;

let source_state_to_string = function
  | Prepared -> "prepared"
  | Bound -> "bound"
;;

let corrupt_validation_error_kind_to_string = function
  | Corrupt_invalid_owner -> "invalid_owner"
  | Corrupt_invalid_operation_id -> "invalid_operation_id"
  | Corrupt_invalid_identity -> "invalid_identity"
  | Corrupt_invalid_allowed_root_path -> "invalid_allowed_root_path"
  | Corrupt_empty_parent_path_identity_mismatch ->
    "empty_parent_path_identity_mismatch"
  | Corrupt_invalid_parent_component -> "invalid_parent_component"
  | Corrupt_invalid_target_leaf -> "invalid_target_leaf"
  | Corrupt_invalid_permissions -> "invalid_permissions"
  | Corrupt_invalid_record_json -> "invalid_record_json"
  | Corrupt_invalid_record_shape -> "invalid_record_shape"
  | Corrupt_unsupported_record_version -> "unsupported_record_version"
  | Corrupt_record_state_mismatch -> "record_state_mismatch"
  | Corrupt_record_owner_mismatch -> "record_owner_mismatch"
  | Corrupt_record_operation_id_mismatch ->
    "record_operation_id_mismatch"
  | Corrupt_record_stage_leaf_mismatch -> "record_stage_leaf_mismatch"
  | Corrupt_record_identity_mismatch -> "record_identity_mismatch"
  | Corrupt_record_kind_mismatch -> "record_kind_mismatch"
  | Corrupt_record_permissions_mismatch -> "record_permissions_mismatch"
  | Corrupt_record_outcome_observation_not_mismatch ->
    "record_outcome_observation_not_mismatch"
  | Corrupt_record_field_invalid -> "record_field_invalid"
;;

let digest_evidence_to_string = function
  | None -> "no_payload"
  | Some { canonical_json_byte_count; canonical_json_sha256 } ->
    Printf.sprintf
      "payload(canonical_json_bytes=%d,sha256=%s)"
      canonical_json_byte_count
      canonical_json_sha256
;;

let corrupt_validation_error_to_string error =
  Printf.sprintf
    "%s,%s"
    (corrupt_validation_error_kind_to_string error.kind)
    (digest_evidence_to_string error.payload)
;;

let release_scope_to_string = function
  | Owner_store_scope -> "owner_store"
  | Record_scope { source_state; operation_id } ->
    Printf.sprintf
      "record(%s,%s)"
      (source_state_to_string source_state)
      operation_id
;;

let cleanup_failure_to_string = function
  | Core_cleanup_failure failure ->
    Printf.sprintf "core(%s)" (Core.failure_to_string failure)
  | Scope_release_failure { scope; exception_; _ } ->
    Printf.sprintf
      "scope_release(%s,%s)"
      (release_scope_to_string scope)
      (Printexc.to_string exception_)
;;

let observation_subject_to_string = function
  | Allowed_root path -> Printf.sprintf "allowed_root(%S)" path
  | Parent_component { index; component } ->
    Printf.sprintf "parent_component(index=%d,name=%S)" index component
  | Stage_leaf name -> Printf.sprintf "stage_leaf(%S)" name
  | Target_leaf name -> Printf.sprintf "target_leaf(%S)" name
;;

let row_to_string = function
  | Unexpected_lane_entry { name; kind } ->
    Format.asprintf
      "unexpected_lane_entry(%S,%a)"
      name
      Eio.File.Stat.pp_kind
      kind
  | Missing_lane_entry { name } ->
    Printf.sprintf "missing_lane_entry(%S)" name
  | Lane_entry_unavailable { name; error } ->
    Printf.sprintf
      "lane_entry_unavailable(%S,%s)"
      name
      (Core.transition_error_to_string error)
  | Area_inventory_unavailable { area; error } ->
    Printf.sprintf
      "area_inventory_unavailable(%s,%s)"
      (record_area_to_string area)
      (Core.transition_error_to_string error)
  | Source_transition_capabilities_unavailable
      { source_state; operation_id; area_failures } ->
    let areas =
      area_failures
      |> List.map (fun (area, _) -> record_area_to_string area)
      |> String.concat ","
    in
    Printf.sprintf
      "source_transition_capabilities_unavailable(%s,%s,[%s])"
      (source_state_to_string source_state)
      operation_id
      areas
  | Prepared_reconciled { operation_id; _ } ->
    Printf.sprintf "prepared_reconciled(%s)" operation_id
  | Bound_reconciled { operation_id; _ } ->
    Printf.sprintf "bound_reconciled(%s)" operation_id
  | Existing_forensic_record { operation_id; source_state } ->
    Printf.sprintf
      "existing_forensic(%s,%s)"
      operation_id
      (source_state_to_string source_state)
  | Conflicting_source_records { operation_id; areas } ->
    Printf.sprintf
      "conflicting_sources(%s,[%s])"
      operation_id
      (String.concat "," (List.map record_area_to_string areas))
  | Invalid_record_name { area; name } ->
    Printf.sprintf
      "invalid_record_name(%s,%S)"
      (record_area_to_string area)
      name
  | Unexpected_record_kind { area; operation_id; kind } ->
    Format.asprintf
      "unexpected_record_kind(%s,%s,%a)"
      (record_area_to_string area)
      operation_id
      Eio.File.Stat.pp_kind
      kind
  | Missing_record_entry { area; operation_id } ->
    Printf.sprintf
      "missing_record(%s,%s)"
      (record_area_to_string area)
      operation_id
  | Record_entry_unavailable { area; operation_id; error } ->
    Printf.sprintf
      "record_unavailable(%s,%s,%s)"
      (record_area_to_string area)
      operation_id
      (Core.transition_error_to_string error)
  | Corrupt_record_preserved
      { area; operation_id; validation_error; _ } ->
    Printf.sprintf
      "corrupt_record(%s,%s,%s)"
      (record_area_to_string area)
      operation_id
      (corrupt_validation_error_to_string validation_error)
  | Record_observation_failed
      { source_state; operation_id; failure } ->
    Printf.sprintf
      "observation_failed(%s,%s,%s)"
      (source_state_to_string source_state)
      operation_id
      (observation_subject_to_string failure.subject)
  | Record_transition_failed { source_state; operation_id; error } ->
    Printf.sprintf
      "transition_failed(%s,%s,%s)"
      (source_state_to_string source_state)
      operation_id
      (Core.transition_error_to_string error)
  | Record_scope_release_failed
      { source_state; operation_id; failure } ->
    Printf.sprintf
      "record_scope_release_failed(%s,%s,%s)"
      (source_state_to_string source_state)
      operation_id
      (cleanup_failure_to_string failure)
  | Owner_store_release_failed failure ->
    Printf.sprintf
      "owner_store_release_failed(%s)"
      (cleanup_failure_to_string failure)
  | Owner_store_unavailable error ->
    Printf.sprintf
      "owner_store_unavailable(%s)"
      (Core.transition_error_to_string error)
  | Owner_inventory_unavailable error ->
    Printf.sprintf
      "owner_inventory_unavailable(%s)"
      (Core.transition_error_to_string error)
;;

let report_to_string report =
  Printf.sprintf
    "owner=%S ready=%b rows=[%s]"
    report.owner
    (report_is_ready report)
    (String.concat "; " (List.map row_to_string report.rows))
;;
