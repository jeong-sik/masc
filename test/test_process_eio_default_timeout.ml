(** Pin {!Process_eio.default_timeout_sec} at the pre-extraction
    literal [60.0]. Eleven public APIs (run_argv*, run_unix_argv*_
    fallback, with_unix_capture) used to share a hardcoded [60.0]
    default in their [?timeout_sec] parameter. The literals were
    consolidated into one module-level constant so operators can
    override fleet-wide via [MASC_PROCESS_DEFAULT_TIMEOUT_SEC] without
    a rebuild.

    Properties pinned:

    1. Default value preserves the pre-extraction literal [60.0]
       (regression guard against silent budget shifts).
    2. Floor 1.0 prevents degenerate operator config (sub-second
       budgets cannot capture any subprocess startup).

    The env-override behavior itself isn't tested here because the
    constant is read at module load — proving it requires a subprocess
    or [reset_for_testing] hook. The default-pin test is sufficient to
    catch any future refactor that flips the default. *)

open Alcotest

let test_default_value () =
  check (float 0.001)
    "Process_eio.default_timeout_sec default (was inline 60.0)"
    60.0 Process_eio.default_timeout_sec

let test_floor_documented () =
  check bool
    "default value satisfies the documented >=1.0 floor"
    true
    (Process_eio.default_timeout_sec >= 1.0)

let () =
  run "process_eio_default_timeout"
    [
      ( "default preserves pre-extraction literal",
        [
          test_case "default = 60.0" `Quick test_default_value;
          test_case "default >= 1.0 (floor)" `Quick test_floor_documented;
        ] );
    ]
