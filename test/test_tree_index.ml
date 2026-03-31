open Masc_mcp
open Command_plane_v2

(* --- Test helpers --- *)

let default_policy =
  {
    policy_class = "standard";
    approval_class = "auto";
    tool_allowlist = [];
    model_allowlist = [];
    requires_human_for = [];
    escalation_timeout_sec = 300;
    kill_switch = false;
    frozen = false;
  }

let default_budget =
  {
    headcount_cap = 10;
    active_operation_cap = 20;
    max_cost_usd = 100.0;
    max_tokens = 100000;
  }

let make_unit ~unit_id ~label ~kind ?parent_unit_id ?(roster = []) () =
  {
    unit_id;
    label;
    kind;
    parent_unit_id;
    leader_id = None;
    roster;
    capability_profile = [];
    policy = default_policy;
    budget = default_budget;
    source = "test";
    created_at = "2026-03-31T12:00:00Z";
    updated_at = "2026-03-31T12:00:00Z";
  }

let make_operation ~operation_id ~assigned_unit_id ~status () =
  {
    operation_id;
    objective = "test";
    intent_id = None;
    assigned_unit_id;
    policy_class = "standard";
    budget_class = "standard";
    workload_template = None;
    workload_profile = "default";
    stage = None;
    artifact_scope = [];
    depends_on_operation_ids = [];
    search_strategy = "default";
    detachment_session_id = None;
    trace_id = "test-trace";
    checkpoint_ref = None;
    active_goal_ids = [];
    note = None;
    created_by = "test";
    source = "test";
    status;
    created_at = "2026-03-31T12:00:00Z";
    updated_at = "2026-03-31T12:00:00Z";
  }

let make_agent ~name ?(status = Types.Active) () : Types.agent =
  {
    name;
    agent_type = "test";
    status;
    capabilities = [];
    current_task = None;
    joined_at = "2026-03-31T12:00:00Z";
    last_seen = "2026-03-31T12:00:00Z";
    meta = None;
  }

(* --- Fixtures --- *)

(* Company -> 2 Platoons -> 2 Squads each -> 2 Agents each = 13 units *)
let fixture_units =
  [
    make_unit ~unit_id:"company-1" ~label:"HQ" ~kind:Company ();
    make_unit ~unit_id:"platoon-1" ~label:"Alpha" ~kind:Platoon
      ~parent_unit_id:"company-1" ();
    make_unit ~unit_id:"platoon-2" ~label:"Beta" ~kind:Platoon
      ~parent_unit_id:"company-1" ();
    make_unit ~unit_id:"squad-1a" ~label:"Strike-A" ~kind:Squad
      ~parent_unit_id:"platoon-1" ~roster:["alice"; "bob"] ();
    make_unit ~unit_id:"squad-1b" ~label:"Strike-B" ~kind:Squad
      ~parent_unit_id:"platoon-1" ~roster:["charlie"] ();
    make_unit ~unit_id:"squad-2a" ~label:"Recon-A" ~kind:Squad
      ~parent_unit_id:"platoon-2" ~roster:["diana"; "eve"] ();
    make_unit ~unit_id:"squad-2b" ~label:"Recon-B" ~kind:Squad
      ~parent_unit_id:"platoon-2" ~roster:["frank"] ();
    make_unit ~unit_id:"agent-alice" ~label:"Alice" ~kind:Agent_unit
      ~parent_unit_id:"squad-1a" ~roster:["alice"] ();
    make_unit ~unit_id:"agent-bob" ~label:"Bob" ~kind:Agent_unit
      ~parent_unit_id:"squad-1a" ~roster:["bob"] ();
    make_unit ~unit_id:"agent-charlie" ~label:"Charlie" ~kind:Agent_unit
      ~parent_unit_id:"squad-1b" ~roster:["charlie"] ();
    make_unit ~unit_id:"agent-diana" ~label:"Diana" ~kind:Agent_unit
      ~parent_unit_id:"squad-2a" ~roster:["diana"] ();
    make_unit ~unit_id:"agent-eve" ~label:"Eve" ~kind:Agent_unit
      ~parent_unit_id:"squad-2a" ~roster:["eve"] ();
    make_unit ~unit_id:"agent-frank" ~label:"Frank" ~kind:Agent_unit
      ~parent_unit_id:"squad-2b" ~roster:["frank"] ();
  ]

let fixture_operations =
  [
    make_operation ~operation_id:"op-1" ~assigned_unit_id:"squad-1a" ~status:Active ();
    make_operation ~operation_id:"op-2" ~assigned_unit_id:"squad-1a" ~status:Active ();
    make_operation ~operation_id:"op-3" ~assigned_unit_id:"squad-2a" ~status:Planned ();
    make_operation ~operation_id:"op-4" ~assigned_unit_id:"agent-alice" ~status:Completed ();
    make_operation ~operation_id:"op-5" ~assigned_unit_id:"platoon-2" ~status:Active ();
    make_operation ~operation_id:"op-6" ~assigned_unit_id:"agent-frank" ~status:Paused ();
  ]

let fixture_agents =
  [
    make_agent ~name:"alice" ();
    make_agent ~name:"bob" ();
    make_agent ~name:"charlie" ~status:Inactive ();
    make_agent ~name:"diana" ();
    make_agent ~name:"eve" ();
    make_agent ~name:"frank" ~status:Inactive ();
  ]

(* --- Tests --- *)

let test_child_tbl_groups () =
  let idx = Cp_tree_index.build_tree_index
      ~units:fixture_units ~operations:fixture_operations ~agents:fixture_agents in
  (* company-1 should have 2 children: platoon-1, platoon-2 *)
  let company_children =
    Hashtbl.find_opt idx.child_tbl "company-1"
    |> Option.value ~default:[]
    |> List.map (fun (u : unit_record) -> u.unit_id)
    |> List.sort String.compare
  in
  Alcotest.(check (list string)) "company children"
    ["platoon-1"; "platoon-2"] company_children;
  (* squad-1a should have 2 children: agent-alice, agent-bob *)
  let squad_children =
    Hashtbl.find_opt idx.child_tbl "squad-1a"
    |> Option.value ~default:[]
    |> List.map (fun (u : unit_record) -> u.unit_id)
    |> List.sort String.compare
  in
  Alcotest.(check (list string)) "squad-1a children"
    ["agent-alice"; "agent-bob"] squad_children;
  (* leaf node has no children *)
  let leaf_children =
    Hashtbl.find_opt idx.child_tbl "agent-alice"
    |> Option.value ~default:[]
  in
  Alcotest.(check int) "leaf has no children" 0 (List.length leaf_children)

let test_direct_active_ops () =
  let idx = Cp_tree_index.build_tree_index
      ~units:fixture_units ~operations:fixture_operations ~agents:fixture_agents in
  (* squad-1a has 2 active ops (op-1, op-2) *)
  Alcotest.(check int) "squad-1a direct ops" 2
    (Hashtbl.find_opt idx.direct_active_ops "squad-1a" |> Option.value ~default:0);
  (* squad-2a has 1 planned op (op-3) — planned counts as active *)
  Alcotest.(check int) "squad-2a direct ops" 1
    (Hashtbl.find_opt idx.direct_active_ops "squad-2a" |> Option.value ~default:0);
  (* agent-alice has 0 active (op-4 is Completed) *)
  Alcotest.(check int) "agent-alice direct ops" 0
    (Hashtbl.find_opt idx.direct_active_ops "agent-alice" |> Option.value ~default:0);
  (* platoon-2 has 1 active (op-5) *)
  Alcotest.(check int) "platoon-2 direct ops" 1
    (Hashtbl.find_opt idx.direct_active_ops "platoon-2" |> Option.value ~default:0);
  (* agent-frank has 0 active (op-6 is Paused) *)
  Alcotest.(check int) "agent-frank direct ops" 0
    (Hashtbl.find_opt idx.direct_active_ops "agent-frank" |> Option.value ~default:0)

let test_subtree_aggregation () =
  let idx = Cp_tree_index.build_tree_index
      ~units:fixture_units ~operations:fixture_operations ~agents:fixture_agents in
  Cp_tree_index.bottom_up_aggregate idx;
  (* company-1 subtree: op-1(active) + op-2(active) + op-3(planned) + op-5(active) = 4
     op-4(completed) and op-6(paused) are excluded *)
  Alcotest.(check int) "company-1 subtree ops" 4
    (Hashtbl.find_opt idx.subtree_active_ops "company-1" |> Option.value ~default:0);
  (* platoon-1 subtree: op-1 + op-2 = 2 (squad-1a direct) *)
  Alcotest.(check int) "platoon-1 subtree ops" 2
    (Hashtbl.find_opt idx.subtree_active_ops "platoon-1" |> Option.value ~default:0);
  (* platoon-2 subtree: op-3(squad-2a) + op-5(platoon-2 direct) = 2 *)
  Alcotest.(check int) "platoon-2 subtree ops" 2
    (Hashtbl.find_opt idx.subtree_active_ops "platoon-2" |> Option.value ~default:0);
  (* squad-1a subtree: op-1 + op-2 = 2 (both direct, children have 0 active) *)
  Alcotest.(check int) "squad-1a subtree ops" 2
    (Hashtbl.find_opt idx.subtree_active_ops "squad-1a" |> Option.value ~default:0);
  (* leaf agent-alice: 0 (completed doesn't count) *)
  Alcotest.(check int) "agent-alice subtree ops" 0
    (Hashtbl.find_opt idx.subtree_active_ops "agent-alice" |> Option.value ~default:0)

let test_live_roster_count () =
  let idx = Cp_tree_index.build_tree_index
      ~units:fixture_units ~operations:fixture_operations ~agents:fixture_agents in
  (* squad-1a roster: [alice, bob] — alice is Active, bob is Active = 2 *)
  Alcotest.(check int) "squad-1a live roster" 2
    (Hashtbl.find_opt idx.live_roster_count "squad-1a" |> Option.value ~default:0);
  (* squad-1b roster: [charlie] — charlie is Inactive = 0 *)
  Alcotest.(check int) "squad-1b live roster" 0
    (Hashtbl.find_opt idx.live_roster_count "squad-1b" |> Option.value ~default:0);
  (* squad-2b roster: [frank] — frank is Inactive = 0 *)
  Alcotest.(check int) "squad-2b live roster" 0
    (Hashtbl.find_opt idx.live_roster_count "squad-2b" |> Option.value ~default:0)

let test_agent_status_for_tbl () =
  let idx = Cp_tree_index.build_tree_index
      ~units:fixture_units ~operations:fixture_operations ~agents:fixture_agents in
  Alcotest.(check string) "alice status" "active"
    (Cp_tree_index.agent_status_for_tbl idx "alice");
  Alcotest.(check string) "charlie status" "inactive"
    (Cp_tree_index.agent_status_for_tbl idx "charlie");
  Alcotest.(check string) "unknown status" "offline"
    (Cp_tree_index.agent_status_for_tbl idx "unknown-agent")

let test_prefix_matching () =
  (* Test that roster name "alice" matches live agent "alice-1" *)
  let agents = [make_agent ~name:"alice-1" ()] in
  let units = [make_unit ~unit_id:"u1" ~label:"U" ~kind:Squad ~roster:["alice"] ()] in
  let idx = Cp_tree_index.build_tree_index ~units ~operations:[] ~agents in
  Alcotest.(check int) "prefix match live roster" 1
    (Hashtbl.find_opt idx.live_roster_count "u1" |> Option.value ~default:0);
  Alcotest.(check string) "prefix match status" "active"
    (Cp_tree_index.agent_status_for_tbl idx "alice")

(* --- Golden test: indexed vs legacy produce same JSON --- *)

let test_golden_json_equality () =
  let idx = Cp_tree_index.build_tree_index
      ~units:fixture_units ~operations:fixture_operations ~agents:fixture_agents in
  Cp_tree_index.bottom_up_aggregate idx;
  let child_map = children_map fixture_units in
  let unit_lookup = unit_map fixture_units in
  let agent_statuses = agent_status_map fixture_agents in
  let live_agents = live_agent_names fixture_agents in
  (* Build with old method *)
  let old_result =
    build_tree_json ~child_map ~unit_lookup ~agent_statuses ~live_agents
      ~operations:fixture_operations "company-1"
  in
  (* Build with new indexed method *)
  let new_result = build_tree_json_indexed ~tree_idx:idx "company-1" in
  (* Strip generated_at and time-dependent fields for comparison.
     The JSON structure should be identical except for is_stale which
     depends on current time — both use the same logic so should match. *)
  match (old_result, new_result) with
  | Some old_json, Some new_json ->
      let old_str = Yojson.Safe.to_string old_json in
      let new_str = Yojson.Safe.to_string new_json in
      Alcotest.(check string) "golden JSON equality" old_str new_str
  | None, None -> ()
  | Some _, None -> Alcotest.fail "old produced Some, new produced None"
  | None, Some _ -> Alcotest.fail "old produced None, new produced Some"

(* --- Runner --- *)

let () =
  Alcotest.run "tree_index"
    [
      ( "build_tree_index",
        [
          Alcotest.test_case "child_tbl groups" `Quick test_child_tbl_groups;
          Alcotest.test_case "direct_active_ops" `Quick test_direct_active_ops;
          Alcotest.test_case "subtree_aggregation" `Quick test_subtree_aggregation;
          Alcotest.test_case "live_roster_count" `Quick test_live_roster_count;
          Alcotest.test_case "agent_status_for_tbl" `Quick test_agent_status_for_tbl;
          Alcotest.test_case "prefix_matching" `Quick test_prefix_matching;
        ] );
      ( "golden",
        [
          Alcotest.test_case "indexed vs legacy JSON" `Quick test_golden_json_equality;
        ] );
    ]
