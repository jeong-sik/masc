open Alcotest

module Scope = Fs_compat_test_support.Publication_recovery_for_testing
module Cleanup = Scope.For_testing

exception Callback_cancelled
exception Release_failed
exception Body_failed

let check_release_failure = function
  | Some Release_failed -> ()
  | Some failure ->
    failf "unexpected release failure: %s" (Printexc.to_string failure)
  | None -> fail "release failure was not retained"
;;

let test_callback_cancellation_precedes_release_failure () =
  Eio_main.run @@ fun _ ->
  let outcome =
    Scope.run_resource_scope
      ~callback:(Scope.Cancel_callback Callback_cancelled)
      ~release_failure:(Some Release_failed)
  in
  (match outcome with
   | Scope.Cancelled_callback
       { reason = Callback_cancelled; release_failure } ->
     check_release_failure release_failure
   | Scope.Cancelled_callback { reason; _ } ->
     failf "unexpected cancellation reason: %s" (Printexc.to_string reason)
   | Scope.Returned_rows _ | Scope.Raised_callback _ ->
     fail "callback cancellation was not retained")
;;

let test_returned_callback_survives_release_failure () =
  Eio_main.run @@ fun _ ->
  let outcome =
    Scope.run_resource_scope
      ~callback:(Scope.Return_completed_rows [ "completed-row" ])
      ~release_failure:(Some Release_failed)
  in
  match outcome with
  | Scope.Returned_rows { completed_rows; release_failure } ->
    check (list string)
      "completed rows retain order"
      [ "completed-row" ]
      completed_rows;
    check_release_failure release_failure
  | Scope.Cancelled_callback _ | Scope.Raised_callback _ ->
    fail "returned callback value was not retained"
;;

let test_lane_cleanup_retains_cancellation_and_release_failure () =
  Eio_main.run @@ fun _ ->
  match
    Cleanup.run_cleanup_boundary
      ~body:(Cleanup.Cancel_cleanup_body Callback_cancelled)
      ~cleanup_failure:(Some Release_failed)
  with
  | Cleanup.Cancellation_primary_with_cleanup_failure
      { body = None
      ; cancellation = { exception_ = Eio.Cancel.Cancelled Callback_cancelled; _ }
      ; cleanup = { exception_ = Release_failed; _ }
      } -> ()
  | Cleanup.Cancellation_primary_with_cleanup_failure
      { body; cancellation; cleanup } ->
    failf
      "wrong typed cleanup evidence: body=%b cancellation=%s cleanup=%s"
      (Option.is_some body)
      (Printexc.to_string cancellation.exception_)
      (Printexc.to_string cleanup.exception_)
  | Cleanup.Cleanup_returned _
  | Cleanup.Cleanup_failed_without_cancellation _
  | Cleanup.Body_failure_during_cancellation _
  | Cleanup.Cancellation_primary _
  | Cleanup.Cleanup_boundary_raised _ ->
    fail "lane cleanup lost cancellation or release evidence"
;;

let test_lane_cleanup_retains_body_and_release_failure () =
  Eio_main.run @@ fun _ ->
  match
    Cleanup.run_cleanup_boundary
      ~body:(Cleanup.Raise_cleanup_body Body_failed)
      ~cleanup_failure:(Some Release_failed)
  with
  | Cleanup.Cleanup_failed_without_cancellation
      { body = Some { exception_ = Body_failed; _ }
      ; cleanup = { exception_ = Release_failed; _ }
      } -> ()
  | Cleanup.Cleanup_failed_without_cancellation { body; cleanup } ->
    failf
      "wrong body/cleanup evidence: body=%s cleanup=%s"
      (match body with
       | None -> "none"
       | Some failure -> Printexc.to_string failure.exception_)
      (Printexc.to_string cleanup.exception_)
  | Cleanup.Cleanup_returned _
  | Cleanup.Cancellation_primary_with_cleanup_failure _
  | Cleanup.Body_failure_during_cancellation _
  | Cleanup.Cancellation_primary _
  | Cleanup.Cleanup_boundary_raised _ ->
    fail "lane cleanup lost body or release evidence"
;;

let () =
  run
    "Eio resource-only scope"
    [ ( "release evidence"
      , [ test_case
            "callback cancellation remains primary"
            `Quick
            test_callback_cancellation_precedes_release_failure
        ; test_case
            "returned callback survives release failure"
            `Quick
            test_returned_callback_survives_release_failure
        ; test_case
            "lane cleanup retains cancellation and release failure"
            `Quick
            test_lane_cleanup_retains_cancellation_and_release_failure
        ; test_case
            "lane cleanup retains body and release failure"
            `Quick
            test_lane_cleanup_retains_body_and_release_failure
        ] )
    ]
;;
