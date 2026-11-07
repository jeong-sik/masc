let capability_write_failure_json
      (failure : Fs_compat.capability_write_failure)
  =
  let cause_fields =
    match failure.cause with
    | Fs_compat.Payload_write_failed { bytes_written; _ } ->
      [ "bytes_written", `Int bytes_written ]
    | ( Fs_compat.Invalid_recovery_target _
      | Fs_compat.Mutation_contended
      | Fs_compat.Target_already_exists
      | Fs_compat.Posix_descriptor_unavailable
      | Fs_compat.Unexpected_resource_kind _
      | Fs_compat.Resource_identity_unavailable
      | Fs_compat.Resource_identity_changed
      | Fs_compat.Operation_failed _ ) -> []
  in
  `Assoc
    ([ ( "stage"
       , `String (Fs_compat.capability_write_stage_to_string failure.stage) )
     ; ( "cause"
       , `String (Fs_compat.capability_write_cause_to_string failure.cause) )
     ]
     @ cause_fields)
;;

let capability_recovery_failure_json failure =
  `Assoc
    [ ( "phase"
      , `String
          (Fs_compat.capability_recovery_phase_to_string
             (Fs_compat.capability_recovery_failure_phase failure)) )
    ; ( "effect"
      , `String
          (Fs_compat.capability_recovery_effect_to_string
             (Fs_compat.capability_recovery_failure_effect failure)) )
    ; "detail", `String (Fs_compat.capability_recovery_failure_to_string failure)
    ]
;;

let capability_write_primary_failure_json = function
  | Fs_compat.Write_primary_failure failure ->
    `Assoc
      [ "kind", `String "write"
      ; "failure", capability_write_failure_json failure
      ]
  | Fs_compat.Recovery_primary_failure failure ->
    `Assoc
      [ "kind", `String "recovery"
      ; "failure", capability_recovery_failure_json failure
      ]
  | Fs_compat.Recovery_access_primary_failure
      Fs_compat.Recovery_access_not_available ->
    `Assoc
      [ "kind", `String "recovery_access"
      ; "failure", `String "recovery_access_not_available"
      ]
;;

let capability_write_cleanup_failure_json = function
  | Fs_compat.Write_cleanup_failure failure ->
    `Assoc
      [ "kind", `String "write"
      ; "failure", capability_write_failure_json failure
      ]
  | Fs_compat.Recovery_cleanup_failure failure ->
    `Assoc
      [ "kind", `String "recovery"
      ; "failure", capability_recovery_failure_json failure
      ]
;;

let observe_capability_write_failure_backtrace
      ~keeper_name
      ~target
      (failure : Fs_compat.capability_write_failure)
  =
  match failure.Fs_compat.cause with
  | Fs_compat.Operation_failed { exception_; backtrace } ->
    Log.Keeper.error
      ~keeper_name
      "WRITE_AUDIT: filesystem publication operation failed path=%s stage=%s error=%s backtrace=%s"
      target
      (Fs_compat.capability_write_stage_to_string failure.stage)
      (Printexc.to_string exception_)
      (Printexc.raw_backtrace_to_string backtrace)
  | Fs_compat.Payload_write_failed { exception_; backtrace; bytes_written } ->
    Log.Keeper.error
      ~keeper_name
      "WRITE_AUDIT: filesystem payload write failed path=%s stage=%s bytes_written=%d error=%s backtrace=%s"
      target
      (Fs_compat.capability_write_stage_to_string failure.stage)
      bytes_written
      (Printexc.to_string exception_)
      (Printexc.raw_backtrace_to_string backtrace)
  | ( Fs_compat.Invalid_recovery_target _
    | Fs_compat.Mutation_contended
      | Fs_compat.Target_already_exists
    | Fs_compat.Posix_descriptor_unavailable
    | Fs_compat.Unexpected_resource_kind _
    | Fs_compat.Resource_identity_unavailable
    | Fs_compat.Resource_identity_changed ) -> ()
;;

let observe_capability_recovery_failure ~keeper_name ~target failure =
  Log.Keeper.error
    ~keeper_name
    "WRITE_AUDIT: filesystem recovery transition failed path=%s phase=%s effect=%s failure=%s"
    target
    (Fs_compat.capability_recovery_phase_to_string
       (Fs_compat.capability_recovery_failure_phase failure))
    (Fs_compat.capability_recovery_effect_to_string
       (Fs_compat.capability_recovery_failure_effect failure))
    (Fs_compat.capability_recovery_failure_to_string failure)
;;

let observe_capability_write_primary_failure ~keeper_name ~target = function
  | Fs_compat.Write_primary_failure failure ->
    observe_capability_write_failure_backtrace ~keeper_name ~target failure
  | Fs_compat.Recovery_primary_failure failure ->
    observe_capability_recovery_failure ~keeper_name ~target failure
  | Fs_compat.Recovery_access_primary_failure
      Fs_compat.Recovery_access_not_available ->
    Log.Keeper.error
      ~keeper_name
      "WRITE_AUDIT: filesystem recovery access unavailable path=%s"
      target
;;

let observe_capability_write_cleanup_failure ~keeper_name ~target = function
  | Fs_compat.Write_cleanup_failure failure ->
    observe_capability_write_failure_backtrace ~keeper_name ~target failure
  | Fs_compat.Recovery_cleanup_failure failure ->
    observe_capability_recovery_failure ~keeper_name ~target failure
;;

let observe_capability_write_error
      ~keeper_name
      ~target
      (error : Fs_compat.capability_write_error)
  =
  observe_capability_write_primary_failure
    ~keeper_name
    ~target
    error.Fs_compat.primary_failure;
  List.iter
    (observe_capability_write_cleanup_failure ~keeper_name ~target)
    error.cleanup_failures
;;

let observe_capability_directory_sync_error
      ~keeper_name
      ~target
      (error : Fs_compat.capability_directory_sync_error)
  =
  observe_capability_write_failure_backtrace
    ~keeper_name
    ~target
    error.failure;
  List.iter
    (observe_capability_write_failure_backtrace ~keeper_name ~target)
    error.cleanup_failures
;;
