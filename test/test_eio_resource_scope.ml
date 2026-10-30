open Alcotest

module Scope = Fs_compat_test_support.Publication_recovery_for_testing
module Cleanup = Scope.For_testing
module Resource_scope = Fs_compat_internal.Eio_resource_scope

exception Callback_cancelled
exception Release_failed
exception Body_failed

let with_recorded_backtraces f =
  let previous = Printexc.backtrace_status () in
  Printexc.record_backtrace true;
  Fun.protect ~finally:(fun () -> Printexc.record_backtrace previous) f
;;

let check_backtrace_prefix expected observed =
  let length = Printexc.raw_backtrace_length expected in
  check bool "origin has frames" true (length > 0);
  check bool "origin frame prefix retained" true
    (Printexc.raw_backtrace_length observed >= length
     && List.for_all
          (fun index ->
             Printexc.get_raw_backtrace_slot expected index
             = Printexc.get_raw_backtrace_slot observed index)
          (List.init length Fun.id))
;;

let returned_scope_value (outcome : 'a Resource_scope.t) =
  match outcome.callback with
  | Some (Resource_scope.Returned value) -> value
  | Some (Resource_scope.Cancelled _ | Resource_scope.Raised _) | None ->
    fail "returned callback value was lost"
;;

let test_registered_release_preserves_origin_and_cancellation () =
  with_recorded_backtraces @@ fun () ->
  Eio_main.run @@ fun _ ->
  let origin = Printexc.get_callstack 32 in
  let outcome =
    Resource_scope.run_resource_only @@ fun sw ->
    Resource_scope.on_release sw (fun () ->
      Printexc.raise_with_backtrace Release_failed origin);
    raise (Eio.Cancel.Cancelled Callback_cancelled)
  in
  (match outcome.callback with
   | Some (Resource_scope.Cancelled { reason = Callback_cancelled; _ }) -> ()
   | Some (Resource_scope.Cancelled _) -> fail "callback cancellation changed"
   | Some (Resource_scope.Returned _ | Resource_scope.Raised _) | None ->
     fail "callback cancellation was lost");
  match outcome.scope_failure with
  | Some { exception_ = Release_failed; backtrace } ->
    check_backtrace_prefix origin backtrace
  | Some _ | None -> fail "original release failure was lost"
;;

let test_registered_releases_preserve_multiple_failure_origins () =
  with_recorded_backtraces @@ fun () ->
  Eio_main.run @@ fun _ ->
  let release_origin = Printexc.get_callstack 32 in
  let body_origin = Printexc.get_callstack 32 in
  let outcome =
    Resource_scope.run_resource_only @@ fun sw ->
    Resource_scope.on_release sw (fun () ->
      Printexc.raise_with_backtrace Release_failed release_origin);
    Resource_scope.on_release sw (fun () ->
      Printexc.raise_with_backtrace Body_failed body_origin);
    "completed"
  in
  check string "callback value" "completed" (returned_scope_value outcome);
  match outcome.scope_failure with
  | Some { exception_ = Eio.Exn.Multiple failures; _ } ->
    check int "both failures retained" 2 (List.length failures);
    List.iter
      (function
        | Release_failed, bt -> check_backtrace_prefix release_origin bt
        | Body_failed, bt -> check_backtrace_prefix body_origin bt
        | ex, _ -> failf "unexpected failure: %s" (Printexc.to_string ex))
      failures
  | Some _ | None -> fail "multiple release failures were lost"
;;

let test_actual_file_close_failure_retains_origin () =
  with_recorded_backtraces @@ fun () ->
  let path = Filename.temp_file "masc-resource-close" ".tmp" in
  Fun.protect ~finally:(fun () -> Unix.unlink path) @@ fun () ->
  Eio_main.run @@ fun env ->
  let observed = ref None in
  let descriptor = ref None in
  let close_calls = ref 0 in
  let outcome =
    Resource_scope.run_resource_only @@ fun sw ->
    let file = Eio.Path.open_in ~sw Eio.Path.(Eio.Stdenv.fs env / path) in
    let fd =
      match Eio_unix.Resource.fd_opt file with
      | Some fd -> fd
      | None -> fail "POSIX file did not expose its actual descriptor"
    in
    descriptor := Some fd;
    let observed_file : Eio.Resource.close_ty Eio.Resource.t =
      Eio.Resource.T
        ( file
        , Eio.Resource.handler
            [ Eio.Resource.H
                ( Eio.Resource.Close
                , fun resource ->
                    incr close_calls;
                    match Eio.Resource.close resource with
                    | () -> ()
                    | exception exception_ ->
                      let backtrace = Printexc.get_raw_backtrace () in
                      observed := Some (exception_, backtrace);
                      Printexc.raise_with_backtrace exception_ backtrace )
            ] )
    in
    Resource_scope.track_close ~sw observed_file;
    (* Invalidate the real POSIX descriptor so the actual close implementation
       raises EBADF. Its original switch hook must be disabled before failure. *)
    Eio_unix.Fd.use_exn "inject failed close" fd Unix.close;
    "completed"
  in
  check string "callback value" "completed" (returned_scope_value outcome);
  match outcome.scope_failure, !observed, !descriptor with
  | Some failure, Some (exception_, backtrace), Some fd ->
    (match exception_ with
     | Unix.Unix_error (error, operation, _) ->
       check bool "actual EBADF" true (error = Unix.EBADF);
       check string "actual failed operation" "close" operation
     | other -> failf "not an actual POSIX close failure: %s"
         (Printexc.to_string other));
    check bool "same actual close exception" true
      (failure.exception_ == exception_);
    check_backtrace_prefix backtrace failure.backtrace;
    check bool "descriptor marked closed despite failed close" false
      (Eio_unix.Fd.is_open fd);
    check int "tracked close invoked once" 1 !close_calls
  | _ -> fail "actual file close failure or callback value was lost"
;;

let test_tracked_file_early_close_is_safe () =
  let path = Filename.temp_file "masc-resource-early-close" ".tmp" in
  Fun.protect ~finally:(fun () -> Unix.unlink path) @@ fun () ->
  Eio_main.run @@ fun env ->
  let outcome =
    Resource_scope.run_resource_only @@ fun sw ->
    let file = Eio.Path.open_in ~sw Eio.Path.(Eio.Stdenv.fs env / path) in
    Resource_scope.track_close ~sw file;
    Eio.Resource.close file;
    "completed"
  in
  check string "callback value" "completed" (returned_scope_value outcome);
  match outcome.scope_failure with
  | None -> ()
  | Some _ -> fail "tracking an already closed file introduced a release failure"
;;

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
            "registered release preserves origin and callback cancellation"
            `Quick
            test_registered_release_preserves_origin_and_cancellation
        ; test_case
            "multiple release failures retain their own origins"
            `Quick
            test_registered_releases_preserve_multiple_failure_origins
        ; test_case
            "actual POSIX close failure retains its origin"
            `Quick
            test_actual_file_close_failure_retains_origin
        ; test_case
            "tracked file supports explicit early close"
            `Quick
            test_tracked_file_early_close_is_safe
        ; test_case
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
