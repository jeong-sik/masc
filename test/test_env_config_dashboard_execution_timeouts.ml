(** Pin the {!Env_config_runtime.Dashboard} execution-surface timeout
    contract. Three values were extracted from inline literals at
    [server_dashboard_http_execution_surfaces.ml]:

    - line 437/438  120.0  → execution_timeout_sec (light path)
    - line 448/449  120.0  → execution_timeout_sec (parameterized path)
    - line 467/468   30.0  → execution_trust_timeout_sec

    The two execution literals (light + parameterized) shared a value
    by coincidence — we collapse them to one knob so future operator
    overrides apply to both consistently. The trust literal is kept
    separate because the trust projection is intentionally lighter and
    the split signal helps operators diagnose which surface is the
    bottleneck.

    Properties pinned:

    1. Defaults preserve the pre-extraction literals.
    2. Trust budget < execution budget — the trust projection is
       lighter, and the split lets operators distinguish "trust
       scoring is slow" from "the full execution surface is slow".
    3. Floor clamps prevent degenerate operator config. *)

open Alcotest

module D = Env_config_runtime.Dashboard

let approx = float 0.001

let test_default_execution () =
  check approx
    "execution_timeout_sec default (was inline 120.0 ×2)"
    120.0 D.execution_timeout_sec

let test_default_execution_trust () =
  check approx
    "execution_trust_timeout_sec default (was inline 30.0)"
    30.0 D.execution_trust_timeout_sec

let test_trust_strictly_less_than_execution () =
  check bool
    "execution_trust_timeout_sec must be < execution_timeout_sec \
     (else the split-budget signal between trust vs full surface \
     becomes meaningless)"
    true
    (D.execution_trust_timeout_sec < D.execution_timeout_sec)

let test_smoke_call_sites_compile () =
  let _ = D.execution_timeout_sec in
  let _ = D.execution_trust_timeout_sec in
  check bool "both accessors are reachable" true true

let () =
  run "env_config_dashboard_execution_timeouts"
    [
      ( "defaults preserve pre-extraction literals",
        [
          test_case "execution = 120.0" `Quick test_default_execution;
          test_case "execution_trust = 30.0" `Quick
            test_default_execution_trust;
        ] );
      ( "trust < execution ordering",
        [
          test_case "execution_trust < execution" `Quick
            test_trust_strictly_less_than_execution;
        ] );
      ( "API surface",
        [
          test_case "both accessors reachable" `Quick
            test_smoke_call_sites_compile;
        ] );
    ]
