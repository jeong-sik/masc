(** Observation-only contract tests for [Fd_accountant]. *)

open Alcotest

module FA = Fd_accountant

let observer_calls = Atomic.make 0
let observer_should_raise = Atomic.make false

let install_test_observers () =
  FA.install_observers
    ~nofile_soft_limit:(fun () -> Some 4242)
    ~on_resource_error:(fun ~kind:_ _error _exn ->
      Atomic.incr observer_calls;
      if Atomic.get observer_should_raise
      then raise (Failure "synthetic observer failure"))
;;

let active kind = FA.active_count ~kind

let test_kind_round_trip () =
  List.iter
    (fun kind ->
      let encoded = FA.kind_to_string kind in
      check
        (option string)
        "kind round-trip"
        (Some encoded)
        (Option.map FA.kind_to_string (FA.kind_of_string encoded)))
    FA.all_kinds
;;

let test_unknown_kind_rejected () =
  check bool "unknown kind" true (Option.is_none (FA.kind_of_string "carrier_pigeon"))
;;

let test_observe_returns_and_releases () =
  let result =
    FA.observe ~kind:Provider_http (fun () ->
      check int "active inside callback" 1 (active Provider_http);
      42)
  in
  check int "callback result" 42 result;
  check int "released after return" 0 (active Provider_http)
;;

let test_nested_observations_count_every_scope () =
  FA.observe ~kind:Sandbox_exec (fun () ->
    check int "outer observation" 1 (active Sandbox_exec);
    FA.observe ~kind:Sandbox_exec (fun () ->
      check int "nested observation" 2 (active Sandbox_exec)));
  check int "nested observations released" 0 (active Sandbox_exec)
;;

let test_exception_releases () =
  let raised =
    match
      FA.observe ~kind:Provider_cli (fun () -> raise (Failure "callback failure"))
    with
    | _ -> false
    | exception Failure message when String.equal message "callback failure" -> true
    | exception _ -> false
  in
  check bool "original callback exception" true raised;
  check int "released after exception" 0 (active Provider_cli)
;;

let wait_until ~clock ~attempts predicate =
  let rec loop remaining =
    if predicate ()
    then true
    else if remaining = 0
    then false
    else (
      Eio.Fiber.yield ();
      Eio.Time.sleep clock 0.001;
      loop (remaining - 1))
  in
  loop attempts
;;

let test_concurrent_observations_are_not_capped () =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let entered = Atomic.make 0 in
  let release, release_resolver = Eio.Promise.create () in
  Eio.Switch.run
  @@ fun sw ->
  for _ = 1 to 4 do
    Eio.Fiber.fork ~sw (fun () ->
      FA.observe ~kind:Docker_spawn (fun () ->
        Atomic.incr entered;
        Eio.Promise.await release))
  done;
  let all_entered = wait_until ~clock ~attempts:100 (fun () -> Atomic.get entered = 4) in
  check bool "all callbacks entered without admission" true all_entered;
  check int "all callbacks observed concurrently" 4 (active Docker_spawn);
  Eio.Promise.resolve release_resolver ();
  check bool "all concurrent observations released" true
    (wait_until ~clock ~attempts:100 (fun () -> active Docker_spawn = 0))
;;

let test_lifetime_observation_release_is_idempotent () =
  let release = FA.acquire_lifetime_observation ~kind:Log_writer () in
  check int "lifetime observation active" 1 (active Log_writer);
  release ();
  check int "lifetime observation released" 0 (active Log_writer);
  release ();
  check int "second release is a no-op" 0 (active Log_writer)
;;

let expect_resource_error unix_error expected_error =
  let kind = FA.Provider_http in
  let internal_before = FA.resource_error_count ~kind expected_error in
  let observer_before = Atomic.get observer_calls in
  let raised_original =
    match
      FA.observe ~kind (fun () ->
        raise (Unix.Unix_error (unix_error, "open", "fixture")))
    with
    | _ -> false
    | exception Unix.Unix_error (actual, function_name, argument)
      when actual = unix_error
           && String.equal function_name "open"
           && String.equal argument "fixture" -> true
    | exception _ -> false
  in
  check bool "typed Unix error re-raised unchanged" true raised_original;
  check
    int
    "internal error telemetry increments"
    (internal_before + 1)
    (FA.resource_error_count ~kind expected_error);
  check int "external observer invoked" (observer_before + 1) (Atomic.get observer_calls)
;;

let test_typed_resource_errors_are_reported () =
  expect_resource_error Unix.EMFILE FA.Process_fd_exhausted;
  expect_resource_error Unix.ENFILE FA.System_fd_exhausted;
  expect_resource_error Unix.ENOSPC FA.Storage_space_exhausted
;;

let test_unrelated_exception_is_not_reported () =
  let before = Atomic.get observer_calls in
  (match FA.observe ~kind:Provider_http (fun () -> raise (Failure "unrelated")) with
   | _ -> fail "unrelated exception should be re-raised"
   | exception Failure message when String.equal message "unrelated" -> ()
   | exception exn -> failf "unexpected exception: %s" (Printexc.to_string exn));
  check int "observer not called" before (Atomic.get observer_calls)
;;

let test_observer_failure_does_not_replace_os_error () =
  Atomic.set observer_should_raise true;
  Fun.protect
    ~finally:(fun () -> Atomic.set observer_should_raise false)
    (fun () ->
      let raised_original =
        match
          FA.observe ~kind:Sandbox_exec (fun () ->
            raise (Unix.Unix_error (Unix.EMFILE, "dup", "fixture")))
        with
        | _ -> false
        | exception Unix.Unix_error (Unix.EMFILE, function_name, argument)
          when String.equal function_name "dup"
               && String.equal argument "fixture" -> true
        | exception _ -> false
      in
      check bool "observer failure preserves original OS error" true raised_original)
;;

let test_snapshot_is_observation_only () =
  let snapshot = FA.fd_snapshot () in
  check int "all kinds present" (List.length FA.all_kinds) (List.length snapshot.per_kind);
  check int "all typed error series present"
    (List.length FA.all_kinds * List.length FA.all_resource_errors)
    (List.length snapshot.resource_errors);
  check (option int) "installed nofile observer" (Some 4242) snapshot.fd_limit;
  List.iter
    (fun (kind, count) ->
      if count < 0
      then failf "negative active count for %s" (FA.kind_to_string kind))
    snapshot.per_kind;
  List.iter
    (fun (kind, error, count) ->
      if count < 0
      then
        failf
          "negative resource error count for %s/%s"
          (FA.kind_to_string kind)
          (FA.resource_error_to_string error))
    snapshot.resource_errors
;;

let test_with_process_observer_wiring () =
  Eio_main.run
  @@ fun _env ->
  Eio_guard.enable ();
  Fun.protect
    ~finally:(fun () ->
      With_process.reset_process_guard_for_testing ();
      Eio_guard.disable ())
    (fun () ->
      With_process.reset_process_guard_for_testing ();
      FA.install_with_process_sandbox_exec_observer ();
      let (observed, lines), status =
        With_process.with_process_args_in
          "/bin/echo"
          [| "/bin/echo"; "fd-observation" |]
          (fun ic -> active Sandbox_exec, With_process.drain_lines ic)
      in
      check int "process callback observed" 1 observed;
      check (list string) "process stdout" [ "fd-observation" ] lines;
      (match status with
       | Unix.WEXITED 0 -> ()
       | _ -> fail "expected process to exit 0");
      check int "process observation released" 0 (active Sandbox_exec))
;;

let () =
  install_test_observers ();
  run
    "Fd_accountant"
    [ ( "typed surface"
      , [ test_case "kind round-trip" `Quick test_kind_round_trip
        ; test_case "unknown kind rejected" `Quick test_unknown_kind_rejected
        ] )
    ; ( "observation semantics"
      , [ test_case "return and release" `Quick test_observe_returns_and_releases
        ; test_case "nested scopes are counted" `Quick test_nested_observations_count_every_scope
        ; test_case "exception releases" `Quick test_exception_releases
        ; test_case "concurrency is not capped" `Quick test_concurrent_observations_are_not_capped
        ; test_case "lifetime release is idempotent" `Quick
            test_lifetime_observation_release_is_idempotent
        ] )
    ; ( "resource errors"
      , [ test_case "typed OS errors are reported" `Quick test_typed_resource_errors_are_reported
        ; test_case "unrelated errors are ignored" `Quick test_unrelated_exception_is_not_reported
        ; test_case "observer failure preserves original" `Quick
            test_observer_failure_does_not_replace_os_error
        ] )
    ; "snapshot", [ test_case "observation-only shape" `Quick test_snapshot_is_observation_only ]
    ; "process wiring", [ test_case "With_process observer" `Quick test_with_process_observer_wiring ]
    ]
;;
