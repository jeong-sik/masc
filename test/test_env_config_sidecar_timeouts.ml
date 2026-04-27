(** Pin the {!Env_config_runtime.Sidecar} subprocess timeout
    contract. Three values were extracted from inline literals at
    [server_routes_http_routes_sidecar.ml]:

    - 780  5.0   → control_command_timeout_sec ([stop])
    - 835  5.0   → control_command_timeout_sec ([tail])
    - 884  10.0  → schema_generation_timeout_sec (Python schema gen)

    The two [5.0] literals shared a value because both drive
    quick housekeeping subprocesses; collapse to one knob. The
    [10.0] is a *different intent* (Python interpreter + schema
    introspection) so it stays a separate accessor.

    Properties pinned:

    1. Defaults preserve pre-extraction literals.
    2. schema_generation > control_command — the schema path is
       strictly heavier (Python startup + introspection); operators
       lowering schema budget below control budget would silently
       reorder the implicit precedence and surprise downstream
       diagnostics ("schema timed out faster than tail?").
    3. Floor 1.0s on both — sub-second budgets cannot capture even
       a trivial sidecar subprocess startup. *)

open Alcotest

module S = Env_config_runtime.Sidecar

let approx = float 0.001

let test_default_control_command () =
  check approx
    "control_command_timeout_sec default (was inline 5.0 ×2)"
    5.0 S.control_command_timeout_sec

let test_default_schema_generation () =
  check approx
    "schema_generation_timeout_sec default (was inline 10.0)"
    10.0 S.schema_generation_timeout_sec

let test_schema_exceeds_control () =
  check bool
    "schema_generation_timeout_sec MUST exceed control_command_timeout_sec \
     (else operator lowering schema budget would reorder implicit precedence)"
    true
    (S.schema_generation_timeout_sec > S.control_command_timeout_sec)

let test_floor () =
  check bool
    "control_command_timeout_sec satisfies the documented >= 1.0 floor"
    true
    (S.control_command_timeout_sec >= 1.0);
  check bool
    "schema_generation_timeout_sec satisfies the documented >= 1.0 floor"
    true
    (S.schema_generation_timeout_sec >= 1.0)

let test_smoke_call_sites_compile () =
  let _ = S.control_command_timeout_sec in
  let _ = S.schema_generation_timeout_sec in
  check bool "both accessors are reachable" true true

let () =
  run "env_config_sidecar_timeouts"
    [
      ( "defaults preserve pre-extraction literals",
        [
          test_case "control_command = 5.0" `Quick test_default_control_command;
          test_case "schema_generation = 10.0" `Quick
            test_default_schema_generation;
        ] );
      ( "ordering invariant",
        [
          test_case "schema > control" `Quick
            test_schema_exceeds_control;
        ] );
      ( "floor",
        [
          test_case ">= 1.0s on both" `Quick test_floor;
        ] );
      ( "API surface",
        [
          test_case "both accessors reachable" `Quick
            test_smoke_call_sites_compile;
        ] );
    ]
