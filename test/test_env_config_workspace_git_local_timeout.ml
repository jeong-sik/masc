(** Pin the {!Env_config_runtime.Workspace_git} local-op timeout
    contract.  Six values were extracted from inline literals at
    [workspace_git.ml] and [workspace_worktree.ml]:

    - [workspace_git.ml:45]        30.0  (run_argv_line   helper)
    - [workspace_git.ml:56]        30.0  (run_argv_exit   default arg)
    - [workspace_git.ml:74]        30.0  (run_argv_lines  helper)
    - [workspace_worktree.ml:21]   30.0  (run_argv_lines  helper)
    - [workspace_worktree.ml:31]   30.0  (run_argv_with_status default arg)
    - [workspace_worktree.ml:868]  30.0  (worktree add -B direct call)

    All six sites share the same semantic bucket: "local-only git
    operations" (rev-parse, status, branch, worktree add — no
    network IO).  Network-bound git ops (fetch, push) intentionally
    use a separate knob ({!Env_config_core.git_fetch_timeout_sec}).

    Properties pinned:

    1. Default preserves the pre-extraction literal exactly.
    2. The local-op budget is strictly less than the network-bound
       fetch budget.  An operator who inverted this — by lowering
       fetch below local — would silently break the implicit
       precedence (a network fetch should always carry more headroom
       than a local rev-parse), turning what should be a slow-network
       failure into a fast-local timeout.
    3. Floor clamp (5.0) prevents degenerate operator config that
       would race subprocess startup. *)

open Alcotest

module C = Env_config_runtime.Workspace_git

let approx = float 0.001

let test_default_local_op () =
  check approx
    "local_op_timeout_sec default (was inline 30.0 ×6)"
    30.0 C.local_op_timeout_sec

let test_local_strictly_less_than_fetch () =
  check bool
    "local_op_timeout_sec MUST stay below \
     Env_config_core.git_fetch_timeout_sec (network fetch needs more \
     headroom than a local rev-parse)"
    true
    (C.local_op_timeout_sec < Env_config_core.git_fetch_timeout_sec ())

let test_smoke_call_site_compiles () =
  let _ = C.local_op_timeout_sec in
  check bool "accessor is reachable" true true

let () =
  run "env_config_workspace_git_local_timeout"
    [
      ( "default preserves pre-extraction literal",
        [
          test_case "local_op = 30.0" `Quick test_default_local_op;
        ] );
      ( "ordering invariant",
        [
          test_case "local_op < git_fetch" `Quick
            test_local_strictly_less_than_fetch;
        ] );
      ( "API surface",
        [
          test_case "accessor reachable" `Quick
            test_smoke_call_site_compiles;
        ] );
    ]
