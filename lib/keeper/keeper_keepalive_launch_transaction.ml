type 'registration_error error =
  | Shutdown_reserved of Keeper_shutdown_types.Operation_id.t
  | Intake_token_not_live
  | Reservation_unavailable of Keeper_lifecycle_reservation.snapshot
  | Registration_failed of 'registration_error
  | Lifecycle_open_failed of
      { error : Keeper_memory_lane.lifecycle_open_error
      ; rollback_error : string option
      }
  | Launch_failed of
      { exception_detail : string
      ; librarian_abort_error : string option
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
  let abort_open_lifecycle () =
    match Keeper_memory_lane.abort_librarian ~base_path ~keeper_name with
    | Ok Keeper_memory_lane.Librarian_abort_idle
    | Ok Keeper_memory_lane.Librarian_abort_requested
    | Ok Keeper_memory_lane.Librarian_abort_already_in_progress
    | Ok (Keeper_memory_lane.Librarian_abort_already_exited _) -> None
    | Ok (Keeper_memory_lane.Librarian_abort_committed_with_failure exn) ->
      Some
        ("Librarian cancellation committed with callback failure: "
         ^ Printexc.to_string exn)
    | Error error ->
      Some (Keeper_memory_lane.librarian_abort_error_to_string error)
  in
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
             (match
                Keeper_memory_lane.begin_librarian_lifecycle
                  ~base_path
                  ~keeper_name
              with
              | Error error ->
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
                Error (Lifecycle_open_failed { error; rollback_error })
              | Ok () ->
                (try
                   Ok (launch intake_token token reg)
                 with
                 | exn ->
                   let exception_detail = Printexc.to_string exn in
                   let librarian_abort_error, rollback_error =
                     Eio.Cancel.protect (fun () ->
                       match rollback with
                       | Retain_registered ->
                         (* Retain the registry authority in both cases, but a
                            pre-start callback failure owns no live fiber that
                            can settle the Librarian lifecycle. Close that
                            lifecycle so the exact Offline lane is retryable.
                            A started lane keeps terminal cleanup ownership. *)
                         if Keeper_lane.crossed_start_boundary reg.lane
                         then None, None
                         else abort_open_lifecycle (), None
                       | Remove_registered | Restore_previous _ ->
                         (match reject_for_rollback reg with
                          | Error detail -> None, Some detail
                          | Ok () ->
                            let librarian_abort_error = abort_open_lifecycle () in
                            let rollback_error =
                              match rollback_registry rollback token reg with
                              | Ok () -> None
                              | Error detail -> Some detail
                            in
                            librarian_abort_error, rollback_error))
                   in
                   (match exn with
                    | Eio.Cancel.Cancelled _ -> raise exn
                    | _ ->
                      Error
                        (Launch_failed
                           { exception_detail
                           ; librarian_abort_error
                           ; rollback_error
                           })))))
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
       Keeper_shutdown_intake_fence.run_durable_intake_if_open
         ~base_path
         ~keeper_name
         run_admitted
     with
     | Keeper_shutdown_intake_fence.Intake_committed result -> result
     | Keeper_shutdown_intake_fence.Intake_shutdown_reserved operation_id ->
       Error (Shutdown_reserved operation_id))
;;

type exit_boundary =
  | Graceful
  | Unexpected

let terminalize_safely terminalize =
  try terminalize () with
  | exn -> Error (Printexc.to_string exn)
;;

let abort_result ~base_path ~keeper_name =
  match Keeper_memory_lane.abort_librarian ~base_path ~keeper_name with
  | Ok Keeper_memory_lane.Librarian_abort_idle
  | Ok Keeper_memory_lane.Librarian_abort_requested
  | Ok Keeper_memory_lane.Librarian_abort_already_in_progress
  | Ok (Keeper_memory_lane.Librarian_abort_already_exited _) -> Ok ()
  | Ok (Keeper_memory_lane.Librarian_abort_committed_with_failure exn) ->
    Error
      ("Librarian cancellation committed with callback failure: "
       ^ Printexc.to_string exn)
  | Error error ->
    Error (Keeper_memory_lane.librarian_abort_error_to_string error)
;;

let drain_result ~base_path ~keeper_name =
  match Keeper_memory_lane.drain_and_join_librarian ~base_path ~keeper_name with
  | Ok Keeper_memory_lane.No_librarian_work
  | Ok Keeper_memory_lane.Librarian_drained -> Ok ()
  | Error error ->
    Error (Keeper_memory_lane.librarian_drain_error_to_string error)
;;

let combine first_label first second_label second =
  match first, second with
  | Ok (), Ok () -> Ok ()
  | Error detail, Ok () -> Error (first_label ^ " failed: " ^ detail)
  | Ok (), Error detail -> Error (second_label ^ " failed: " ^ detail)
  | Error first_detail, Error second_detail ->
    Error
      (first_label ^ " failed: " ^ first_detail ^ "; " ^ second_label
       ^ " failed: " ^ second_detail)
;;

let finish_lifecycle ~boundary ~base_path ~keeper_name ~terminalize =
  (* Exit settlement commonly runs after the lane has observed cancellation.
     Keep the ordered Librarian/terminal transaction outside that cancelled
     context; otherwise the first drain/abort suspension can raise immediately
     and the lane cleanup may reinterpret a graceful stop as an unexpected
     abort. *)
  Eio.Cancel.protect (fun () ->
    try
      match boundary with
      | Graceful ->
        let librarian = drain_result ~base_path ~keeper_name in
        let terminal = terminalize_safely terminalize in
        combine "Librarian cleanup" librarian "terminal cleanup" terminal
      | Unexpected ->
        let librarian = abort_result ~base_path ~keeper_name in
        (* Fence this lifecycle's Librarian intake before publishing a terminal
           state that may admit its replacement. A name-only abort after
           publication could otherwise close the newly reopened lifecycle. *)
        let terminal = terminalize_safely terminalize in
        combine "Librarian cleanup" librarian "terminal cleanup" terminal
    with
    | exn -> Error (Printexc.to_string exn))
;;
