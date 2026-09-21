type 'registration_error error =
  | Shutdown_reserved of Keeper_shutdown_types.Operation_id.t
  | Intake_token_not_live
  | Reservation_unavailable of Keeper_lifecycle_reservation.snapshot
  | Registration_failed of 'registration_error
  | Launch_failed of
      { exception_detail : string
      ; rollback_error : string option
      }

type rollback =
  | Remove_registered
  | Restore_previous of Keeper_registry.registry_entry
  | Retain_registered

let release_owned token =
  match Keeper_lifecycle_reservation.release token with
  | Keeper_lifecycle_reservation.Released -> ()
  | outcome ->
    Log.Keeper.warn
      "keepalive launch lifecycle reservation release was not clean: %s"
      (Keeper_lifecycle_reservation.release_outcome_to_string outcome)
;;

let reject_for_rollback reg =
  match
    Keeper_lane.reject_before_start
      reg.Keeper_registry.lane
      ~reason:(Failure "keepalive launch transaction rolled back")
  with
  | Ok () -> Ok ()
  | Error error ->
    Error
      ("launch rollback retained a lane that crossed the start boundary: "
       ^ Keeper_lane.start_error_to_string error)
;;

let unregister token reg =
  match Keeper_registry.unregister_exact_for_lifecycle token reg with
  | Keeper_registry.Exact_unregistered
  | Keeper_registry.Exact_entry_missing -> Ok ()
  | Keeper_registry.Exact_entry_replaced ->
    Error "launch rollback found a newer registry lane"
  | Keeper_registry.Exact_unregister_lifecycle_reserved owner ->
    Error
      ("launch rollback lost lifecycle ownership: "
       ^ Keeper_lifecycle_reservation.snapshot_to_string owner)
;;

let rollback_registry rollback token reg =
  match rollback with
  | Retain_registered -> Ok ()
  | Remove_registered -> unregister token reg
  | Restore_previous previous ->
    (match unregister token reg with
     | Error _ as error -> error
     | Ok () ->
       (match Keeper_registry.restore_entry_if_absent_for_lifecycle token previous with
        | Keeper_registry.Entry_restored -> Ok ()
        | Keeper_registry.Entry_restore_occupied _ ->
          Error "restart rollback found an occupied registry key"
        | Keeper_registry.Entry_restore_invalid error ->
          Error (Keeper_registry.registry_entry_validation_error_to_string error)
        | Keeper_registry.Entry_restore_lifecycle_reserved owner ->
          Error
            ("restart rollback lost lifecycle ownership: "
             ^ Keeper_lifecycle_reservation.snapshot_to_string owner)))
;;

let run
      ?lifecycle_token
      ?intake_token
      ~base_path
      ~keeper_name
      ~register
      ~rollback
      launch
  =
  let run_admitted intake_token =
    let ownership =
      match lifecycle_token with
      | Some token -> Ok (token, false)
      | None ->
        (match
           Keeper_lifecycle_reservation.acquire
             ~base_path
             ~keeper_name
             ~purpose:Keeper_lifecycle_reservation.Keepalive_launch
         with
         | Ok token -> Ok (token, true)
         | Error (Keeper_lifecycle_reservation.Already_reserved owner) ->
           Error (Reservation_unavailable owner))
    in
    match ownership with
    | Error _ as error -> error
    | Ok (token, owns_token) ->
      Fun.protect
        ~finally:(fun () ->
          if owns_token then Eio.Cancel.protect (fun () -> release_owned token))
        (fun () ->
           (* Registration may load durable state before committing its final
              registry CAS. Keep the callback cancellation-protected so the
              transaction always obtains the exact entry needed for rollback
              after that commit. *)
           match Eio.Cancel.protect (fun () -> register token intake_token) with
           | Error error -> Error (Registration_failed error)
           | Ok reg ->
             (* The Librarian's catch-up is submitted before the launch
                callback, so no launch path can forget it; the submission is
                a queue hand-off and the launch does not wait for it (RFC
                librarian-lifecycle section 4.3, I7). *)
             (try
                Keeper_librarian_queue_refresh.submit_durable
                  ~base_path
                  ~keeper_name;
                Ok (launch intake_token token reg)
              with
              | exn -> (* cancel-guard-ok: PROVISIONAL, delete with #37372. This arm dispatches on the exception below and re-throws Cancelled there, after the rollback has run under Eio.Cancel.protect. *)
                let exception_detail = Printexc.to_string exn in
                let rollback_error =
                  Eio.Cancel.protect (fun () ->
                    match rollback with
                    | Retain_registered -> None
                    | Remove_registered | Restore_previous _ ->
                      (match reject_for_rollback reg with
                       | Error detail -> Some detail
                       | Ok () ->
                         (match rollback_registry rollback token reg with
                          | Ok () -> None
                          | Error detail -> Some detail)))
                in
                (match exn with
                 | Eio.Cancel.Cancelled _ -> raise exn
                 | _ -> Error (Launch_failed { exception_detail; rollback_error }))))
  in
  match intake_token with
  | Some token ->
    if
      Keeper_shutdown_intake_fence.intake_token_matches
        token
        ~base_path
        ~keeper_name
    then run_admitted token
    else Error Intake_token_not_live
  | None ->
    (match
       Keeper_shutdown_intake_fence.run_durable_intake_observing
         ~base_path
         ~keeper_name
         run_admitted
     with
     | result, None -> result
     | result, Some operation_id ->
       (* Observed, not obeyed: a reservation left by a shutdown that never
          finalised would otherwise refuse every launch for as long as the
          process lives (#29566). *)
       Log.Keeper.warn
         "keepalive lane launched while a shutdown reservation stood: \
          keeper=%s operation=%s"
         keeper_name
         (Keeper_shutdown_types.Operation_id.to_string operation_id);
       result)
;;

let terminalize_safely terminalize =
  try terminalize () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printexc.to_string exn)
;;

let finish_lifecycle ~terminalize =
  (* Exit settlement commonly runs after the lane has observed cancellation.
     Keep the terminal publication outside that cancelled context; otherwise
     its first suspension can raise immediately and the lane cleanup may
     reinterpret a graceful stop as an unexpected abort. *)
  Eio.Cancel.protect (fun () ->
    try terminalize_safely terminalize with
    | exn -> Error (Printexc.to_string exn))
;;
