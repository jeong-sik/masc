open Keeper_tool_shared_runtime
open Keeper_tool_filesystem_guidance
open Keeper_tool_filesystem_runtime_shared
open Keeper_tool_filesystem_runtime_write_types

let append_capability ~on_cancelled file content =
  let outcome =
    Eio.Cancel.protect (fun () ->
      Fs_compat.append_capability_observed file content)
  in
  (try Eio.Fiber.check () with
   | Eio.Cancel.Cancelled _ as cancellation ->
     on_cancelled outcome;
     raise cancellation);
  match outcome.write_failure, outcome.sync_failure, outcome.target_binding with
  | None, None, Fs_compat.Capability_append_target_verified -> Ok ()
  | ( None
    , None
    , Fs_compat.Capability_append_target_not_checked )
    when outcome.requested_bytes = 0 -> Ok ()
  | (None, None, (Fs_compat.Capability_append_target_changed | Fs_compat.Capability_append_target_check_failed _))
  | (None, Some _, _) | (Some _, _, _) | (None, None, Capability_append_target_not_checked) -> Error (Content_write_append outcome)
;;

let append_target_effect_to_string = function
  | Append_target_unchanged -> "target_unchanged"
  | Append_target_extended_complete -> "target_extended_complete"
  | Append_target_extended_partial -> "target_extended_partial"
  | Append_target_extended_detached -> "target_extended_detached"
  | Append_target_state_unknown -> "target_state_unknown"
;;

let capability_append_open_error_kind = function
  | Fs_compat.Capability_append_open_invalid_leaf _ -> "invalid_leaf"
  | Fs_compat.Capability_append_open_missing -> "missing"
  | Fs_compat.Capability_append_open_failed _ -> "operation_failed"
;;

let capability_append_open_error_payload ~target error =
  error_json
    ~fields:
      [ "path", `String target
      ; ( "filesystem_append_open_failure"
        , `Assoc
            [ ( "kind"
              , `String (capability_append_open_error_kind error) )
            ; ( "cause"
              , `String
                  (Fs_compat.capability_append_open_error_to_string error) )
            ] )
      ]
    (fs_guidance_text Append_capability_failed)
;;

let observe_capability_append_open_error ~keeper_name ~target error =
  match error with
  | Fs_compat.Capability_append_open_failed { exception_; backtrace } ->
    Log.Keeper.error
      ~keeper_name
      "WRITE_AUDIT: append capability acquisition failed path=%s error=%s backtrace=%s"
      target
      (Printexc.to_string exception_)
      (Printexc.raw_backtrace_to_string backtrace)
  | ( Fs_compat.Capability_append_open_invalid_leaf _
    | Fs_compat.Capability_append_open_missing ) ->
    Log.Keeper.error
      ~keeper_name
      "WRITE_AUDIT: append capability acquisition rejected path=%s kind=%s"
      target
      (capability_append_open_error_kind error)
;;

let append_target_effect outcome =
  match outcome.target_binding with
  | Fs_compat.Capability_append_target_not_checked
    when outcome.bytes_written = 0 -> Append_target_unchanged
  | Fs_compat.Capability_append_target_verified ->
    if outcome.bytes_written = 0
    then Append_target_unchanged
    else if
      outcome.bytes_written = outcome.requested_bytes
      && Option.is_none outcome.write_failure
    then Append_target_extended_complete
    else Append_target_extended_partial
  | Fs_compat.Capability_append_target_changed ->
    if outcome.bytes_written = 0
    then Append_target_state_unknown
    else Append_target_extended_detached
  | ( Fs_compat.Capability_append_target_not_checked
    | Fs_compat.Capability_append_target_check_failed _ ) ->
    Append_target_state_unknown
;;

let append_target_binding_json = function
  | Fs_compat.Capability_append_target_not_checked ->
    `Assoc [ "status", `String "not_checked" ]
  | Fs_compat.Capability_append_target_verified ->
    `Assoc [ "status", `String "verified" ]
  | Fs_compat.Capability_append_target_changed ->
    `Assoc [ "status", `String "changed" ]
  | Fs_compat.Capability_append_target_check_failed { exception_; _ } ->
    `Assoc
      [ "status", `String "check_failed"
      ; "cause", `String (Printexc.to_string exception_)
      ]
;;

let append_write_outcome_payload ~target outcome =
  error_json
    ~fields:
      [ "path", `String target
      ; ( "filesystem_append_target_effect"
        , `String
            (append_target_effect_to_string (append_target_effect outcome)) )
      ; ( "filesystem_append_target_binding"
        , append_target_binding_json outcome.target_binding )
      ; ( "filesystem_append_failure"
        , match outcome.write_failure with
          | None -> `Null
          | Some failure ->
            `String (Fs_compat.capability_append_failure_to_string failure) )
      ; ( "filesystem_append_sync_failure"
        , match outcome.sync_failure with
          | None -> `Null
          | Some { exception_; _ } -> `String (Printexc.to_string exception_) )
      ]
    (fs_guidance_text Append_incomplete)
;;

let observe_append_write_outcome ~keeper_name ~target outcome =
  Log.Keeper.error
    ~keeper_name
    "WRITE_AUDIT: append publication outcome path=%s requested_bytes=%d bytes_written=%d target_effect=%s failure=%s"
    target
    outcome.requested_bytes
    outcome.bytes_written
    (append_target_effect_to_string (append_target_effect outcome))
    (match outcome.write_failure with
     | None -> "none"
     | Some failure -> Fs_compat.capability_append_failure_to_string failure);
  (match outcome.write_failure with
   | Some
       (Fs_compat.Capability_append_operation_failed
         { exception_; backtrace }) ->
     Log.Keeper.error
       ~keeper_name
       "WRITE_AUDIT: append write failed path=%s error=%s backtrace=%s"
       target
       (Printexc.to_string exception_)
       (Printexc.raw_backtrace_to_string backtrace)
   | ( None
     | Some Fs_compat.Capability_append_posix_descriptor_unavailable
     | Some Fs_compat.Capability_append_mutation_contended ) -> ());
  let observe_operation_failure
        label
        (failure : Fs_compat.capability_append_operation_failure)
    =
    Log.Keeper.error
      ~keeper_name
      "WRITE_AUDIT: append %s failed path=%s error=%s backtrace=%s"
      label
      target
      (Printexc.to_string failure.exception_)
      (Printexc.raw_backtrace_to_string failure.backtrace)
  in
  Option.iter (observe_operation_failure "sync") outcome.sync_failure;
  (match outcome.target_binding with
   | Fs_compat.Capability_append_target_check_failed failure ->
     observe_operation_failure "target identity check" failure
   | ( Fs_compat.Capability_append_target_not_checked
     | Fs_compat.Capability_append_target_verified
     | Fs_compat.Capability_append_target_changed ) -> ())
;;
