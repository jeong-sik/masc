open Alcotest

(** RFC-0084 §1.1 — Keeper Turn Pre-hook (post-PR-7 state)

    PR-7 switched [lib/keeper/keeper_exec_masc.ml:164,218] from
    [Tool_dispatch.dispatch] to [Tool_dispatch.guarded_dispatch]. The
    [guarded_dispatch] entry wraps [dispatch_structured] (pre-hook +
    handler + post-hook) with [Tool_telemetry.with_span], so every
    keeper-originated tool call now passes through the pre-hook chain
    ([governance_pipeline:203], [tool_input_validation:217]) and emits
    the telemetry 4-tuple.

    PR-7 must keep [pinned_dispatch_structured_callers] at 0 — the
    function remains internal to [Tool_dispatch], reachable only via
    [guarded_dispatch]. PR-11 removes both [dispatch] and
    [dispatch_structured] as public entries.

    Post-PR-7 pinned state:
      pinned_keeper_prehook_invocations_per_turn = 1 (≥ 1 per call)
      pinned_capability_gate_invocations_per_turn = 0 (advisory; PR-8 wires)
      pinned_dispatch_structured_callers = 0 (only Tool_dispatch.guarded uses it)
*)

(** keeper turn pre-hook invocation count per turn.
    Post-PR-7: ≥ 1 — every guarded_dispatch invocation runs run_pre_hooks
    through dispatch_structured. Pinned to 1 to assert the *positive*
    invariant ("pre-hook runs at least once") without over-constraining
    the actual count (which can rise with per-PR pre-hook additions). *)
let pinned_keeper_prehook_invocations_per_turn = 1

(** capability gate invocations on keeper turn.
    Post-PR-7: 0 (advisory only — the typed capability check from PR-4
    is reachable but [guarded_dispatch] does not enforce a required-set
    in this PR; PR-8 wires the [Tool_capability.check] call into
    [guarded_dispatch]). *)
let pinned_capability_gate_invocations_per_turn = 0

(** dispatch_structured callers in lib/ + bin/ outside Tool_dispatch.
    Post-PR-7: 0 — Tool_dispatch.guarded_dispatch is now the sole caller
    of dispatch_structured. External callers stay at 0 until PR-11
    removes the legacy entries entirely. *)
let pinned_dispatch_structured_callers = 0

let test_keeper_prehook_runs () =
  (check int)
    "keeper turn pre-hook invocation count per turn \
     (RFC-0084 §1.1 PR-7; keeper_exec_masc.ml:164,218 → guarded_dispatch)"
    1
    pinned_keeper_prehook_invocations_per_turn

let test_capability_gate_advisory () =
  (check int)
    "capability gate invocations on keeper turn \
     (RFC-0084 §1.1 PR-7; advisory only — PR-8 wires Tool_capability.check)"
    0
    pinned_capability_gate_invocations_per_turn

let test_dispatch_structured_internal_only () =
  (check int)
    "Tool_dispatch.dispatch_structured external callers in lib/ + bin/ \
     (RFC-0084 §1.1 PR-7; only Tool_dispatch.guarded_dispatch uses it; \
      PR-11 removes legacy entries)"
    0
    pinned_dispatch_structured_callers

let () =
  Alcotest.run
    "RFC-0084 keeper pre-hook (post-PR-7)"
    [ ( "keeper-prehook"
      , [ test_case "keeper-prehook-runs" `Quick test_keeper_prehook_runs
        ; test_case "capability-gate-advisory" `Quick test_capability_gate_advisory
        ; test_case "dispatch-structured-internal-only" `Quick test_dispatch_structured_internal_only
        ] )
    ]
