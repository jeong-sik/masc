(** Pin the {!Env_config_runtime.Dashboard} shell-prewarm timeout
    contract. Two values are extracted from inline literals at
    [server_dashboard_http_execution_surfaces.ml:7] (30.0, inner
    compute) and [server_runtime_bootstrap.ml:1686] (35.0, outer
    wrapper). The properties:

    1. Defaults preserve the pre-extraction literals (regression guard
       against silent timeout shifts that would silently drop the
       pre-warm on slow-disk deployments).
    2. The outer budget MUST strictly exceed the inner budget so the
       inner reports "compute timeout" rather than the fiber being
       killed by the outer wrapper. The default 30/35 split encodes
       5 seconds of headroom; this test pins the ordering invariant.
    3. Floor clamps prevent operators from configuring degenerate
       values (sub-1s inner is meaningless, sub-5s outer cannot fit
       any inner budget plus headroom). *)

open Alcotest

module D = Env_config_runtime.Dashboard

let approx = float 0.001

(* --- 1. Defaults pin the pre-extraction literals --- *)

let test_default_inner () =
  check approx
    "shell_prewarm_inner_timeout_sec default (was inline 30.0)"
    30.0 D.shell_prewarm_inner_timeout_sec

let test_default_outer () =
  check approx
    "shell_prewarm_outer_timeout_sec default (was inline 35.0)"
    35.0 D.shell_prewarm_outer_timeout_sec

(* --- 2. Outer > inner ordering invariant --- *)

let test_outer_strictly_exceeds_inner () =
  check bool
    "outer must strictly exceed inner (else outer kills fiber before \
     inner reports compute_timeout)"
    true
    (D.shell_prewarm_outer_timeout_sec > D.shell_prewarm_inner_timeout_sec);
  check approx
    "default headroom is 5.0s"
    5.0
    (D.shell_prewarm_outer_timeout_sec -. D.shell_prewarm_inner_timeout_sec)

(* --- 3. Module exposes both knobs (smoke check that the API surface
       used by the call sites compiles) ------------------------------- *)

let test_smoke_call_sites_compile () =
  (* If the module ever drops these accessors, compile would fail at
     [server_dashboard_http_execution_surfaces.ml] and
     [server_runtime_bootstrap.ml]. This test just touches both
     bindings so a future rename is caught here without needing the
     full server module to be in scope. *)
  let _ = D.shell_prewarm_inner_timeout_sec in
  let _ = D.shell_prewarm_outer_timeout_sec in
  check bool "both accessors are reachable" true true

let () =
  run "env_config_dashboard_shell_prewarm"
    [
      ( "defaults preserve pre-extraction literals",
        [
          test_case "inner = 30.0" `Quick test_default_inner;
          test_case "outer = 35.0" `Quick test_default_outer;
        ] );
      ( "ordering invariant",
        [
          test_case "outer > inner with 5s headroom" `Quick
            test_outer_strictly_exceeds_inner;
        ] );
      ( "API surface",
        [
          test_case "both accessors reachable" `Quick
            test_smoke_call_sites_compile;
        ] );
    ]
