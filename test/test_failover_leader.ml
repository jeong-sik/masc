open Alcotest

module Cp = Masc_mcp.Cp_lifecycle_policy
module Cp_types = Masc_mcp.Cp_types

let make_detachment ?(leader = None) ~id roster : Cp_types.detachment_record =
  { detachment_id = id; operation_id = "op-1"; assigned_unit_id = "u-1";
    leader_id = leader; roster; session_id = None; checkpoint_ref = None;
    runtime_kind = None; runtime_ref = None; source = "test"; status = Cp_types.Det_active;
    last_event_at = None; last_progress_at = None; heartbeat_deadline = None;
    created_at = "2026-01-01T00:00:00Z"; updated_at = "2026-01-01T00:00:00Z" }

let test_deterministic () =
  let d = make_detachment ~id:"det-1" ["alice"; "bob"; "carol"] in
  let live = ["alice"; "bob"; "carol"] in
  let r1 = Cp.pick_failover_leader live d in
  let r2 = Cp.pick_failover_leader live d in
  check (option string) "same inputs same output" r1 r2

let test_excludes_current_leader () =
  let d = make_detachment ~id:"det-2" ~leader:(Some "alice") ["alice"; "bob"] in
  let live = ["alice"; "bob"] in
  check (option string) "picks non-leader" (Some "bob")
    (Cp.pick_failover_leader live d)

let test_empty_eligible () =
  let d = make_detachment ~id:"det-3" ~leader:(Some "alice") ["alice"] in
  let live = ["alice"] in
  check (option string) "none when only leader" None
    (Cp.pick_failover_leader live d)

let test_roster_order_irrelevant () =
  let d1 = make_detachment ~id:"det-4" ["bob"; "alice"; "carol"] in
  let d2 = make_detachment ~id:"det-4" ["carol"; "alice"; "bob"] in
  let live = ["alice"; "bob"; "carol"] in
  check (option string) "order does not affect result"
    (Cp.pick_failover_leader live d1)
    (Cp.pick_failover_leader live d2)

let () =
  run "pick_failover_leader"
    [ "failover",
      [ test_case "deterministic" `Quick test_deterministic;
        test_case "excludes current leader" `Quick test_excludes_current_leader;
        test_case "empty eligible returns none" `Quick test_empty_eligible;
        test_case "roster order irrelevant" `Quick test_roster_order_irrelevant;
      ] ]
