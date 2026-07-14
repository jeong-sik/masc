(* See [atomic_write.mli] for the contract. *)

(* Durable atomic write: tmp → fsync(tmp) → rename → fsync(parent dir).
   Without the fsync pair, a crash between the rename and the kernel's
   dirty-page flush can leave the target truncated or zero-length —
   observed on backlog.json after an abrupt shutdown (2026-04-18). *)
let fsync_path path =
  let fd = Unix.openfile path [ Unix.O_RDONLY ] 0 in
  Stdlib.Fun.protect
    ~finally:(fun () ->
      try Unix.close fd with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Stdlib.Printf.eprintf
          "[fs_compat] fsync_path close failed: %s\n%!"
          (Printexc.to_string exn))
    (fun () ->
      try Unix.fsync fd with
      | Unix.Unix_error ((Unix.EINVAL | Unix.EOPNOTSUPP), _, _) ->
        (* Some filesystems (tmpfs on some kernels) reject fsync. The data
           is still durable to the extent the underlying FS offers. *)
        ())
;;

(* #10205 finding 2: keep the atomic-tmp filename shape in one place
   so the writer ([save_file_atomic]) and the orphan-sweep matcher
   ([is_atomic_orphan_name]) cannot drift independently. A
   prefix/suffix change on one side without the other would cause
   the sweep to either miss live orphans or scoop unrelated tmp
   files. *)
let atomic_tmp_prefix = ".atomic_"
let atomic_tmp_suffix = ".tmp"

let open_atomic_temp_file ~temp_dir () =
  Stdlib.Filename.open_temp_file
    ~temp_dir
    atomic_tmp_prefix
    atomic_tmp_suffix
;;

module Recovery = Capability_recovery_obligation
module Recovery_access = Publication_recovery_access

type atomic_replace_recovery_target_error =
  | Recovery_target_validation_failed of Recovery.validation_error

type atomic_replace_recovery_target =
  { allowed_root_path : string
  ; allowed_root : Recovery.identity
  ; parent_components : string list
  ; target_leaf : string
  ; permissions : Recovery.permissions
  }

type publication_recovery_access = Recovery_access.t
type publication_recovery_registry = Recovery_access.registry
type publication_recovery_registry_error = Recovery.transition_error
type publication_recovery_lane_open_error = Recovery_access.lane_open_error

let open_publication_recovery_registry = Recovery_access.open_registry
let publication_recovery_registry_error_to_string = Recovery.transition_error_to_string
let with_publication_recovery_lane = Recovery_access.with_lane

let publication_recovery_lane_open_error_to_string =
  Recovery_access.lane_open_error_to_string
;;

let atomic_replace_recovery_target_error_to_string = function
  | Recovery_target_validation_failed error ->
    Recovery.validation_error_to_string error
;;

let atomic_replace_recovery_target
      ~allowed_root_path
      ~allowed_root_device
      ~allowed_root_inode
      ~parent_components
      ~target_leaf
      ~permissions
  =
  match
    Recovery.identity ~dev:allowed_root_device ~ino:allowed_root_inode
  with
  | Error error -> Error (Recovery_target_validation_failed error)
  | Ok allowed_root ->
    (match Recovery.permissions_of_int permissions with
     | Error error -> Error (Recovery_target_validation_failed error)
     | Ok permissions ->
       (match
          Recovery.locator
            ~allowed_root_path
            ~allowed_root
            ~parent_components
            ~parent:allowed_root
            ~target_leaf
            ~initial_target:Recovery.Absent
        with
        | Error error -> Error (Recovery_target_validation_failed error)
        | Ok validated ->
          Ok
            { allowed_root_path =
                Recovery.locator_allowed_root_path validated
            ; allowed_root
            ; parent_components =
                Recovery.locator_parent_components validated
            ; target_leaf = Recovery.locator_target_leaf validated
            ; permissions
            }))
;;

type capability_write_operation =
  | Atomic_replace_operation
  | Create_exclusive_operation

type capability_write_stage =
  | Validate_leaf
  | Acquire_mutation_lease
  | Inspect_target_entry
  | Prepare_recovery_obligation
  | Create_staging_directory
  | Inspect_staging_directory
  | Acquire_staging_directory
  | Apply_staging_directory_permissions
  | Verify_staging_directory_identity
  | Preserve_unbound_recovery_obligation
  | Bind_recovery_obligation
  | Create_staging_entry
  | Create_target_entry
  | Inspect_open_resource
  | Write_payload
  | Apply_permissions
  | Sync_payload
  | Close_payload
  | Verify_entry_identity
  | Publish_replace
  | Sync_staging_directory
  | Sync_parent
  | Remove_staging_directory
  | Close_staging_directory
  | Discharge_prepared_recovery_obligation
  | Discharge_bound_recovery_obligation
  | Cleanup_close
  | Cleanup_verify_identity
  | Cleanup_unlink
  | Cleanup_sync_staging_directory
  | Cleanup_verify_staging_directory_identity
  | Cleanup_remove_staging_directory
  | Cleanup_close_staging_directory
  | Cleanup_sync_parent

type capability_write_target_effect =
  | Target_unchanged
  | Target_created
  | Target_created_incomplete
  | Target_replaced
  | Target_state_unknown

type capability_write_operation_failure =
  { exception_ : exn
  ; backtrace : Printexc.raw_backtrace
  }

type capability_write_payload_failure =
  { exception_ : exn
  ; backtrace : Printexc.raw_backtrace
  ; bytes_written : int
  }

type capability_write_cause =
  | Invalid_leaf of string
  | Invalid_recovery_target of atomic_replace_recovery_target_error
  | Mutation_contended
  | Posix_descriptor_unavailable
  | Unexpected_resource_kind of Eio.File.Stat.kind
  | Resource_identity_unavailable
  | Resource_identity_changed
  | Payload_write_failed of capability_write_payload_failure
  | Operation_failed of capability_write_operation_failure

type capability_write_failure =
  { stage : capability_write_stage
  ; cause : capability_write_cause
  }

type capability_recovery_phase =
  | Recovery_validate_owner
  | Recovery_open_registry
  | Recovery_open_store
  | Recovery_prepare
  | Recovery_preserve_unbound
  | Recovery_bind
  | Recovery_discharge_prepared
  | Recovery_discharge_bound

type capability_recovery_removal_transition =
  | Recovery_discharge_active
  | Recovery_discharge_owned
  | Recovery_active_to_owned
  | Recovery_active_to_forensic
  | Recovery_owned_to_forensic

type capability_recovery_effect =
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

type recovery_failure_detail =
  | Recovery_transition_failed of Recovery.transition_error
  | Recovery_validation_failed of Recovery.validation_error
  | Recovery_transition_interrupted of
      { reason : exn
      ; cleanup_failures : Recovery.failure list
      }

type capability_recovery_failure =
  { recovery_phase : capability_recovery_phase
  ; recovery_effect : capability_recovery_effect
  ; recovery_detail : recovery_failure_detail
  }

type capability_recovery_access_failure = Recovery_access_not_available

type capability_write_primary_failure =
  | Write_primary_failure of capability_write_failure
  | Recovery_primary_failure of capability_recovery_failure
  | Recovery_access_primary_failure of capability_recovery_access_failure

type capability_write_cleanup_failure =
  | Write_cleanup_failure of capability_write_failure
  | Recovery_cleanup_failure of capability_recovery_failure

type capability_write_error =
  { operation : capability_write_operation
  ; target_effect : capability_write_target_effect
  ; primary_failure : capability_write_primary_failure
  ; cleanup_failures : capability_write_cleanup_failure list
  }

type capability_directory_sync_error =
  { failure : capability_write_failure
  ; cleanup_failures : capability_write_failure list
  }

type capability_write_cancellation =
  { operation : capability_write_operation
  ; target_effect : capability_write_target_effect
  ; interrupted_primary_failure : capability_write_primary_failure option
  ; interrupted_recovery : capability_recovery_failure option
  ; cleanup_failures : capability_write_cleanup_failure list
  }

exception Capability_write_failed of
  capability_write_failure * capability_write_failure list

exception Capability_write_cancelled of exn * capability_write_cancellation

exception Parent_sync_cleanup_failed_on_cancellation of
  exn * capability_write_failure list

let capability_write_operation_to_string = function
  | Atomic_replace_operation -> "atomic_replace"
  | Create_exclusive_operation -> "create_exclusive"
;;

let capability_write_stage_to_string = function
  | Validate_leaf -> "validate_leaf"
  | Acquire_mutation_lease -> "acquire_mutation_lease"
  | Inspect_target_entry -> "inspect_target_entry"
  | Prepare_recovery_obligation -> "prepare_recovery_obligation"
  | Create_staging_directory -> "create_staging_directory"
  | Inspect_staging_directory -> "inspect_staging_directory"
  | Acquire_staging_directory -> "acquire_staging_directory"
  | Apply_staging_directory_permissions ->
    "apply_staging_directory_permissions"
  | Verify_staging_directory_identity ->
    "verify_staging_directory_identity"
  | Preserve_unbound_recovery_obligation ->
    "preserve_unbound_recovery_obligation"
  | Bind_recovery_obligation -> "bind_recovery_obligation"
  | Create_staging_entry -> "create_staging_entry"
  | Create_target_entry -> "create_target_entry"
  | Inspect_open_resource -> "inspect_open_resource"
  | Write_payload -> "write_payload"
  | Apply_permissions -> "apply_permissions"
  | Sync_payload -> "sync_payload"
  | Close_payload -> "close_payload"
  | Verify_entry_identity -> "verify_entry_identity"
  | Publish_replace -> "publish_replace"
  | Sync_staging_directory -> "sync_staging_directory"
  | Sync_parent -> "sync_parent"
  | Remove_staging_directory -> "remove_staging_directory"
  | Close_staging_directory -> "close_staging_directory"
  | Discharge_prepared_recovery_obligation ->
    "discharge_prepared_recovery_obligation"
  | Discharge_bound_recovery_obligation ->
    "discharge_bound_recovery_obligation"
  | Cleanup_close -> "cleanup_close"
  | Cleanup_verify_identity -> "cleanup_verify_identity"
  | Cleanup_unlink -> "cleanup_unlink"
  | Cleanup_sync_staging_directory -> "cleanup_sync_staging_directory"
  | Cleanup_verify_staging_directory_identity ->
    "cleanup_verify_staging_directory_identity"
  | Cleanup_remove_staging_directory -> "cleanup_remove_staging_directory"
  | Cleanup_close_staging_directory -> "cleanup_close_staging_directory"
  | Cleanup_sync_parent -> "cleanup_sync_parent"
;;

let capability_write_target_effect_to_string = function
  | Target_unchanged -> "target_unchanged"
  | Target_created -> "target_created"
  | Target_created_incomplete -> "target_created_incomplete"
  | Target_replaced -> "target_replaced"
  | Target_state_unknown -> "target_state_unknown"
;;

let capability_write_cause_to_string = function
  | Invalid_leaf leaf -> Printf.sprintf "invalid leaf component: %S" leaf
  | Invalid_recovery_target error ->
    Printf.sprintf
      "invalid recovery target: %s"
      (atomic_replace_recovery_target_error_to_string error)
  | Mutation_contended -> "another cooperative writer owns this entry"
  | Posix_descriptor_unavailable -> "POSIX descriptor unavailable"
  | Unexpected_resource_kind kind ->
    Format.asprintf "unexpected resource kind: %a" Eio.File.Stat.pp_kind kind
  | Resource_identity_unavailable -> "resource identity unavailable"
  | Resource_identity_changed -> "resource identity changed"
  | Payload_write_failed { exception_; bytes_written; _ } ->
    Printf.sprintf
      "payload write failed after %d bytes: %s"
      bytes_written
      (Printexc.to_string exception_)
  | Operation_failed { exception_; _ } -> Printexc.to_string exception_
;;

let capability_write_failure_to_string failure =
  Printf.sprintf
    "stage=%s reason=%s"
    (capability_write_stage_to_string failure.stage)
    (capability_write_cause_to_string failure.cause)
;;

let capability_recovery_phase_to_string = function
  | Recovery_validate_owner -> "validate_owner"
  | Recovery_open_registry -> "open_registry"
  | Recovery_open_store -> "open_store"
  | Recovery_prepare -> "prepare"
  | Recovery_preserve_unbound -> "preserve_unbound"
  | Recovery_bind -> "bind"
  | Recovery_discharge_prepared -> "discharge_prepared"
  | Recovery_discharge_bound -> "discharge_bound"
;;

let capability_recovery_removal_transition_to_string = function
  | Recovery_discharge_active -> "discharge_active"
  | Recovery_discharge_owned -> "discharge_owned"
  | Recovery_active_to_owned -> "active_to_owned"
  | Recovery_active_to_forensic -> "active_to_forensic"
  | Recovery_owned_to_forensic -> "owned_to_forensic"
;;

let capability_recovery_effect_of_core = function
  | Recovery.No_record_change -> Recovery_no_record_change
  | Recovery.Layout_may_be_incomplete -> Recovery_layout_may_be_incomplete
  | Recovery.Layout_ready -> Recovery_layout_ready
  | Recovery.Active_record_state_unknown ->
    Recovery_active_record_state_unknown
  | Recovery.Active_record_durable -> Recovery_active_record_durable
  | Recovery.Active_record_discharged -> Recovery_active_record_discharged
  | Recovery.Owned_record_state_unknown_with_active ->
    Recovery_owned_record_state_unknown_with_active
  | Recovery.Owned_record_durable_with_active ->
    Recovery_owned_record_durable_with_active
  | Recovery.Owned_record_durable -> Recovery_owned_record_durable
  | Recovery.Owned_record_discharged -> Recovery_owned_record_discharged
  | Recovery.Forensic_record_state_unknown_with_source ->
    Recovery_forensic_record_state_unknown_with_source
  | Recovery.Forensic_record_durable_with_source ->
    Recovery_forensic_record_durable_with_source
  | Recovery.Forensic_record_durable -> Recovery_forensic_record_durable
  | Recovery.Source_removal_durability_unknown transition ->
    let transition =
      match transition with
      | Recovery.Discharge_active -> Recovery_discharge_active
      | Recovery.Discharge_owned -> Recovery_discharge_owned
      | Recovery.Active_to_owned -> Recovery_active_to_owned
      | Recovery.Active_to_forensic -> Recovery_active_to_forensic
      | Recovery.Owned_to_forensic -> Recovery_owned_to_forensic
    in
    Recovery_source_removal_durability_unknown transition
;;

let capability_recovery_effect_to_string = function
  | Recovery_no_record_change -> "no_record_change"
  | Recovery_layout_may_be_incomplete -> "layout_may_be_incomplete"
  | Recovery_layout_ready -> "layout_ready"
  | Recovery_active_record_state_unknown -> "active_record_state_unknown"
  | Recovery_active_record_durable -> "active_record_durable"
  | Recovery_active_record_discharged -> "active_record_discharged"
  | Recovery_owned_record_state_unknown_with_active ->
    "owned_record_state_unknown_with_active"
  | Recovery_owned_record_durable_with_active ->
    "owned_record_durable_with_active"
  | Recovery_owned_record_durable -> "owned_record_durable"
  | Recovery_owned_record_discharged -> "owned_record_discharged"
  | Recovery_forensic_record_state_unknown_with_source ->
    "forensic_record_state_unknown_with_source"
  | Recovery_forensic_record_durable_with_source ->
    "forensic_record_durable_with_source"
  | Recovery_forensic_record_durable -> "forensic_record_durable"
  | Recovery_source_removal_durability_unknown transition ->
    Printf.sprintf
      "source_removal_durability_unknown(%s)"
      (capability_recovery_removal_transition_to_string transition)
;;

let capability_recovery_failure_phase failure = failure.recovery_phase
let capability_recovery_failure_effect failure = failure.recovery_effect

let capability_recovery_failure_to_string failure =
  let detail =
    match failure.recovery_detail with
    | Recovery_transition_failed error ->
      Recovery.transition_error_to_string error
    | Recovery_validation_failed error ->
      Recovery.validation_error_to_string error
  | Recovery_transition_interrupted { reason; cleanup_failures } ->
      let cleanup =
        match cleanup_failures with
        | [] -> ""
        | failures ->
          failures
          |> List.map Recovery.failure_to_string
          |> String.concat "; "
          |> Printf.sprintf " cleanup_failures=[%s]"
      in
      Printf.sprintf
        "transition interrupted reason=%s%s"
        (Printexc.to_string reason)
        cleanup
  in
  Printf.sprintf
    "phase=%s effect=%s reason=%s"
    (capability_recovery_phase_to_string failure.recovery_phase)
    (capability_recovery_effect_to_string failure.recovery_effect)
    detail
;;

let recovery_transition_failure recovery_phase error =
  { recovery_phase
  ; recovery_effect = capability_recovery_effect_of_core error.Recovery.store_effect
  ; recovery_detail = Recovery_transition_failed error
  }
;;

let recovery_validation_failure recovery_phase error =
  { recovery_phase
  ; recovery_effect = Recovery_no_record_change
  ; recovery_detail = Recovery_validation_failed error
  }
;;

let recovery_interruption recovery_phase store_effect reason cleanup_failures =
  { recovery_phase
  ; recovery_effect = capability_recovery_effect_of_core store_effect
  ; recovery_detail = Recovery_transition_interrupted { reason; cleanup_failures }
  }
;;

let capability_write_primary_failure_to_string = function
  | Write_primary_failure failure -> capability_write_failure_to_string failure
  | Recovery_primary_failure failure ->
    capability_recovery_failure_to_string failure
  | Recovery_access_primary_failure Recovery_access_not_available ->
    "publication recovery access is not available for this Keeper lane"
;;

let capability_write_cleanup_failure_to_string = function
  | Write_cleanup_failure failure -> capability_write_failure_to_string failure
  | Recovery_cleanup_failure failure ->
    capability_recovery_failure_to_string failure
;;

let capability_write_error_to_string (error : capability_write_error) =
  let cleanup =
    match error.cleanup_failures with
    | [] -> ""
    | failures ->
      failures
      |> List.map capability_write_cleanup_failure_to_string
      |> String.concat "; "
      |> Printf.sprintf " cleanup_failures=[%s]"
  in
  Printf.sprintf
    "operation=%s target_effect=%s failure=(%s)%s"
    (capability_write_operation_to_string error.operation)
    (capability_write_target_effect_to_string error.target_effect)
    (capability_write_primary_failure_to_string error.primary_failure)
    cleanup
;;

let capability_directory_sync_error_to_string
      (error : capability_directory_sync_error)
  =
  let cleanup =
    match error.cleanup_failures with
    | [] -> ""
    | failures ->
      failures
      |> List.map capability_write_failure_to_string
      |> String.concat "; "
      |> Printf.sprintf " cleanup_failures=[%s]"
  in
  Printf.sprintf
    "failure=(%s)%s"
    (capability_write_failure_to_string error.failure)
    cleanup
;;

let operation_failure stage exception_ backtrace =
  { stage; cause = Operation_failed { exception_; backtrace } }
;;

let raise_failure stage cause =
  raise (Capability_write_failed ({ stage; cause }, []))
;;

let run_stage ~before_stage stage f =
  try
    before_stage stage;
    f ()
  with
  | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
  | Capability_write_failed _ as failure -> raise failure
  | exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    raise
      (Capability_write_failed
         (operation_failure stage exception_ backtrace, []))
;;

let capture_cleanup ~before_stage stage f =
  try
    before_stage stage;
    f ();
    []
  with
  | Capability_write_failed (failure, additional) -> failure :: additional
  | exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    [ operation_failure stage exception_ backtrace ]
;;

type resource_identity =
  { dev : int64
  ; ino : int64
  }

let same_resource_identity expected actual =
  Int64.equal expected.dev actual.Eio.File.Stat.dev
  && Int64.equal expected.ino actual.Eio.File.Stat.ino
;;

let identity_of_open_resource ~before_stage ~stage ~expected_kind file =
  let stat = run_stage ~before_stage stage (fun () -> Eio.File.stat file) in
  if stat.kind <> expected_kind
  then raise_failure stage (Unexpected_resource_kind stat.kind)
  else { dev = stat.dev; ino = stat.ino }
;;

let identity_of_open_file ~before_stage file =
  identity_of_open_resource
    ~before_stage
    ~stage:Inspect_open_resource
    ~expected_kind:`Regular_file
    file
;;

let capability_staging_payload_leaf = "payload"
let capability_staging_directory_permissions = 0o700

let validate_leaf ~before_stage leaf =
  run_stage ~before_stage Validate_leaf (fun () ->
    match Capability_leaf.of_string leaf with
    | Some leaf -> leaf
    | None -> raise_failure Validate_leaf (Invalid_leaf leaf))
;;

let set_open_file_permissions ~before_stage file permissions =
  run_stage ~before_stage Apply_permissions (fun () ->
    match Eio_unix.Resource.fd_opt file with
    | None -> raise_failure Apply_permissions Posix_descriptor_unavailable
    | Some fd ->
      Eio_unix.run_in_systhread ~label:"fs-compat-capability-fchmod" (fun () ->
        Eio_unix.Fd.use_exn "fs-compat-capability-fchmod" fd (fun unix_fd ->
          Unix.fchmod unix_fd permissions));
      Eio.Fiber.check ())
;;

let set_open_directory_permissions ~before_stage directory_file =
  run_stage ~before_stage Apply_staging_directory_permissions (fun () ->
    match Eio_unix.Resource.fd_opt directory_file with
    | None ->
      raise_failure
        Apply_staging_directory_permissions
        Posix_descriptor_unavailable
    | Some fd ->
      Eio_unix.run_in_systhread
        ~label:"fs-compat-capability-staging-directory-fchmod"
        (fun () ->
           Eio_unix.Fd.use_exn
             "fs-compat-capability-staging-directory-fchmod"
             fd
             (fun unix_fd ->
                Unix.fchmod unix_fd capability_staging_directory_permissions));
      Eio.Fiber.check ())
;;

let sync_open_directory_file ~before_stage ~stage directory_file =
  run_stage ~before_stage stage (fun () ->
    match Eio_unix.Resource.fd_opt directory_file with
    | None -> raise_failure stage Posix_descriptor_unavailable
    | Some fd ->
      Eio_unix.run_in_systhread
        ~label:"fs-compat-capability-staging-directory-fsync"
        (fun () ->
           Eio_unix.Fd.use_exn
             "fs-compat-capability-staging-directory-fsync"
             fd
             Unix.fsync))
;;

let write_open_file_payload ~before_stage file content =
  run_stage ~before_stage Write_payload (fun () ->
    match
      Blocking_write.write_string
        ~label:"fs-compat-capability-write"
        file
        content
    with
    | Ok () -> Eio.Fiber.check ()
    | Error Blocking_write.Open_file_posix_descriptor_unavailable ->
      raise_failure Write_payload Posix_descriptor_unavailable
    | Error
        (Blocking_write.Open_file_operation_failed
          { exception_; backtrace; bytes_written }) ->
      raise
        (Capability_write_failed
           ( { stage = Write_payload
             ; cause =
                 Payload_write_failed
                   { exception_; backtrace; bytes_written }
             }
           , [] )))
;;

let sync_parent_capability ~before_stage ~stage ~sw parent =
  let directory_file = ref None in
  let close_directory () =
    match !directory_file with
    | None -> []
    | Some file ->
      let failures =
        try
          Eio.Resource.close file;
          []
        with
        | exception_ ->
          let backtrace = Printexc.get_raw_backtrace () in
          [ operation_failure stage exception_ backtrace ]
      in
      directory_file := None;
      failures
  in
  try
    before_stage stage;
    let file = Eio.Path.open_in ~sw Eio.Path.(parent / ".") in
    directory_file := Some file;
    (match Eio_unix.Resource.fd_opt file with
     | None -> raise_failure stage Posix_descriptor_unavailable
     | Some fd ->
       Eio_unix.run_in_systhread ~label:"fs-compat-capability-dir-fsync" (fun () ->
         Eio_unix.Fd.use_exn "fs-compat-capability-dir-fsync" fd Unix.fsync));
    let close_failures = close_directory () in
    (match close_failures with
     | [] -> ()
     | failure :: additional ->
       raise (Capability_write_failed (failure, additional)))
  with
  | Eio.Cancel.Cancelled reason as cancellation ->
    let backtrace = Printexc.get_raw_backtrace () in
    let close_failures = close_directory () in
    if close_failures = []
    then Printexc.raise_with_backtrace cancellation backtrace
    else
      Printexc.raise_with_backtrace
        (Eio.Cancel.Cancelled
           (Parent_sync_cleanup_failed_on_cancellation
              (reason, close_failures)))
        backtrace
  | Capability_write_failed (failure, additional) ->
    let close_failures = close_directory () in
    raise
      (Capability_write_failed
         (failure, additional @ close_failures))
  | exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    let close_failures = close_directory () in
    raise
      (Capability_write_failed
         (operation_failure stage exception_ backtrace, close_failures))
;;

let close_open_resource ~before_stage ~stage open_resource =
  match !open_resource with
  | None -> ()
  | Some resource ->
    run_stage ~before_stage stage (fun () -> Eio.Resource.close resource);
    open_resource := None
;;

let close_open_entry ~before_stage open_file =
  close_open_resource ~before_stage ~stage:Close_payload open_file
;;

let close_open_directory ~before_stage ~stage open_directory =
  match !open_directory with
  | None -> ()
  | Some (directory_resource, _) ->
    run_stage ~before_stage stage (fun () ->
      Eio.Resource.close directory_resource);
    open_directory := None
;;

let verify_path_identity
      ~before_stage
      ~stage
      ~expected_kind
      path
      identity
  =
  run_stage ~before_stage stage (fun () ->
    match !identity with
    | None -> raise_failure stage Resource_identity_unavailable
    | Some expected ->
      let actual = Eio.Path.stat ~follow:false path in
      if
        actual.kind <> expected_kind
        || not (same_resource_identity expected actual)
      then raise_failure stage Resource_identity_changed)
;;

let verify_entry_identity ~before_stage ~stage entry identity =
  verify_path_identity
    ~before_stage
    ~stage
    ~expected_kind:`Regular_file
    entry
    identity
;;

let cleanup_open_resource ~before_stage ~stage open_resource =
  match !open_resource with
  | None -> []
  | Some resource ->
    let failures =
      capture_cleanup ~before_stage stage (fun () ->
        Eio.Resource.close resource)
    in
    open_resource := None;
    failures
;;

let cleanup_open_file ~before_stage open_file =
  cleanup_open_resource ~before_stage ~stage:Cleanup_close open_file
;;

let cleanup_open_directory ~before_stage ~stage open_directory =
  match !open_directory with
  | None -> []
  | Some (directory_resource, _) ->
    let failures =
      capture_cleanup ~before_stage stage (fun () ->
        Eio.Resource.close directory_resource)
    in
    open_directory := None;
    failures
;;

let cleanup_parent_if_dirty ~before_stage ~sw ~parent parent_dirty =
  if not !parent_dirty
  then []
  else
    let failures =
      capture_cleanup ~before_stage Cleanup_sync_parent (fun () ->
        sync_parent_capability
          ~before_stage:(fun _ -> ())
          ~stage:Cleanup_sync_parent
          ~sw
          parent)
    in
    if failures = [] then parent_dirty := false;
    failures
;;

exception Capability_recovery_failed of capability_recovery_failure

exception Capability_recovery_operation_cancelled of
  exn * capability_recovery_failure

let run_recovery_transition
      ~before_stage
      ~stage
      ~recovery_phase
      operation
  =
  run_stage ~before_stage stage (fun () -> ());
  try
    match operation () with
    | Ok value -> value
    | Error error ->
      raise
        (Capability_recovery_failed
           (recovery_transition_failure recovery_phase error))
  with
  | Eio.Cancel.Cancelled reason ->
    let backtrace = Printexc.get_raw_backtrace () in
    let original_reason, store_effect, cleanup_failures =
      match reason with
      | Recovery.Recovery_store_cancelled
          (original_reason, store_effect, cleanup_failures) ->
        original_reason, store_effect, cleanup_failures
      | original_reason -> original_reason, Recovery.No_record_change, []
    in
    let interruption =
      recovery_interruption
        recovery_phase
        store_effect
        original_reason
        cleanup_failures
    in
    Printexc.raise_with_backtrace
      (Eio.Cancel.Cancelled
         (Capability_recovery_operation_cancelled
            (original_reason, interruption)))
      backtrace
;;

let recovery_identity ~stage (identity : resource_identity) =
  match Recovery.identity ~dev:identity.dev ~ino:identity.ino with
  | Ok identity -> identity
  | Error _ -> raise_failure stage Resource_identity_unavailable
;;

let recovery_identity_of_stat ~stage (stat : Eio.File.Stat.t) =
  recovery_identity ~stage { dev = stat.dev; ino = stat.ino }
;;

let observe_target_entry ~before_stage target =
  run_stage ~before_stage Inspect_target_entry (fun () ->
    try
      let stat = Eio.Path.stat ~follow:false target in
      (match stat.kind with
       | `Regular_file | `Symbolic_link ->
         Recovery.Present
           { kind = stat.kind
           ; identity =
               recovery_identity_of_stat ~stage:Inspect_target_entry stat
           }
       | kind ->
         raise_failure Inspect_target_entry (Unexpected_resource_kind kind))
    with
    | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) -> Recovery.Absent)
;;

let write_cleanup_failures failures =
  List.map (fun failure -> Write_cleanup_failure failure) failures
;;

let capture_recovery_cleanup ~recovery_phase operation =
  try
    match operation () with
    | Ok _ -> []
    | Error error ->
      [ Recovery_cleanup_failure
          (recovery_transition_failure recovery_phase error)
      ]
  with
  | Eio.Cancel.Cancelled reason ->
    let original_reason, store_effect, cleanup_failures =
      match reason with
      | Recovery.Recovery_store_cancelled
          (original_reason, store_effect, cleanup_failures) ->
        original_reason, store_effect, cleanup_failures
      | original_reason -> original_reason, Recovery.No_record_change, []
    in
    [ Recovery_cleanup_failure
        (recovery_interruption
           recovery_phase
           store_effect
           original_reason
           cleanup_failures)
    ]
;;

let cleanup_owned_staging_directory
      ~before_stage
      ~sw
      ~parent
      ~staging_path
      ~staging_directory
      ~staging_directory_file
      ~staging_directory_identity
      ~staging_directory_created
      ~staging_directory_removed
      ~payload_entry
      ~payload_file
      ~payload_identity
      ~payload_created
      ~payload_published
      ~parent_dirty
  =
  Eio.Cancel.protect (fun () ->
    let failures = ref (cleanup_open_file ~before_stage payload_file) in
    let add additional = failures := !failures @ additional in
    let payload_absent =
      if (not !payload_created) || !payload_published
      then true
      else (
        let identity_failures =
          capture_cleanup ~before_stage Cleanup_verify_identity (fun () ->
            match !payload_entry, !payload_identity with
            | Some entry, Some expected ->
              let actual = Eio.Path.stat ~follow:false entry in
              if
                actual.kind <> `Regular_file
                || not (same_resource_identity expected actual)
              then raise_failure Cleanup_verify_identity Resource_identity_changed
            | None, _ | _, None ->
              raise_failure
                Cleanup_verify_identity
                Resource_identity_unavailable)
        in
        add identity_failures;
        if identity_failures <> []
        then false
        else (
          let unlink_failures =
            capture_cleanup ~before_stage Cleanup_unlink (fun () ->
              match !payload_entry with
              | None ->
                raise_failure Cleanup_unlink Resource_identity_unavailable
              | Some entry -> Eio.Path.unlink entry)
          in
          add unlink_failures;
          if unlink_failures = [] then payload_created := false;
          unlink_failures = []))
    in
    let staging_sync_failures =
      if (not !staging_directory_created) || !staging_directory_removed
      then []
      else
        capture_cleanup ~before_stage Cleanup_sync_staging_directory (fun () ->
          match !staging_directory_file with
          | None ->
            raise_failure
              Cleanup_sync_staging_directory
              Resource_identity_unavailable
          | Some directory_file ->
            sync_open_directory_file
              ~before_stage:(fun _ -> ())
              ~stage:Cleanup_sync_staging_directory
              directory_file)
    in
    add staging_sync_failures;
    add
      (cleanup_open_resource
         ~before_stage
         ~stage:Cleanup_close_staging_directory
         staging_directory_file);
    let staging_identity_failures =
      if (not !staging_directory_created) || !staging_directory_removed
      then []
      else
        capture_cleanup
          ~before_stage
          Cleanup_verify_staging_directory_identity
          (fun () ->
             match !staging_path, !staging_directory_identity with
             | Some path, Some expected ->
               let actual = Eio.Path.stat ~follow:false path in
               if
                 actual.kind <> `Directory
                 || not (same_resource_identity expected actual)
               then
                 raise_failure
                   Cleanup_verify_staging_directory_identity
                   Resource_identity_changed
             | None, _ | _, None ->
               raise_failure
                 Cleanup_verify_staging_directory_identity
                 Resource_identity_unavailable)
    in
    add staging_identity_failures;
    if
      !staging_directory_created
      && not !staging_directory_removed
      && payload_absent
      && staging_sync_failures = []
      && staging_identity_failures = []
    then (
      let removal_failures =
        capture_cleanup ~before_stage Cleanup_remove_staging_directory (fun () ->
          match !staging_path with
          | None ->
            raise_failure
              Cleanup_remove_staging_directory
              Resource_identity_unavailable
          | Some path -> Eio.Path.rmdir path)
      in
      add removal_failures;
      if removal_failures = []
      then (
        staging_directory_removed := true;
        parent_dirty := true));
    add
      (cleanup_open_directory
         ~before_stage
         ~stage:Cleanup_close_staging_directory
         staging_directory);
    add (cleanup_parent_if_dirty ~before_stage ~sw ~parent parent_dirty);
    !failures)
;;

let replace_capability_file_with
      ~before_stage
      ~recovery
      ~parent
      ~target:recovery_target
      content
  =
  let operation = Atomic_replace_operation in
  let target_effect = ref Target_unchanged in
  let callback_result = ref None in
  try
    let leaf =
      match Capability_leaf.of_string recovery_target.target_leaf with
      | Some leaf -> leaf
      | None ->
        raise_failure
          Validate_leaf
          (Invalid_recovery_target
             (Recovery_target_validation_failed
                (Recovery.Invalid_target_leaf recovery_target.target_leaf)))
    in
    Eio.Switch.run @@ fun sw ->
    let parent_stat, mutation_lease =
      run_stage ~before_stage Acquire_mutation_lease (fun () ->
        let parent_stat = Eio.Path.stat ~follow:true parent in
        if parent_stat.kind <> `Directory
        then
          raise_failure
            Acquire_mutation_lease
            (Unexpected_resource_kind parent_stat.kind);
        match
          Capability_mutation_lease.try_acquire
            ~parent_dev:parent_stat.dev
            ~parent_ino:parent_stat.ino
            ~leaf
        with
        | Some lease -> parent_stat, lease
        | None -> raise_failure Acquire_mutation_lease Mutation_contended)
    in
    Eio.Switch.on_release sw (fun () ->
      Capability_mutation_lease.release mutation_lease);
    let target_path = Eio.Path.(parent / recovery_target.target_leaf) in
    let parent_identity =
      recovery_identity_of_stat ~stage:Inspect_target_entry parent_stat
    in
    let initial_target = observe_target_entry ~before_stage target_path in
    let locator =
      match
        Recovery.locator
          ~allowed_root_path:recovery_target.allowed_root_path
          ~allowed_root:recovery_target.allowed_root
          ~parent_components:recovery_target.parent_components
          ~parent:parent_identity
          ~target_leaf:recovery_target.target_leaf
          ~initial_target
      with
      | Ok locator -> locator
      | Error error ->
        raise_failure
          Inspect_target_entry
          (Invalid_recovery_target
             (Recovery_target_validation_failed error))
    in
    let staging_path = ref None in
    let staging_directory = ref None in
    let staging_directory_file = ref None in
    let staging_directory_identity = ref None in
    let staging_directory_created = ref false in
    let staging_directory_removed = ref false in
    let payload_entry = ref None in
    let open_file = ref None in
    let payload_identity = ref None in
    let payload_created = ref false in
    let published = ref false in
    let parent_dirty = ref false in
    let prepared = ref None in
    let bound = ref None in
    let bind_started = ref false in
    let prepared_discharge_started = ref false in
    let bound_discharge_started = ref false in
    let cleanup () =
      Eio.Cancel.protect (fun () ->
        let write_failures =
          cleanup_owned_staging_directory
            ~before_stage
            ~sw
            ~parent
            ~staging_path
            ~staging_directory
            ~staging_directory_file
            ~staging_directory_identity
            ~staging_directory_created
            ~staging_directory_removed
            ~payload_entry
            ~payload_file:open_file
            ~payload_identity
            ~payload_created
            ~payload_published:published
            ~parent_dirty
        in
        let cleanup_failures = ref (write_cleanup_failures write_failures) in
        let exact_stage_absent_and_synced = ref false in
        if (not !staging_directory_created) && write_failures = []
        then (
          let absent = ref false in
          let inspect_failures =
            capture_cleanup
              ~before_stage
              Cleanup_verify_staging_directory_identity
              (fun () ->
                 match !staging_path with
                 | None -> ()
                 | Some path ->
                   (try ignore (Eio.Path.stat ~follow:false path) with
                    | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) ->
                      absent := true))
          in
          cleanup_failures :=
            !cleanup_failures @ write_cleanup_failures inspect_failures;
          if !absent && inspect_failures = []
          then (
            let sync_failures =
              capture_cleanup ~before_stage Cleanup_sync_parent (fun () ->
                sync_parent_capability
                  ~before_stage:(fun _ -> ())
                  ~stage:Cleanup_sync_parent
                  ~sw
                  parent)
            in
            cleanup_failures :=
              !cleanup_failures @ write_cleanup_failures sync_failures;
            exact_stage_absent_and_synced := sync_failures = []))
        else
          exact_stage_absent_and_synced :=
            !staging_directory_removed
            && not !parent_dirty
            && write_failures = [];
        if !cleanup_failures = []
           && !exact_stage_absent_and_synced
           && !target_effect <> Target_state_unknown
        then (
          match !bound with
          | Some obligation when not !bound_discharge_started ->
            bound_discharge_started := true;
            cleanup_failures :=
              !cleanup_failures
              @ capture_recovery_cleanup
                  ~recovery_phase:Recovery_discharge_bound
                  (fun () -> Recovery.discharge_bound ~store:recovery ~bound:obligation)
          | None when (not !bind_started) && not !prepared_discharge_started ->
            (match !prepared with
             | None -> ()
             | Some obligation ->
               prepared_discharge_started := true;
               cleanup_failures :=
                 !cleanup_failures
                 @ capture_recovery_cleanup
                     ~recovery_phase:Recovery_discharge_prepared
                     (fun () ->
                        Recovery.discharge_prepared
                          ~store:recovery
                          ~prepared:obligation))
          | Some _ | None -> ());
        !cleanup_failures)
    in
    let error primary_failure additional =
      let cleanup_failures = additional @ cleanup () in
      Error
        { operation
        ; target_effect = !target_effect
        ; primary_failure
        ; cleanup_failures
        }
    in
    let result =
      try
       let rec prepare_and_create_stage () =
         let obligation =
           run_recovery_transition
             ~before_stage
             ~stage:Prepare_recovery_obligation
             ~recovery_phase:Recovery_prepare
             (fun () ->
                Recovery.prepare
                  ~store:recovery
                  ~locator
                  ~permissions:recovery_target.permissions)
         in
         prepared := Some obligation;
         let path =
           Eio.Path.
             (parent
              / Recovery.stage_name
                  (Recovery.prepared_operation_id obligation))
         in
         staging_path := Some path;
         let creation =
           Eio.Cancel.protect (fun () ->
             run_stage ~before_stage Create_staging_directory (fun () ->
               try
                 Eio.Path.mkdir
                   ~perm:capability_staging_directory_permissions
                   path;
                 staging_directory_created := true;
                 parent_dirty := true;
                 `Created
               with
               | Eio.Io (Eio.Fs.E (Eio.Fs.Already_exists _), _) ->
                 `Collision))
         in
         match creation with
         | `Created -> obligation, path
         | `Collision ->
           let collision =
             run_stage ~before_stage Inspect_staging_directory (fun () ->
               Eio.Path.stat ~follow:false path)
           in
           let collision_identity =
             recovery_identity_of_stat
               ~stage:Inspect_staging_directory
               collision
           in
           ignore
             (run_recovery_transition
                ~before_stage
                ~stage:Preserve_unbound_recovery_obligation
                ~recovery_phase:Recovery_preserve_unbound
                (fun () ->
                   Recovery.preserve_unbound
                     ~store:recovery
                     ~prepared:obligation
                     ~kind:collision.kind
                     ~stage_identity:collision_identity));
           prepared := None;
           staging_path := None;
           Eio.Fiber.check ();
           prepare_and_create_stage ()
       in
       let obligation, path = prepare_and_create_stage () in
       let created_identity =
         run_stage ~before_stage Inspect_staging_directory (fun () ->
           let lexical = Eio.Path.stat ~follow:false path in
           if lexical.kind <> `Directory
           then
             raise_failure
               Inspect_staging_directory
               (Unexpected_resource_kind lexical.kind);
           { dev = lexical.dev; ino = lexical.ino })
       in
       staging_directory_identity := Some created_identity;
       run_stage ~before_stage Acquire_staging_directory (fun () ->
         let directory = Eio.Path.open_dir ~sw path in
         staging_directory := Some directory;
         let directory_file =
           Eio.Path.open_in ~sw Eio.Path.(directory / ".")
         in
         staging_directory_file := Some directory_file;
         let opened = Eio.File.stat directory_file in
         if opened.kind <> `Directory
         then
           raise_failure
             Acquire_staging_directory
             (Unexpected_resource_kind opened.kind);
         if not (same_resource_identity created_identity opened)
         then raise_failure Acquire_staging_directory Resource_identity_changed);
       (match !staging_directory_file with
        | None ->
          raise_failure
            Apply_staging_directory_permissions
            Resource_identity_unavailable
        | Some directory_file ->
          set_open_directory_permissions ~before_stage directory_file);
       verify_path_identity
         ~before_stage
         ~stage:Verify_staging_directory_identity
         ~expected_kind:`Directory
         path
         staging_directory_identity;
       bind_started := true;
       let bound_obligation =
         run_recovery_transition
           ~before_stage
           ~stage:Bind_recovery_obligation
           ~recovery_phase:Recovery_bind
           (fun () ->
              Recovery.bind
                ~store:recovery
                ~prepared:obligation
                ~stage_identity:
                  (recovery_identity
                     ~stage:Bind_recovery_obligation
                     created_identity))
       in
       bound := Some bound_obligation;
       let entry, file =
         run_stage ~before_stage Create_staging_entry (fun () ->
           match !staging_directory with
           | None ->
             raise_failure
               Create_staging_entry
               Resource_identity_unavailable
           | Some directory ->
             let entry =
               Eio.Path.
                 ( (directory :> Eio.Fs.dir_ty Eio.Path.t)
                   / capability_staging_payload_leaf )
             in
             entry, Eio.Path.open_out ~sw ~create:(`Exclusive 0o600) entry)
       in
       payload_entry := Some entry;
       open_file := Some file;
       payload_created := true;
       payload_identity := Some (identity_of_open_file ~before_stage file);
       write_open_file_payload ~before_stage file content;
       set_open_file_permissions
         ~before_stage
         file
         (Recovery.permissions_to_int recovery_target.permissions);
       run_stage ~before_stage Sync_payload (fun () -> Eio.File.sync file);
       close_open_entry ~before_stage open_file;
       Eio.Fiber.check ();
       Eio.Cancel.protect (fun () ->
         run_stage ~before_stage Publish_replace (fun () -> ());
         verify_entry_identity
           ~before_stage
           ~stage:Verify_entry_identity
           entry
           payload_identity;
         (try Eio.Path.rename entry target_path with
          | Eio.Cancel.Cancelled _ as cancellation ->
            target_effect := Target_state_unknown;
            raise cancellation
          | exception_ ->
            let backtrace = Printexc.get_raw_backtrace () in
            target_effect := Target_state_unknown;
            raise
              (Capability_write_failed
                 (operation_failure Publish_replace exception_ backtrace, [])));
         published := true;
         target_effect := Target_replaced;
         parent_dirty := true;
         (match !staging_directory_file with
          | None ->
            raise_failure
              Sync_staging_directory
              Resource_identity_unavailable
          | Some directory_file ->
            sync_open_directory_file
              ~before_stage
              ~stage:Sync_staging_directory
              directory_file);
         verify_path_identity
           ~before_stage
           ~stage:Verify_staging_directory_identity
           ~expected_kind:`Directory
           path
           staging_directory_identity;
         run_stage ~before_stage Remove_staging_directory (fun () ->
           Eio.Path.rmdir path);
         staging_directory_removed := true;
         close_open_resource
           ~before_stage
           ~stage:Close_staging_directory
           staging_directory_file;
         close_open_directory
           ~before_stage
           ~stage:Close_staging_directory
           staging_directory;
         sync_parent_capability ~before_stage ~stage:Sync_parent ~sw parent;
         parent_dirty := false;
         bound_discharge_started := true;
         ignore
           (run_recovery_transition
              ~before_stage
              ~stage:Discharge_bound_recovery_obligation
              ~recovery_phase:Recovery_discharge_bound
              (fun () ->
                 Recovery.discharge_bound
                   ~store:recovery
                   ~bound:bound_obligation)));
       Eio.Fiber.check ();
       Ok ()
     with
     | Eio.Cancel.Cancelled reason as cancellation ->
       let backtrace = Printexc.get_raw_backtrace () in
       let reason, interrupted_recovery, additional =
         match reason with
         | Capability_recovery_operation_cancelled (reason, interruption) ->
           reason, Some interruption, []
         | Parent_sync_cleanup_failed_on_cancellation (reason, failures) ->
           reason, None, write_cleanup_failures failures
         | reason -> reason, None, []
       in
       let cleanup_failures = additional @ cleanup () in
       if
         !target_effect = Target_unchanged
         && Option.is_none interrupted_recovery
         && cleanup_failures = []
       then Printexc.raise_with_backtrace cancellation backtrace
       else
         Printexc.raise_with_backtrace
           (Eio.Cancel.Cancelled
              (Capability_write_cancelled
                 ( reason
                 , { operation
                   ; target_effect = !target_effect
                   ; interrupted_primary_failure = None
                   ; interrupted_recovery
                   ; cleanup_failures
                   } )))
           backtrace
     | Capability_recovery_failed failure ->
       error (Recovery_primary_failure failure) []
     | Capability_write_failed (failure, additional) ->
       error
         (Write_primary_failure failure)
         (write_cleanup_failures additional)
     | exception_ ->
       let backtrace = Printexc.get_raw_backtrace () in
       error
         (Write_primary_failure
            (operation_failure Create_staging_directory exception_ backtrace))
         []
    in
    callback_result := Some result;
    result
  with
  | Eio.Cancel.Cancelled (Capability_write_cancelled _) as cancellation ->
    raise cancellation
  | Eio.Cancel.Cancelled reason as cancellation ->
    let backtrace = Printexc.get_raw_backtrace () in
    (match !callback_result with
     | Some (Error error) ->
       Printexc.raise_with_backtrace
         (Eio.Cancel.Cancelled
            (Capability_write_cancelled
               ( reason
               , { operation
                 ; target_effect = !target_effect
                 ; interrupted_primary_failure = Some error.primary_failure
                 ; interrupted_recovery = None
                 ; cleanup_failures = error.cleanup_failures
                 } )))
         backtrace
     | Some (Ok ()) | None ->
       if !target_effect = Target_unchanged
       then Printexc.raise_with_backtrace cancellation backtrace
       else
         Printexc.raise_with_backtrace
           (Eio.Cancel.Cancelled
              (Capability_write_cancelled
                 ( reason
                 , { operation
                   ; target_effect = !target_effect
                   ; interrupted_primary_failure = None
                   ; interrupted_recovery = None
                   ; cleanup_failures = []
                   } )))
           backtrace)
  | Capability_write_failed (failure, cleanup_failures) ->
    (match !callback_result with
     | Some (Error error) ->
       Error
         { error with
           cleanup_failures =
             error.cleanup_failures
             @ write_cleanup_failures (failure :: cleanup_failures)
         }
     | Some (Ok ()) | None ->
       Error
         { operation
         ; target_effect = !target_effect
         ; primary_failure = Write_primary_failure failure
         ; cleanup_failures = write_cleanup_failures cleanup_failures
         })
  | exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    let release_failure = operation_failure Cleanup_close exception_ backtrace in
    (match !callback_result with
     | Some (Error error) ->
       Error
         { error with
           cleanup_failures =
             error.cleanup_failures
             @ [ Write_cleanup_failure release_failure ]
         }
     | Some (Ok ()) | None ->
       Error
         { operation
         ; target_effect = !target_effect
         ; primary_failure = Write_primary_failure release_failure
         ; cleanup_failures = []
         })
;;

let create_capability_file_exclusive_with
      ~before_stage
      ~parent
      ~leaf
      ~permissions
      content
  =
  let operation = Create_exclusive_operation in
  let target_effect = ref Target_unchanged in
  let callback_result = ref None in
  try
    let leaf = validate_leaf ~before_stage leaf in
    Eio.Switch.run @@ fun sw ->
    let target = Eio.Path.(parent / Capability_leaf.to_string leaf) in
    let mutation_lease =
      run_stage ~before_stage Acquire_mutation_lease (fun () ->
        let parent_stat = Eio.Path.stat ~follow:true parent in
        if parent_stat.kind <> `Directory
        then
          raise_failure
            Acquire_mutation_lease
            (Unexpected_resource_kind parent_stat.kind);
        match
          Capability_mutation_lease.try_acquire
            ~parent_dev:parent_stat.dev
            ~parent_ino:parent_stat.ino
            ~leaf
        with
        | Some lease -> lease
        | None -> raise_failure Acquire_mutation_lease Mutation_contended)
    in
    Eio.Switch.on_release sw (fun () ->
      Capability_mutation_lease.release mutation_lease);
    let open_file = ref None in
    let identity = ref None in
    let parent_dirty = ref false in
    let cleanup () =
      Eio.Cancel.protect (fun () ->
        write_cleanup_failures
          (cleanup_open_file ~before_stage open_file
           @ cleanup_parent_if_dirty ~before_stage ~sw ~parent parent_dirty))
    in
    let error failure additional =
      Error
        { operation
        ; target_effect = !target_effect
        ; primary_failure = Write_primary_failure failure
        ; cleanup_failures = write_cleanup_failures additional @ cleanup ()
        }
    in
    let result =
      try
       let file =
         Eio.Cancel.protect (fun () ->
           let file =
             run_stage ~before_stage Create_target_entry (fun () ->
               Eio.Path.open_out ~sw ~create:(`Exclusive 0o600) target)
           in
           open_file := Some file;
           parent_dirty := true;
           target_effect := Target_created_incomplete;
           file)
       in
       identity := Some (identity_of_open_file ~before_stage file);
       write_open_file_payload ~before_stage file content;
       set_open_file_permissions ~before_stage file permissions;
       run_stage ~before_stage Sync_payload (fun () -> Eio.File.sync file);
       close_open_entry ~before_stage open_file;
       verify_entry_identity
         ~before_stage
         ~stage:Verify_entry_identity
         target
         identity;
       target_effect := Target_created;
       Eio.Cancel.protect (fun () ->
         sync_parent_capability ~before_stage ~stage:Sync_parent ~sw parent;
         parent_dirty := false);
       Eio.Fiber.check ();
       Ok ()
     with
     | Eio.Cancel.Cancelled reason as cancellation ->
       let backtrace = Printexc.get_raw_backtrace () in
       let reason, additional =
         match reason with
         | Parent_sync_cleanup_failed_on_cancellation (reason, failures) ->
           reason, write_cleanup_failures failures
         | reason -> reason, []
       in
       let cleanup_failures = additional @ cleanup () in
       if !target_effect = Target_unchanged && cleanup_failures = []
       then Printexc.raise_with_backtrace cancellation backtrace
       else
         Printexc.raise_with_backtrace
           (Eio.Cancel.Cancelled
              (Capability_write_cancelled
                 ( reason
                 , { operation
                   ; target_effect = !target_effect
                   ; interrupted_primary_failure = None
                   ; interrupted_recovery = None
                   ; cleanup_failures
                   } )))
           backtrace
     | Capability_write_failed (failure, additional) ->
       error failure additional
     | exception_ ->
       let backtrace = Printexc.get_raw_backtrace () in
       error
         (operation_failure Create_target_entry exception_ backtrace)
         []
    in
    callback_result := Some result;
    result
  with
  | Eio.Cancel.Cancelled (Capability_write_cancelled _) as cancellation ->
    raise cancellation
  | Eio.Cancel.Cancelled reason as cancellation ->
    let backtrace = Printexc.get_raw_backtrace () in
    (match !callback_result with
     | Some (Error error) ->
       Printexc.raise_with_backtrace
         (Eio.Cancel.Cancelled
            (Capability_write_cancelled
               ( reason
               , { operation
                 ; target_effect = !target_effect
                 ; interrupted_primary_failure = Some error.primary_failure
                 ; interrupted_recovery = None
                 ; cleanup_failures = error.cleanup_failures
                 } )))
         backtrace
     | Some (Ok ()) | None ->
       if !target_effect = Target_unchanged
       then Printexc.raise_with_backtrace cancellation backtrace
       else
         Printexc.raise_with_backtrace
           (Eio.Cancel.Cancelled
              (Capability_write_cancelled
                 ( reason
                 , { operation
                   ; target_effect = !target_effect
                   ; interrupted_primary_failure = None
                   ; interrupted_recovery = None
                   ; cleanup_failures = []
                   } )))
           backtrace)
  | Capability_write_failed (failure, cleanup_failures) ->
    (match !callback_result with
     | Some (Error error) ->
       Error
         { error with
           cleanup_failures =
             error.cleanup_failures
             @ write_cleanup_failures (failure :: cleanup_failures)
         }
     | Some (Ok ()) | None ->
       Error
         { operation
         ; target_effect = !target_effect
         ; primary_failure = Write_primary_failure failure
         ; cleanup_failures = write_cleanup_failures cleanup_failures
         })
  | exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    let release_failure = operation_failure Cleanup_close exception_ backtrace in
    (match !callback_result with
     | Some (Error error) ->
       Error
         { error with
           cleanup_failures =
             error.cleanup_failures
             @ [ Write_cleanup_failure release_failure ]
         }
     | Some (Ok ()) | None ->
       Error
         { operation
         ; target_effect = !target_effect
         ; primary_failure = Write_primary_failure release_failure
         ; cleanup_failures = []
         })
;;

let replace_capability_file ~recovery ~parent ~target content =
  match
    Recovery_access.with_store recovery (fun recovery ->
      replace_capability_file_with
        ~before_stage:(fun _ -> ())
        ~recovery
        ~parent
        ~target
        content)
  with
  | Ok result -> result
  | Error Recovery_access.Keeper_lane_not_available ->
    Error
      { operation = Atomic_replace_operation
      ; target_effect = Target_unchanged
      ; primary_failure =
          Recovery_access_primary_failure Recovery_access_not_available
      ; cleanup_failures = []
      }
;;

let create_capability_file_exclusive ~parent ~leaf ~permissions content =
  create_capability_file_exclusive_with
    ~before_stage:(fun _ -> ())
    ~parent
    ~leaf
    ~permissions
    content
;;

let sync_directory_capability_with ~before_stage directory =
  try
    let result =
      Eio.Switch.run @@ fun sw ->
      sync_parent_capability ~before_stage ~stage:Sync_parent ~sw directory;
      Ok ()
    in
    Eio.Fiber.check ();
    result
  with
  | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
  | Capability_write_failed (failure, cleanup_failures) ->
    Error { failure; cleanup_failures }
  | exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    Error
      { failure = operation_failure Sync_parent exception_ backtrace
      ; cleanup_failures = []
      }
;;

let sync_directory_capability directory =
  sync_directory_capability_with ~before_stage:(fun _ -> ()) directory
;;

module Capability_write_for_testing = struct
  let replace_capability_file
        ~before_stage
        ~recovery
        ~parent
        ~target
        content
    =
    match
      Recovery_access.with_store recovery (fun recovery ->
        replace_capability_file_with
          ~before_stage
          ~recovery
          ~parent
          ~target
          content)
    with
    | Ok result -> result
    | Error Recovery_access.Keeper_lane_not_available ->
      Error
        { operation = Atomic_replace_operation
        ; target_effect = Target_unchanged
        ; primary_failure =
            Recovery_access_primary_failure Recovery_access_not_available
        ; cleanup_failures = []
        }
  ;;

  let create_capability_file_exclusive =
    create_capability_file_exclusive_with
  ;;

  let with_publication_recovery_access ~registry_root ~owner f =
    Eio.Switch.run @@ fun sw ->
    match Recovery_access.open_registry ~sw ~registry_root with
    | Error error ->
      Error (recovery_transition_failure Recovery_open_registry error)
    | Ok registry ->
      (match Recovery_access.with_lane ~registry ~owner f with
       | Ok value -> Ok value
       | Error (Recovery_access.Invalid_owner error) ->
         Error (recovery_validation_failure Recovery_validate_owner error)
       | Error (Recovery_access.Store_failed error) ->
         Error (recovery_transition_failure Recovery_open_store error))
  ;;

  let sync_directory_capability = sync_directory_capability_with
end

let save_file_atomic
  ~(save_file : string -> string -> unit)
  (path : string)
  (content : string)
  : (unit, string) Result.t
  =
  let dir = Stdlib.Filename.dirname path in
  let tmp =
    Stdlib.Filename.temp_file ~temp_dir:dir atomic_tmp_prefix atomic_tmp_suffix
  in
  try
    save_file tmp content;
    fsync_path tmp;
    Stdlib.Sys.rename tmp path;
    (try fsync_path dir with
     | Unix.Unix_error _ -> ());
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e ->
    (try Stdlib.Sys.remove tmp with
     | Sys_error _ -> ());
    raise e
  | exn ->
    (try Stdlib.Sys.remove tmp with
     | Sys_error _ -> ());
    Error (Printf.sprintf "save_file_atomic %s: %s" path (Printexc.to_string exn))
;;

let has_atomic_temp_shape ~prefix name =
  let n = String.length name in
  let p = String.length prefix in
  let s = String.length atomic_tmp_suffix in
  n >= p + s
  && String.starts_with name ~prefix
  && String.ends_with ~suffix:atomic_tmp_suffix name
;;

let is_atomic_orphan_name name =
  has_atomic_temp_shape ~prefix:atomic_tmp_prefix name
;;

type atomic_orphan_cleanup_scope =
  | Directory_only
  | Directory_and_immediate_subdirectories

type atomic_orphan_cleanup_operation =
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

type atomic_orphan_cleanup_cause =
  | Unix_failure of Unix.error * string * string
  | Sys_failure of string
  | Unexpected_file_kind of Unix.file_kind
  | Outside_ownership_root of { ownership_root : string }
  | Identity_changed
  | Other_failure of exn

type atomic_orphan_cleanup_failure =
  { operation : atomic_orphan_cleanup_operation
  ; path : string
  ; cause : atomic_orphan_cleanup_cause
  }

type atomic_orphan_cleanup_report =
  { inspected : int
  ; deleted : int
  ; preserved : int
  ; failures : atomic_orphan_cleanup_failure list
  }

let atomic_orphan_cleanup_operation_to_string = function
  | Inspect_cleanup_root -> "inspect_cleanup_root"
  | Read_cleanup_directory -> "read_cleanup_directory"
  | Inspect_orphan -> "inspect_orphan"
  | Create_recovery_directory -> "create_recovery_directory"
  | Sync_recovery_parent -> "sync_recovery_parent"
  | Link_preserved_orphan -> "link_preserved_orphan"
  | Verify_preserved_orphan -> "verify_preserved_orphan"
  | Sync_preserved_orphan -> "sync_preserved_orphan"
  | Sync_recovery_directory -> "sync_recovery_directory"
  | Delete_empty_orphan -> "delete_empty_orphan"
  | Delete_preserved_source -> "delete_preserved_source"
  | Sync_source_directory -> "sync_source_directory"
  | Close_cleanup_descriptor -> "close_cleanup_descriptor"
;;

let file_kind_to_string = function
  | Unix.S_REG -> "regular_file"
  | Unix.S_DIR -> "directory"
  | Unix.S_CHR -> "character_device"
  | Unix.S_BLK -> "block_device"
  | Unix.S_LNK -> "symbolic_link"
  | Unix.S_FIFO -> "fifo"
  | Unix.S_SOCK -> "socket"
;;

let atomic_orphan_cleanup_cause_to_string = function
  | Unix_failure (error, fn, arg) ->
    Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message error)
  | Sys_failure detail -> detail
  | Unexpected_file_kind kind ->
    Printf.sprintf "unexpected file kind: %s" (file_kind_to_string kind)
  | Outside_ownership_root { ownership_root } ->
    Printf.sprintf "path is outside ownership root: %s" ownership_root
  | Identity_changed -> "filesystem identity changed during cleanup"
  | Other_failure exn -> Printexc.to_string exn
;;

let atomic_orphan_cleanup_failure_to_string failure =
  Printf.sprintf
    "operation=%s path=%s reason=%s"
    (atomic_orphan_cleanup_operation_to_string failure.operation)
    failure.path
    (atomic_orphan_cleanup_cause_to_string failure.cause)
;;

let cleanup_cause_of_exn = function
  | Unix.Unix_error (error, fn, arg) -> Unix_failure (error, fn, arg)
  | Sys_error detail -> Sys_failure detail
  | exn -> Other_failure exn
;;

let same_inode left right =
  left.Unix.st_dev = right.Unix.st_dev && left.Unix.st_ino = right.Unix.st_ino
;;

let cleanup_atomic_orphans ~ownership_root ~(base_path : string) ~scope () =
  let recovered_name = ".recovered" in
  let empty_report = { inspected = 0; deleted = 0; preserved = 0; failures = [] } in
  let add_failure report ~operation ~path cause =
    { report with failures = { operation; path; cause } :: report.failures }
  in
  let record_exn report ~operation ~path exn =
    match exn with
    | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
    | exn -> add_failure report ~operation ~path (cleanup_cause_of_exn exn)
  in
  let lstat report ~operation path =
    try Some (Unix.lstat path), report with
    | Unix.Unix_error (Unix.ENOENT, _, _) -> None, report
    | exn -> None, record_exn report ~operation ~path exn
  in
  let identity_is_current report ~operation ~path ~expected ~kind =
    match lstat report ~operation path with
    | Some actual, report
      when actual.Unix.st_kind = kind && same_inode expected actual ->
      true, report
    | Some actual, report when actual.Unix.st_kind <> kind ->
      ( false
      , add_failure
          report
          ~operation
          ~path
          (Unexpected_file_kind actual.Unix.st_kind) )
    | Some _, report ->
      false, add_failure report ~operation ~path Identity_changed
    | None, report ->
      false, add_failure report ~operation ~path Identity_changed
  in
  let inspect_owned_chain report =
    try
      match Owned_directory_chain.inspect ~ownership_root base_path with
      | Ok Owned_directory_chain.Owned_directory_missing -> None, report
      | Ok (Owned_directory_chain.Owned_directory stat) -> Some stat, report
      | Error (Owned_directory_chain.Owned_path_outside_root _) ->
        ( None
        , add_failure
            report
            ~operation:Inspect_cleanup_root
            ~path:base_path
            (Outside_ownership_root { ownership_root }) )
      | Error (Owned_directory_chain.Owned_path_non_directory { path; kind }) ->
        ( None
        , add_failure
            report
            ~operation:Inspect_cleanup_root
            ~path
            (Unexpected_file_kind kind) )
    with
    | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
    | exn ->
      None, record_exn report ~operation:Inspect_cleanup_root ~path:base_path exn
  in
  let close_descriptor report path fd =
    try Unix.close fd; report with
    | exn -> record_exn report ~operation:Close_cleanup_descriptor ~path exn
  in
  let sync_verified_path report ~operation ~path ~expected ~kind =
    let opened =
      try
        Ok
          (Unix.openfile
             path
             [ Unix.O_RDONLY; Unix.O_CLOEXEC; Unix.O_NONBLOCK ]
             0)
      with
      | exn -> Error exn
    in
    match opened with
    | Error exn -> None, record_exn report ~operation ~path exn
    | Ok fd ->
      let finish report result =
        let report = close_descriptor report path fd in
        result, report
      in
      (try
         let actual = Unix.fstat fd in
         if actual.Unix.st_kind <> kind || not (same_inode expected actual)
         then finish report None
                |> fun (_, report) ->
                None, add_failure report ~operation ~path Identity_changed
         else (
           Unix.fsync fd;
           finish report (Some ()))
       with
       | exn ->
         let report = record_exn report ~operation ~path exn in
         finish report None)
  in
  let ensure_child_directory report ~parent ~parent_stat name =
    let path = Filename.concat parent name in
    match lstat report ~operation:Create_recovery_directory path with
    | Some stat, report when stat.Unix.st_kind = Unix.S_DIR ->
      Some (path, stat), report
    | Some stat, report ->
      ( None
      , add_failure
          report
          ~operation:Create_recovery_directory
          ~path
          (Unexpected_file_kind stat.Unix.st_kind) )
    | None, report ->
      (try
         Unix.mkdir path 0o700;
         let synced_parent, report =
           sync_verified_path
             report
             ~operation:Sync_recovery_parent
             ~path:parent
             ~expected:parent_stat
             ~kind:Unix.S_DIR
         in
         (match synced_parent with
          | None -> None, report
          | Some () ->
            (match lstat report ~operation:Create_recovery_directory path with
             | Some stat, report when stat.Unix.st_kind = Unix.S_DIR ->
               Some (path, stat), report
             | Some stat, report ->
               ( None
               , add_failure
                   report
                   ~operation:Create_recovery_directory
                   ~path
                   (Unexpected_file_kind stat.Unix.st_kind) )
             | None, report ->
               ( None
               , add_failure
                   report
                   ~operation:Create_recovery_directory
                   ~path
                   Identity_changed )))
       with
       | Unix.Unix_error (Unix.EEXIST, _, _) ->
         (match lstat report ~operation:Create_recovery_directory path with
          | Some stat, report when stat.Unix.st_kind = Unix.S_DIR ->
            Some (path, stat), report
          | Some stat, report ->
            ( None
            , add_failure
                report
                ~operation:Create_recovery_directory
                ~path
                (Unexpected_file_kind stat.Unix.st_kind) )
          | None, report ->
            ( None
            , add_failure
                report
                ~operation:Create_recovery_directory
                ~path
                Identity_changed ))
       | exn ->
         None, record_exn report ~operation:Create_recovery_directory ~path exn)
  in
  let ensure_recovery_directory report ~base_stat source =
    match
      ensure_child_directory
        report
        ~parent:base_path
        ~parent_stat:base_stat
        recovered_name
    with
    | None, report -> None, report
    | Some (recovered, recovered_stat), report ->
      let first =
        match source with
        | `Root -> "root"
        | `Child _ -> "children"
      in
      (match
         ensure_child_directory
           report
           ~parent:recovered
           ~parent_stat:recovered_stat
           first
       with
       | None, report -> None, report
       | Some (destination, destination_stat), report ->
         (match source with
          | `Root -> Some (destination, destination_stat), report
          | `Child child ->
            ensure_child_directory
              report
              ~parent:destination
              ~parent_stat:destination_stat
              child))
  in
  let find_or_create_preserved_link
        report
        ~source_path
        ~source_stat
        ~source_dir
        ~source_dir_stat
        ~destination
        ~destination_stat
        name
    =
    let rec loop report collision =
      let candidate_name =
        if collision = 0 then name else Printf.sprintf "%s.%d" name collision
      in
      let candidate = Filename.concat destination candidate_name in
      let source_current, report =
        identity_is_current
          report
          ~operation:Verify_preserved_orphan
          ~path:source_path
          ~expected:source_stat
          ~kind:Unix.S_REG
      in
      let source_dir_current, report =
        identity_is_current
          report
          ~operation:Verify_preserved_orphan
          ~path:source_dir
          ~expected:source_dir_stat
          ~kind:Unix.S_DIR
      in
      let destination_current, report =
        identity_is_current
          report
          ~operation:Verify_preserved_orphan
          ~path:destination
          ~expected:destination_stat
          ~kind:Unix.S_DIR
      in
      if not (source_current && source_dir_current && destination_current)
      then None, report
      else
        try
          Unix.link ~follow:false source_path candidate;
          Some candidate, report
        with
        | Unix.Unix_error (Unix.EEXIST, _, _) ->
          (match lstat report ~operation:Verify_preserved_orphan candidate with
           | Some stat, report
             when stat.Unix.st_kind = Unix.S_REG && same_inode source_stat stat ->
             Some candidate, report
           | _, report -> loop report (collision + 1))
        | exn ->
          ( None
          , record_exn report ~operation:Link_preserved_orphan ~path:candidate exn )
    in
    loop report 0
  in
  let preserve_nonempty report ~base_stat ~dir ~dir_stat ~source name source_stat =
    match ensure_recovery_directory report ~base_stat source with
    | None, report -> report
    | Some (destination, destination_stat), report ->
      let source_path = Filename.concat dir name in
      (match
         find_or_create_preserved_link
           report
           ~source_path
           ~source_stat
           ~source_dir:dir
           ~source_dir_stat:dir_stat
           ~destination
           ~destination_stat
           name
       with
       | None, report -> report
       | Some target, report ->
         let target_stat, report =
           lstat report ~operation:Verify_preserved_orphan target
         in
         (match target_stat with
          | Some target_stat
            when target_stat.Unix.st_kind = Unix.S_REG
                 && same_inode source_stat target_stat ->
            let synced_file, report =
              sync_verified_path
                report
                ~operation:Sync_preserved_orphan
                ~path:target
                ~expected:target_stat
                ~kind:Unix.S_REG
            in
            let synced_destination, report =
              sync_verified_path
                report
                ~operation:Sync_recovery_directory
                ~path:destination
                ~expected:destination_stat
                ~kind:Unix.S_DIR
            in
            (match synced_file, synced_destination with
             | Some (), Some () ->
               let source_current, report =
                 identity_is_current
                   report
                   ~operation:Delete_preserved_source
                   ~path:source_path
                   ~expected:source_stat
                   ~kind:Unix.S_REG
               in
               let source_dir_current, report =
                 identity_is_current
                   report
                   ~operation:Delete_preserved_source
                   ~path:dir
                   ~expected:dir_stat
                   ~kind:Unix.S_DIR
               in
               if not (source_current && source_dir_current)
               then report
               else
                 (try
                    Unix.unlink source_path;
                    let _, report =
                      sync_verified_path
                        report
                        ~operation:Sync_source_directory
                        ~path:dir
                        ~expected:dir_stat
                        ~kind:Unix.S_DIR
                    in
                    { report with preserved = report.preserved + 1 }
                  with
                  | exn ->
                    record_exn
                      report
                      ~operation:Delete_preserved_source
                      ~path:source_path
                      exn)
             | None, _ | _, None -> report)
          | Some target_stat when target_stat.Unix.st_kind <> Unix.S_REG ->
            add_failure
              report
              ~operation:Verify_preserved_orphan
              ~path:target
              (Unexpected_file_kind target_stat.Unix.st_kind)
          | Some _ ->
            add_failure
              report
              ~operation:Verify_preserved_orphan
              ~path:target
              Identity_changed
          | None ->
            add_failure
              report
              ~operation:Verify_preserved_orphan
              ~path:target
              Identity_changed))
  in
  let delete_empty report ~dir ~dir_stat ~source_stat path =
    let source_current, report =
      identity_is_current
        report
        ~operation:Delete_empty_orphan
        ~path
        ~expected:source_stat
        ~kind:Unix.S_REG
    in
    let source_dir_current, report =
      identity_is_current
        report
        ~operation:Delete_empty_orphan
        ~path:dir
        ~expected:dir_stat
        ~kind:Unix.S_DIR
    in
    if not (source_current && source_dir_current)
    then report
    else
      try
        Unix.unlink path;
        let _, report =
          sync_verified_path
            report
            ~operation:Sync_source_directory
            ~path:dir
            ~expected:dir_stat
            ~kind:Unix.S_DIR
        in
        { report with deleted = report.deleted + 1 }
      with
      | exn -> record_exn report ~operation:Delete_empty_orphan ~path exn
  in
  (* TEL-OK: this leaf returns every cleanup decision/failure in the typed
     [report]; the schema owner records that report to its metric namespace. *)
  let handle_orphan report ~base_stat ~source ~dir ~dir_stat name =
    let path = Filename.concat dir name in
    match lstat report ~operation:Inspect_orphan path with
    | None, report ->
      add_failure report ~operation:Inspect_orphan ~path Identity_changed
    | Some stat, report when stat.Unix.st_kind <> Unix.S_REG ->
      add_failure
        report
        ~operation:Inspect_orphan
        ~path
        (Unexpected_file_kind stat.Unix.st_kind)
    | Some stat, report when stat.Unix.st_size = 0 ->
      delete_empty report ~dir ~dir_stat ~source_stat:stat path
    | Some stat, report ->
      preserve_nonempty report ~base_stat ~dir ~dir_stat ~source name stat
  in
  let fold_directory report ~base_stat ~source ~dir ~dir_stat ~on_entry =
    let opened =
      try Ok (Unix.opendir dir) with
      | exn -> Error exn
    in
    match opened with
    | Error exn ->
      record_exn report ~operation:Read_cleanup_directory ~path:dir exn
    | Ok handle ->
      let close_after_exception exn =
        let backtrace = Printexc.get_raw_backtrace () in
        (try Unix.closedir handle with
         | close_exn ->
           Stdlib.Printf.eprintf
             "[atomic_write] close after cleanup exception failed path=%s primary=%s close=%s\n%!"
             dir
             (Printexc.to_string exn)
             (Printexc.to_string close_exn));
        Printexc.raise_with_backtrace exn backtrace
      in
      let rec loop report =
        match Unix.readdir handle with
        | name ->
          let report =
            if String.equal name "." || String.equal name ".."
            then report
            else on_entry report ~base_stat ~source ~dir ~dir_stat name
          in
          loop report
        | exception End_of_file -> report
        | exception exn ->
          record_exn report ~operation:Read_cleanup_directory ~path:dir exn
      in
      let report =
        try loop report with
        | exn -> close_after_exception exn
      in
      (try Unix.closedir handle; report with
       | exn ->
         record_exn report ~operation:Close_cleanup_descriptor ~path:dir exn)
  in
  let scan_orphans report ~base_stat ~source ~dir ~dir_stat =
    fold_directory
      report
      ~base_stat
      ~source
      ~dir
      ~dir_stat
      ~on_entry:(fun report ~base_stat ~source ~dir ~dir_stat name ->
        if is_atomic_orphan_name name
        then
          handle_orphan
            { report with inspected = report.inspected + 1 }
            ~base_stat
            ~source
            ~dir
            ~dir_stat
            name
        else report)
  in
  let result =
    match inspect_owned_chain empty_report with
    | None, report -> report
    | Some base_stat, report ->
      let report =
        scan_orphans
          report
          ~base_stat
          ~source:`Root
          ~dir:base_path
          ~dir_stat:base_stat
      in
      (match scope with
       | Directory_only -> report
       | Directory_and_immediate_subdirectories ->
         fold_directory
           report
           ~base_stat
           ~source:`Root
           ~dir:base_path
           ~dir_stat:base_stat
           ~on_entry:(fun report ~base_stat ~source:_ ~dir ~dir_stat:_ name ->
             if String.equal name recovered_name
             then report
             else (
               let child = Filename.concat dir name in
               match lstat report ~operation:Inspect_cleanup_root child with
               | Some child_stat, report
                 when child_stat.Unix.st_kind = Unix.S_DIR ->
                 scan_orphans
                   report
                   ~base_stat
                   ~source:(`Child name)
                   ~dir:child
                   ~dir_stat:child_stat
               | Some _, report
               | None, report -> report)))
  in
  { result with failures = List.rev result.failures }
;;
