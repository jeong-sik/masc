(** Observation-only tests for [Keeper_fd_pressure]. *)

open Alcotest

module FD = Keeper_fd_pressure

let member_int name fields =
  match List.assoc_opt name fields with
  | Some (`Int value) -> value
  | Some json -> failf "%s expected int, got %s" name (Yojson.Safe.to_string json)
  | None -> failf "%s missing" name
;;

let test_typed_fd_errors_are_observed () =
  FD.reset_for_tests ();
  FD.note_exception
    ~site:"test.process"
    (Unix.Unix_error (Unix.EMFILE, "open", "fixture"));
  FD.note_exception
    ~site:"test.system"
    (Unix.Unix_error (Unix.ENFILE, "open", "fixture"));
  let fields = FD.projection_fields () in
  check int "process error count" 1
    (member_int "process_fd_exhaustion_observations_total" fields);
  check int "system error count" 1
    (member_int "system_fd_exhaustion_observations_total" fields);
  check string "mode" "observation_only"
    (match List.assoc "mode" fields with
     | `String value -> value
     | json -> failf "mode expected string, got %s" (Yojson.Safe.to_string json))
;;

let test_untyped_errors_do_not_become_fd_facts () =
  FD.reset_for_tests ();
  FD.note_exception ~site:"test.untyped" (Failure "too many open files");
  let fields = FD.projection_fields () in
  check int "process error count unchanged" 0
    (member_int "process_fd_exhaustion_observations_total" fields);
  check int "system error count unchanged" 0
    (member_int "system_fd_exhaustion_observations_total" fields)
;;

let test_external_signal_is_telemetry_only () =
  FD.reset_for_tests ();
  let ts = 1234.5 in
  FD.engage_external ~reason:"host observer fixture" ~level:FD.External_warn ~ts ();
  FD.engage_external ~reason:"same persisted signal" ~level:FD.External_warn ~ts ();
  let fields = FD.projection_fields () in
  check int "exact duplicate counted once" 1 (member_int "external_warn_total" fields);
  check int "crit signal count" 0 (member_int "external_crit_total" fields);
  check (float 0.0) "signal timestamp" ts
    (match List.assoc "last_external_signal_ts" fields with
     | `Float value -> value
     | json -> failf "timestamp expected float, got %s" (Yojson.Safe.to_string json))
;;

let test_runtime_state_contains_facts_not_admission () =
  FD.reset_for_tests ();
  let json =
    FD.runtime_state_json
      ~soft_limit:(Some 256)
      ~open_fds:(Some 16)
      ~system_fds:
        (Some
           { FD.open_files = 1024
           ; max_files = 1_000_000
           ; max_files_per_process = None
           })
      ~active_keepers:24
      ()
  in
  let open Yojson.Safe.Util in
  check string "mode" "observation_only" (json |> member "mode" |> to_string);
  check int "active keeper observation" 24 (json |> member "active_keepers" |> to_int);
  check int "nofile soft limit" 256 (json |> member "nofile_soft_limit" |> to_int);
  check int "open FDs" 16 (json |> member "process_open_fds" |> to_int);
  check int "exact remaining FDs" 240 (json |> member "process_remaining_fds" |> to_int);
  check bool "no admission decision" true (json |> member "admission_decision" = `Null);
  check bool "no projected FD cost" true (json |> member "projected_fds" = `Null);
  check bool "no operator block" true (json |> member "operator_action_required" = `Null)
;;

let test_nofile_cache_single_flight () =
  FD.reset_for_tests ();
  Eio_main.run
  @@ fun _env ->
  let results = Atomic.make [] in
  Eio.Switch.run
  @@ fun sw ->
  let promises =
    List.init 16 (fun _ ->
      Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Fiber.yield ();
        let result = FD.process_nofile_soft_limit () in
        let rec push () =
          let current = Atomic.get results in
          if not (Atomic.compare_and_set results current (result :: current))
          then push ()
        in
        push ()))
  in
  List.iter Eio.Promise.await_exn promises;
  let observed = Atomic.get results in
  check int "all readers completed" 16 (List.length observed);
  (match observed with
   | [] -> fail "no nofile observations"
   | first :: rest ->
     List.iter (fun value -> check bool "cache coherent" true (value = first)) rest);
  (match Atomic.get FD.nofile_soft_limit_cache with
   | FD.Resolved _ -> ()
   | FD.Uninitialized | FD.In_flight -> fail "nofile cache did not resolve")
;;

let test_concurrent_system_observations_return () =
  FD.reset_for_tests ();
  Eio_main.run
  @@ fun _env ->
  Eio_guard.enable ();
  Fun.protect
    ~finally:(fun () ->
      FD.reset_for_tests ();
      Eio_guard.disable ())
    (fun () ->
      Eio.Switch.run
      @@ fun sw ->
      let promises =
        List.init 8 (fun _ ->
          Eio.Fiber.fork_promise ~sw (fun () -> FD.system_fd_snapshot ()))
      in
      check int "all system observations returned" 8
        (List.length (List.map Eio.Promise.await_exn promises)))
;;

let () =
  run
    "keeper_fd_pressure_observation"
    [ ( "typed errors"
      , [ test_case "EMFILE and ENFILE" `Quick test_typed_fd_errors_are_observed
        ; test_case "untyped text is ignored" `Quick test_untyped_errors_do_not_become_fd_facts
        ] )
    ; "external signal", [ test_case "telemetry only" `Quick test_external_signal_is_telemetry_only ]
    ; "runtime state", [ test_case "facts without admission" `Quick test_runtime_state_contains_facts_not_admission ]
    ; "nofile probe", [ test_case "single flight" `Quick test_nofile_cache_single_flight ]
    ; "system probe", [ test_case "concurrent observations" `Quick test_concurrent_system_observations_return ]
    ]
;;
