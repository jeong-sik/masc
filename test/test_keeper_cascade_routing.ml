(** test_keeper_cascade_routing — State-aware cascade profile selection.

    Verifies TLA+ KeeperCoreTriad safety invariants in OCaml:
    - S1: Blocked/non-executable phases still map to base_cascade in the helper;
          actual turn blocking happens upstream in keeper_unified_turn
    - S2: Failing phase selects local_recovery
    - S3: Compacting/HandingOff select local_only
    - Running selects base_cascade unchanged *)

open Alcotest
module Routing = Masc_mcp.Keeper_cascade_routing
module SM = Masc_mcp.Keeper_state_machine

let routing_t = testable
  (Fmt.of_to_string (fun (r : Routing.routing_decision) ->
     Printf.sprintf "{cascade=%s, reason=%s}" r.effective_cascade r.reason))
  (fun a b -> a.effective_cascade = b.effective_cascade)

let base = Masc_mcp.Keeper_config.default_cascade_name

let select phase =
  Routing.select_cascade ~base_cascade:base ~phase

(* ── Phase routing tests (TLA+ mirrored) ──────────────── *)

let test_running_uses_base () =
  let r = select SM.Running in
  check string "Running -> base" base r.effective_cascade

let test_failing_uses_local_recovery () =
  let r = select SM.Failing in
  check string "Failing -> local_recovery"
    Masc_mcp.Keeper_config.local_recovery_cascade_name r.effective_cascade

let test_compacting_uses_local_only () =
  let r = select SM.Compacting in
  check string "Compacting -> local_only"
    Masc_mcp.Keeper_config.local_only_cascade_name r.effective_cascade

let test_handing_off_uses_local_only () =
  let r = select SM.HandingOff in
  check string "HandingOff -> local_only"
    Masc_mcp.Keeper_config.local_only_cascade_name r.effective_cascade

let test_overflowed_uses_base () =
  let r = select SM.Overflowed in
  check string "Overflowed -> base" base r.effective_cascade

let test_draining_uses_base () =
  let r = select SM.Draining in
  check string "Draining -> base" base r.effective_cascade

let test_paused_uses_base () =
  let r = select SM.Paused in
  check string "Paused -> base" base r.effective_cascade

let test_offline_uses_base () =
  let r = select SM.Offline in
  check string "Offline -> base" base r.effective_cascade

let test_stopped_uses_base () =
  let r = select SM.Stopped in
  check string "Stopped -> base" base r.effective_cascade

let test_dead_uses_base () =
  let r = select SM.Dead in
  check string "Dead -> base" base r.effective_cascade

let test_crashed_uses_base () =
  let r = select SM.Crashed in
  check string "Crashed -> base" base r.effective_cascade

let test_restarting_uses_base () =
  let r = select SM.Restarting in
  check string "Restarting -> base" base r.effective_cascade

(* ── Edge cases ───────────────────────────────────────── *)

let test_failing_with_local_only_base () =
  let r = Routing.select_cascade
    ~base_cascade:Masc_mcp.Keeper_config.local_only_cascade_name ~phase:SM.Failing in
  check string "Failing overrides even local_only base"
    Masc_mcp.Keeper_config.local_recovery_cascade_name r.effective_cascade

let test_running_with_custom_base () =
  let r = Routing.select_cascade ~base_cascade:"coding_first" ~phase:SM.Running in
  check string "Running preserves custom base"
    "coding_first" r.effective_cascade

let test_tool_required_turn_preserves_routed_cascade () =
  let r =
    Routing.route_effective_cascade_for_tool_requirement
      ~effective_cascade:"big_three" ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Required
  in
  check string "required tool turns preserve routed cascade"
    "big_three" r.effective_cascade;
  check bool "required tool turns do not rewrite to strict cascade" false
    (String.equal Masc_mcp.Keeper_config.tool_use_strict_cascade_name
       r.effective_cascade)

let test_tool_required_turn_preserves_local_recovery () =
  let r =
    Routing.route_effective_cascade_for_tool_requirement
      ~effective_cascade:Masc_mcp.Keeper_config.local_recovery_cascade_name
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Required
  in
  check string "required tool turns preserve local recovery"
    Masc_mcp.Keeper_config.local_recovery_cascade_name r.effective_cascade

let test_all_phases_have_reason () =
  List.iter (fun phase ->
    let r = Routing.select_cascade ~base_cascade:base ~phase in
    check bool
      (Printf.sprintf "%s has non-empty reason" (SM.phase_to_string phase))
      true
      (String.length r.reason > 0)
  ) SM.all_phases

(* ── Test suite ───────────────────────────────────────── *)

let () =
  run "keeper_cascade_routing" [
    "phase_routing", [
      test_case "Running uses base"       `Quick test_running_uses_base;
      test_case "Failing uses local_recovery" `Quick test_failing_uses_local_recovery;
      test_case "Compacting uses local_only"  `Quick test_compacting_uses_local_only;
      test_case "HandingOff uses local_only"  `Quick test_handing_off_uses_local_only;
      test_case "Overflowed uses base"    `Quick test_overflowed_uses_base;
      test_case "Draining uses base"      `Quick test_draining_uses_base;
      test_case "Paused uses base"        `Quick test_paused_uses_base;
      test_case "Offline uses base"       `Quick test_offline_uses_base;
      test_case "Stopped uses base"       `Quick test_stopped_uses_base;
      test_case "Dead uses base"          `Quick test_dead_uses_base;
      test_case "Crashed uses base"       `Quick test_crashed_uses_base;
      test_case "Restarting uses base"    `Quick test_restarting_uses_base;
    ];
    "edge_cases", [
      test_case "Failing overrides local_only base" `Quick test_failing_with_local_only_base;
      test_case "Running preserves custom base"     `Quick test_running_with_custom_base;
      test_case "Required tool turn preserves routed cascade" `Quick
        test_tool_required_turn_preserves_routed_cascade;
      test_case "Required tool turn preserves local recovery" `Quick
        test_tool_required_turn_preserves_local_recovery;
      test_case "All phases have reason"            `Quick test_all_phases_have_reason;
    ];
  ]
