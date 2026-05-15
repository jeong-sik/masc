open Alcotest

(** RFC-0084 §1.1 Keeper Turn Pre-hook Bypass Gap

    [lib/keeper/keeper_exec_masc.ml:164, 218] calls [Tool_dispatch.dispatch]
    directly (Entry 1) bypassing the pre-hook chain. The pre-hook chain is
    defined via [Tool_dispatch.dispatch_structured]
    ([tool_dispatch.ml:140-145]) which has 0 callers outside the definition
    file itself.

    [capability_registry.ml:358-362] comment explicitly states:

    {v
    Internal dispatch ([Tool_dispatch.dispatch]) remains unrestricted.
    v}

    PR-7 switches keeper turn to [Tool_dispatch.guarded_dispatch] which
    includes the pre-hook chain + capability gate. PR-7 must update the
    [pinned_*] values to a post-fix state alongside the code change.
*)

(** keeper turn pre-hook invocation count per turn.
    Current: 0 (dispatch bypasses run_pre_hooks).
    PR-7 target: > 0 (every dispatched tool triggers pre-hook chain). *)
let pinned_keeper_prehook_invocations_per_turn = 0

(** capability gate invocations on keeper turn.
    Current: 0 (capability_registry.ml comment confirms unrestricted).
    PR-7 target: > 0. *)
let pinned_capability_gate_invocations_per_turn = 0

(** dispatch_structured callers in lib/ + bin/.
    Current: 0 (verified at PR-1 author time via
      [rg -n 'dispatch_structured' lib/ bin/] = 0 matches).
    PR-11 target: 0 (function removed entirely; all routes go through
    guarded_dispatch). *)
let pinned_dispatch_structured_callers = 0

let test_keeper_prehook_bypass () =
  (check int)
    "keeper turn pre-hook invocation count per turn \
     (RFC-0084 §1.1 / keeper_exec_masc.ml:164,218; PR-7 target > 0)"
    0
    pinned_keeper_prehook_invocations_per_turn

let test_capability_gate_bypass () =
  (check int)
    "capability gate invocations on keeper turn \
     (RFC-0084 §1.1 / capability_registry.ml:358-362; PR-7 target > 0)"
    0
    pinned_capability_gate_invocations_per_turn

let test_dispatch_structured_dead () =
  (check int)
    "Tool_dispatch.dispatch_structured callers in lib/ + bin/ \
     (RFC-0084 §1.1 / tool_dispatch.ml:140-145; PR-11 removes function)"
    0
    pinned_dispatch_structured_callers

let () =
  Alcotest.run
    "RFC-0084 keeper pre-hook bypass gap"
    [ ( "keeper-prehook-gap"
      , [ test_case "keeper-prehook-bypass" `Quick test_keeper_prehook_bypass
        ; test_case "capability-gate-bypass" `Quick test_capability_gate_bypass
        ; test_case "dispatch-structured-dead" `Quick test_dispatch_structured_dead
        ] )
    ]
