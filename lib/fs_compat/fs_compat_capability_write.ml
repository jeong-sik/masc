open Fs_compat_internal

let open_atomic_temp_file ~temp_dir () =
  Atomic_replace.open_atomic_temp_file ~temp_dir ()
;;

let is_capability_leaf = Capability_leaf.is_valid

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

let directory_payload = Atomic_write.directory_payload
let directory_payload_error_to_string = Atomic_write.directory_payload_error_to_string

module Publication_recovery = struct
  include Publication_recovery_access

  let directory_leaf = Capability_recovery_store_model.recovery_directory_leaf

  type lane_open_error_category =
    | Invalid_owner_category
    | Reconciliation_blocked_category
    | Store_failed_category

  let lane_open_error_category = function
    | Invalid_owner _ -> Invalid_owner_category
    | Reconciliation_blocked _ -> Reconciliation_blocked_category
    | Store_failed _ -> Store_failed_category
  ;;

  module Core = Capability_recovery_obligation

  let safe_exception = function
    | Unix.Unix_error (error, _, _) -> "os=" ^ Unix.error_message error
    | Eio.Io (Eio.Fs.E error, _) ->
      (match error with
       | Eio.Fs.Permission_denied _ -> "permission_denied"
       | Eio.Fs.Not_found _ -> "not_found"
       | Eio.Fs.Already_exists _ -> "already_exists"
       | Eio.Fs.File_too_large -> "file_too_large"
       | Eio.Fs.Not_native _ -> "not_native")
    | Eio.Io _ -> "io_error"
    | Sys_error _ -> "system_io_error"
    | _ -> "other_error"
  ;;

  let safe_failure (failure : Core.failure) =
    let cause = match failure.cause with
      | Validation_failed _ -> "invalid_record_or_input"
      | Io_failed {exception_; _} | Write_failed {exception_; _} -> safe_exception exception_
      | Unexpected_resource_kind _ -> "unexpected_resource_kind"
      | Resource_identity_changed _ -> "identity_changed"
      | Posix_descriptor_unavailable -> "descriptor_unavailable"
      | Existing_record_does_not_match -> "record_mismatch"
      | Created_record_identity_unavailable -> "identity_unavailable"
      | Missing_record -> "record_missing" in
    Printf.sprintf "stage=%s cause=%s" (Core.operation_to_string failure.operation) cause
  ;;

  let safe_registry_error (error : registry_error) =
    Printf.sprintf "%s cleanup_failures=%d" (safe_failure error.failure)
      (List.length error.cleanup_failures)
  ;;

  let safe_lane_open_error = function
    | Invalid_owner _ -> "invalid_owner"
    | Reconciliation_blocked _ -> "reconciliation_blocked"
    | Store_failed error -> "store_failed " ^ safe_registry_error error
  ;;

  let safe_lane_release_failure (error : lane_release_failure) =
    safe_failure error.failure
  ;;
end

let capability_publication_target = Atomic_write.capability_publication_target

let capability_publication_target_error_to_string =
  Atomic_write.capability_publication_target_error_to_string
;;

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

let capability_recovery_phase_to_string =
  Atomic_write.capability_recovery_phase_to_string
;;

let capability_recovery_effect_to_string =
  Atomic_write.capability_recovery_effect_to_string
;;

let capability_recovery_failure_phase =
  Atomic_write.capability_recovery_failure_phase
;;

let capability_recovery_failure_effect =
  Atomic_write.capability_recovery_failure_effect
;;

let capability_recovery_failure_to_string =
  Atomic_write.capability_recovery_failure_to_string
;;

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

exception Capability_write_cancelled = Atomic_write.Capability_write_cancelled

let replace_capability_file = Atomic_write.replace_capability_file

let create_capability_file_exclusive =
  Atomic_write.create_capability_file_exclusive
;;

let create_capability_directory_exclusive =
  Atomic_write.create_capability_directory_exclusive
;;

let capability_write_error_to_string = Atomic_write.capability_write_error_to_string

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

let create_file_failure_target_effect = function
  | Target_rejected _ | Registry_failed _ | Lane_failed _ -> None
  | Publication_failed error -> Some error.target_effect
  | Lane_release_failed { value = Ok (); _ } -> Some Target_created
  | Lane_release_failed { value = Error error; _ } -> Some error.target_effect

let create_file_error_target_effect = function
  | Create_failed failure -> create_file_failure_target_effect failure
  | Boundary_failed { observed = Some (Ok ()); _ } -> Some Target_created
  | Boundary_failed { observed = Some (Error failure); _ } ->
      create_file_failure_target_effect failure
  | Boundary_failed { observed = None; _ } -> None

let create_file_failure_to_string = function
  | Target_rejected error -> capability_publication_target_error_to_string error
  | Registry_failed error -> Publication_recovery.registry_error_to_string error
  | Lane_failed error -> Publication_recovery.lane_open_error_to_string error
  | Publication_failed error -> capability_write_error_to_string error
  | Lane_release_failed { value; release_failure } ->
      let publication = match value with
        | Ok () -> "target_created; publication returned successfully"
        | Error error -> capability_write_error_to_string error
      in
      publication ^ "; " ^ Publication_recovery.lane_release_failure_to_string release_failure

let create_file_error_to_string = function
  | Create_failed failure -> create_file_failure_to_string failure
  | Boundary_failed { observed; failure = (exception_, _) } ->
      let prior = match observed with
        | None -> "target effect unobserved"
        | Some (Ok ()) -> "target_created; publication returned successfully"
        | Some (Error failure) -> create_file_failure_to_string failure
      in
      prior ^ "; path boundary failed: " ^ Format.asprintf "%a" Eio.Exn.pp exception_

type create_file_cancellation = Create_file_cancellation of exn

let rec contains_create_file_cancellation = function
  | Eio.Cancel.Cancelled _ | Capability_write_cancelled _ -> true
  | Publication_recovery.Cleanup_failed { body; cancellation; cleanup = (cleanup, _) } ->
      Option.is_some cancellation
      || Option.fold ~none:false ~some:(fun (exception_, _) ->
           contains_create_file_cancellation exception_) body
      || contains_create_file_cancellation cleanup
  | Publication_recovery.Body_failed_during_cancellation _
  | Publication_recovery.Reconciliation_cancellation_terminalization_failed _ -> true
  | _ -> false

let create_file_cancellation exception_ =
  if contains_create_file_cancellation exception_
  then Some (Create_file_cancellation exception_)
  else None

let combine_create_file_effect left right =
  match left, right with
  | None, None -> None
  | Some observed_effect, None | None, Some observed_effect -> Some observed_effect
  | Some left, Some right ->
      Some (if left = right then left else Target_state_unknown)

let rec create_file_exception_effect = function
  | Eio.Cancel.Cancelled reason -> create_file_exception_effect reason
  | Capability_write_cancelled (_, evidence) -> Some evidence.target_effect
  | Publication_recovery.Cleanup_failed { body; cancellation; cleanup = (cleanup, _) } ->
      let observed_effect = function
        | None -> None
        | Some (exception_, _) -> create_file_exception_effect exception_
      in
      combine_create_file_effect (observed_effect body)
        (combine_create_file_effect (observed_effect cancellation) (create_file_exception_effect cleanup))
  | Publication_recovery.Body_failed_during_cancellation
      { body = (body, _); cancellation = (cancellation, _) } ->
      combine_create_file_effect (create_file_exception_effect body)
        (create_file_exception_effect cancellation)
  | Publication_recovery.Reconciliation_cancellation_terminalization_failed
      { cancellation = (cancellation, _); terminalization = (terminalization, _) } ->
      combine_create_file_effect (create_file_exception_effect cancellation)
        (create_file_exception_effect terminalization)
  | _ -> None

let create_file_cancellation_effect (Create_file_cancellation exception_) =
  create_file_exception_effect exception_

let create_file_primary_failure_to_string = function
  | Write_primary_failure failure -> Atomic_write.capability_write_failure_to_string failure
  | Recovery_primary_failure failure -> Atomic_write.capability_recovery_failure_to_string failure
  | Recovery_access_primary_failure Recovery_access_not_available ->
      "publication recovery access is not available for this Keeper lane"

let create_file_cleanup_failure_to_string = function
  | Write_cleanup_failure failure -> Atomic_write.capability_write_failure_to_string failure
  | Recovery_cleanup_failure failure -> Atomic_write.capability_recovery_failure_to_string failure

let rec create_file_exception_to_string = function
  | Eio.Cancel.Cancelled reason -> "cancelled: " ^ create_file_exception_to_string reason
  | Capability_write_cancelled (reason, evidence) ->
      let details =
        Option.to_list (Option.map create_file_primary_failure_to_string evidence.interrupted_primary_failure)
        @ Option.to_list (Option.map Atomic_write.capability_recovery_failure_to_string evidence.interrupted_recovery)
        @ List.map create_file_cleanup_failure_to_string evidence.cleanup_failures
      in
      Printf.sprintf "operation=%s target_effect=%s reason=%s%s"
        (Atomic_write.capability_write_operation_to_string evidence.operation)
        (Atomic_write.capability_write_target_effect_to_string evidence.target_effect)
        (create_file_exception_to_string reason)
        (match details with [] -> "" | _ :: _ -> "; " ^ String.concat "; " details)
  | Publication_recovery.Cleanup_failed { body; cancellation; cleanup = (cleanup, _) } ->
      let describe label = Option.map (fun (exception_, _) ->
        label ^ create_file_exception_to_string exception_) in
      String.concat "; "
        (Option.to_list (describe "body: " body)
         @ Option.to_list (describe "cancellation: " cancellation)
         @ ["cleanup: " ^ create_file_exception_to_string cleanup])
  | Publication_recovery.Body_failed_during_cancellation
      { body = (body, _); cancellation = (cancellation, _) } ->
      "body: " ^ create_file_exception_to_string body
      ^ "; cancellation: " ^ create_file_exception_to_string cancellation
  | Publication_recovery.Reconciliation_cancellation_terminalization_failed
      { cancellation = (cancellation, _); terminalization = (terminalization, _) } ->
      "cancellation: " ^ create_file_exception_to_string cancellation
      ^ "; terminalization: " ^ create_file_exception_to_string terminalization
  | exception_ -> Format.asprintf "%a" Eio.Exn.pp exception_

let create_file_cancellation_to_string (Create_file_cancellation exception_) =
  create_file_exception_to_string exception_

let rec create_file_fatal_exception = function
  | Out_of_memory | Stack_overflow | Sys.Break -> true
  | Publication_recovery.Cleanup_failed { body; cleanup = (cleanup, _); _ } ->
      Option.fold ~none:false ~some:(fun (exception_, _) ->
        create_file_fatal_exception exception_) body
      || create_file_fatal_exception cleanup
  | Publication_recovery.Body_failed_during_cancellation { body = (body, _); _ } ->
      create_file_fatal_exception body
  | _ -> false

let create_file_exclusive ~fs ~owner ~path ~permissions content =
  let observed = ref None in
  let remember result = observed := Some result; result in
  let perform () =
    let path =
      if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path
      else path
    in
    Eio.Path.with_open_dir Eio.Path.(fs / Filename.dirname path) (fun parent ->
      let root = Eio.Path.stat ~follow:true parent in
      match capability_publication_target
        ~allowed_root_path:(Filename.dirname path)
        ~allowed_root_device:root.dev ~allowed_root_inode:root.ino
        ~parent_components:[] ~target_leaf:(Filename.basename path) ~permissions
      with
      | Error error -> remember (Error (Target_rejected error))
      | Ok target ->
        Eio.Switch.run @@ fun sw ->
        match Publication_recovery.open_registry ~sw ~fs ~registry_root:parent with
        | Error error -> remember (Error (Registry_failed error))
        | Ok registry ->
          let result = Publication_recovery.with_lane ~registry ~owner (fun recovery ->
            let result = create_capability_file_exclusive ~recovery ~parent ~target content in
            ignore (remember (Result.map_error (fun error -> Publication_failed error) result));
            result)
          in
          remember (match result with
            | Error error -> Error (Lane_failed error)
            | Ok (Publication_recovery.Lane_released result) ->
                Result.map_error (fun error -> Publication_failed error) result
            | Ok (Publication_recovery.Lane_release_failed { value; release_failure }) ->
                Error (Lane_release_failed { value; release_failure })))
  in
  let boundary exception_ =
    let failure = exception_, Printexc.get_raw_backtrace () in
    if contains_create_file_cancellation exception_ || create_file_fatal_exception exception_
    then Printexc.raise_with_backtrace exception_ (snd failure)
    else Error (Boundary_failed { observed = !observed; failure })
  in
  match perform () with
  | result -> Result.map_error (fun failure -> Create_failed failure) result
  | exception ((Eio.Io _ | Sys_error _ | Unix.Unix_error _) as exception_) -> boundary exception_
  | exception (Publication_recovery.Cleanup_failed { cancellation = None; _ } as exception_) ->
      boundary exception_
;;

let capability_write_operation_to_string =
  Atomic_write.capability_write_operation_to_string
;;

let capability_write_stage_to_string = Atomic_write.capability_write_stage_to_string

let capability_write_target_effect_to_string =
  Atomic_write.capability_write_target_effect_to_string
;;

let capability_write_cause_to_string = Atomic_write.capability_write_cause_to_string
let capability_write_failure_to_string = Atomic_write.capability_write_failure_to_string
let sync_directory_capability = Atomic_write.sync_directory_capability

let is_atomic_orphan_name = Atomic_temp_name.is_name
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

let atomic_orphan_cleanup_failure_to_string =
  Atomic_orphan_cleanup.atomic_orphan_cleanup_failure_to_string
;;

let cleanup_atomic_orphans ~ownership_root ~base_path () =
  Atomic_orphan_cleanup.cleanup_atomic_orphans ~ownership_root ~base_path ()
;;
