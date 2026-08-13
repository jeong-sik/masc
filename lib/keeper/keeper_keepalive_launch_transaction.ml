type 'registration_error error =
  | Reservation_unavailable of Keeper_lifecycle_reservation.snapshot
  | Registration_failed of 'registration_error
  | Lifecycle_open_failed of
      { error : Keeper_memory_lane.lifecycle_open_error
      ; rollback_error : string option
      }

let release_owned token =
  match Keeper_lifecycle_reservation.release token with
  | Keeper_lifecycle_reservation.Released -> ()
  | outcome ->
    Log.Keeper.warn
      "keepalive launch lifecycle reservation release was not clean: %s"
      (Keeper_lifecycle_reservation.release_outcome_to_string outcome)
;;

let run
      ?lifecycle_token
      ~base_path
      ~keeper_name
      ~expected_generation
      ~register
      ~rollback
      launch
  =
  let ownership =
    match lifecycle_token with
    | Some token -> Ok (token, false)
    | None ->
      (match
         Keeper_lifecycle_reservation.acquire
           ~base_path
           ~keeper_name
           ~expected_generation
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
      ~finally:(fun () -> if owns_token then release_owned token)
      (fun () ->
         match register token with
         | Error error -> Error (Registration_failed error)
         | Ok reg ->
           (match
              Keeper_memory_lane.begin_librarian_lifecycle
                ~base_path
                ~keeper_name
            with
            | Ok () -> Ok (launch token reg)
            | Error error ->
              let rollback_error =
                match rollback token reg with
                | Ok () -> None
                | Error detail -> Some detail
              in
              Error (Lifecycle_open_failed { error; rollback_error })))
;;

let reject_before_start reg =
  match
    Keeper_lane.reject_before_start
      reg.Keeper_registry.lane
      ~reason:(Failure "keepalive launch transaction rolled back")
  with
  | Ok () -> Ok ()
  | Error error -> Error (Keeper_lane.start_error_to_string error)
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

let rollback_remove_registered token reg =
  let lane_result = reject_before_start reg in
  let registry_result = unregister token reg in
  match lane_result, registry_result with
  | Ok (), Ok () -> Ok ()
  | Error detail, Ok () | Ok (), Error detail -> Error detail
  | Error lane_detail, Error registry_detail ->
    Error (lane_detail ^ "; " ^ registry_detail)
;;

let rollback_restore_previous ~previous token reg =
  match rollback_remove_registered token reg with
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
          ^ Keeper_lifecycle_reservation.snapshot_to_string owner))
;;

let rollback_retain_registered _token _reg = Ok ()

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
  match boundary with
  | Graceful ->
    let librarian = drain_result ~base_path ~keeper_name in
    let terminal = terminalize_safely terminalize in
    combine "Librarian cleanup" librarian "terminal cleanup" terminal
  | Unexpected ->
    let terminal = terminalize_safely terminalize in
    let librarian = abort_result ~base_path ~keeper_name in
    combine "terminal cleanup" terminal "Librarian cleanup" librarian
;;
