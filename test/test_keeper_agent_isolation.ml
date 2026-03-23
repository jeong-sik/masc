(** Tests for keeper-agent tool isolation.

    Validates the structural invariant that keeper tools and agent
    coordination tools occupy disjoint namespaces.

    Note: research-profile keepers intentionally receive masc_autoresearch_*
    and masc_research_* tools via the shard system. The isolation boundary
    is between keeper tools and agent coordination tools (spawned_agent_public).

    Pure synchronous tests — no Eio or network required. *)

module Keeper_exec_tools = Masc_mcp.Keeper_exec_tools
module Agent_tool_surfaces = Masc_mcp.Agent_tool_surfaces
module Tool_shard = Masc_mcp.Tool_shard
module Tool_permissions = Masc_mcp.Tool_permissions
module Keeper_types = Masc_mcp.Keeper_types

(* ============================================================
   Helper: create keeper_meta via meta_of_json (canonical pattern)
   ============================================================ *)

let make_meta
    ?(name = "test-keeper")
    ?(policy_mode = "Heuristic")
    ?(policy_shell_mode = "disabled")
    ?(policy_voice_enabled = false)
    ?(soul_profile = "safety")
    ()
  : Keeper_types.keeper_meta =
  match Keeper_types.meta_of_json
    (`Assoc [
      ("name", `String name);
      ("agent_name", `String name);
      ("trace_id", `String "test-isolation-001");
      ("soul_profile", `String soul_profile);
      ("policy_mode", `String policy_mode);
      ("policy_shell_mode", `String policy_shell_mode);
      ("policy_voice_enabled", `Bool policy_voice_enabled);
    ]) with
  | Ok meta -> meta
  | Error e -> failwith (Printf.sprintf "make_meta failed: %s" e)

(* ============================================================
   Known intentional cross-namespace tools
   (research keepers receive these via shard, not dispatch)
   ============================================================ *)

let has_keeper_prefix name =
  String.length name >= 7 && String.sub name 0 7 = "keeper_"

let is_research_shard_tool name =
  let prefixes = ["masc_autoresearch_"; "masc_research_"] in
  List.exists (fun prefix ->
    String.length name >= String.length prefix &&
    String.sub name 0 (String.length prefix) = prefix) prefixes

(* ============================================================
   Invariant 1: Non-research keepers only get keeper_* tools
   ============================================================ *)

let test_heuristic_only_keeper_prefixed () =
  let meta = make_meta ~policy_mode:"Heuristic" () in
  let names = Keeper_exec_tools.keeper_allowed_tool_names meta in
  let non_keeper = List.filter (fun n -> not (has_keeper_prefix n)) names in
  Alcotest.(check (list string))
    "heuristic keeper only has keeper_* tools" [] non_keeper

let test_learned_only_keeper_prefixed () =
  let meta = make_meta ~policy_mode:"Learned_offline_v1"
      ~policy_shell_mode:"readonly" ~policy_voice_enabled:true () in
  let names = Keeper_exec_tools.keeper_allowed_tool_names meta in
  let non_keeper = List.filter (fun n -> not (has_keeper_prefix n)) names in
  Alcotest.(check (list string))
    "learned keeper only has keeper_* tools" [] non_keeper

(* ============================================================
   Invariant 2: Research keepers only add research/autoresearch tools
   ============================================================ *)

let test_research_extra_tools_are_research_only () =
  let meta = make_meta ~policy_mode:"Learned_offline_v1"
      ~policy_shell_mode:"coding" ~policy_voice_enabled:true
      ~soul_profile:"research" () in
  let names = Keeper_exec_tools.keeper_allowed_tool_names meta in
  let non_keeper = List.filter (fun n -> not (has_keeper_prefix n)) names in
  let unexpected = List.filter (fun n -> not (is_research_shard_tool n)) non_keeper in
  Alcotest.(check (list string))
    "research keeper only adds research shard tools" [] unexpected

let test_write_done_returns_empty () =
  let meta = make_meta ~policy_mode:"Learned_offline_v1"
      ~policy_shell_mode:"coding" () in
  let names = Keeper_exec_tools.keeper_allowed_tool_names ~write_done:true meta in
  Alcotest.(check (list string)) "write_done returns empty" [] names

(* ============================================================
   Invariant 3: Agent coordination tools never contain keeper_*
   ============================================================ *)

let test_agent_surface_no_keeper_tools () =
  let names = Agent_tool_surfaces.spawned_agent_public_tool_names in
  let leaked = List.filter has_keeper_prefix names in
  Alcotest.(check (list string)) "no keeper_* in agent surface" [] leaked

let test_mdal_surface_no_keeper_tools () =
  let names = Agent_tool_surfaces.mdal_auditable_tool_names in
  let leaked = List.filter has_keeper_prefix names in
  Alcotest.(check (list string)) "no keeper_* in mdal surface" [] leaked

(* ============================================================
   Invariant 4: Keeper tools never overlap with agent coordination
   ============================================================ *)

let test_no_overlap_heuristic_vs_agent () =
  let meta = make_meta ~policy_mode:"Heuristic" () in
  let keeper_names = Keeper_exec_tools.keeper_allowed_tool_names meta in
  let agent_names = Agent_tool_surfaces.spawned_agent_public_tool_names in
  let overlap = List.filter (fun n -> List.mem n agent_names) keeper_names in
  Alcotest.(check (list string))
    "heuristic keeper disjoint from agent coordination" [] overlap

let test_no_overlap_research_vs_agent () =
  let meta = make_meta ~policy_mode:"Learned_offline_v1"
      ~policy_shell_mode:"coding" ~policy_voice_enabled:true
      ~soul_profile:"research" () in
  let keeper_names = Keeper_exec_tools.keeper_allowed_tool_names meta in
  let agent_names = Agent_tool_surfaces.spawned_agent_public_tool_names in
  let overlap = List.filter (fun n -> List.mem n agent_names) keeper_names in
  Alcotest.(check (list string))
    "research keeper disjoint from agent coordination" [] overlap

let test_shard_tools_disjoint_from_agent () =
  let keeper_tools = Tool_shard.keeper_model_tools
    |> List.map (fun (t : Types.tool_schema) -> t.name) in
  let agent_tools = Agent_tool_surfaces.spawned_agent_public_tool_names in
  let overlap = List.filter (fun name -> List.mem name agent_tools) keeper_tools in
  Alcotest.(check (list string))
    "shard tools disjoint from agent surface" [] overlap

(* ============================================================
   Invariant 5: Research shard tools that overlap with admin list
   (documenting the intentional design — keeper shard bypasses
   the dispatch pre-hook permission check for these tools)
   ============================================================ *)

let test_research_admin_overlap_documented () =
  let admin = Tool_permissions.admin_tools in
  let meta = make_meta ~policy_mode:"Learned_offline_v1"
      ~policy_shell_mode:"coding" ~soul_profile:"research" () in
  let keeper_names = Keeper_exec_tools.keeper_allowed_tool_names meta in
  let overlap = List.filter (fun n -> List.mem n admin) keeper_names in
  (* These research tools are intentionally in both lists.
     Keepers access them via shard allocation, not dispatch pre-hook.
     This test documents the overlap rather than preventing it. *)
  List.iter (fun name ->
    Alcotest.(check bool) (name ^ " is a research tool") true
      (is_research_shard_tool name)
  ) overlap

(* ============================================================
   Invariant 6: Non-research keepers have zero admin tool access
   ============================================================ *)

let test_non_research_no_admin_tools () =
  let admin = Tool_permissions.admin_tools in
  let meta = make_meta ~policy_mode:"Learned_offline_v1"
      ~policy_shell_mode:"coding" ~policy_voice_enabled:true () in
  let keeper_names = Keeper_exec_tools.keeper_allowed_tool_names meta in
  let leaked = List.filter (fun n -> List.mem n admin) keeper_names in
  Alcotest.(check (list string))
    "non-research keeper has zero admin tools" [] leaked

(* ============================================================
   Invariant 7: Tool count consistency across policy modes
   ============================================================ *)

let test_heuristic_has_fewer_tools_than_learned () =
  let heuristic = make_meta ~policy_mode:"Heuristic" () in
  let learned = make_meta ~policy_mode:"Learned_offline_v1"
      ~policy_shell_mode:"coding" ~policy_voice_enabled:true
      ~soul_profile:"research" () in
  let h_count = List.length (Keeper_exec_tools.keeper_allowed_tool_names heuristic) in
  let l_count = List.length (Keeper_exec_tools.keeper_allowed_tool_names learned) in
  Alcotest.(check bool)
    "learned mode has >= heuristic tools"
    true (l_count >= h_count)

(* ============================================================
   Test runner
   ============================================================ *)

let () =
  Alcotest.run "Keeper_agent_isolation" [
    ("non_research_prefix", [
      Alcotest.test_case "heuristic only keeper_*" `Quick test_heuristic_only_keeper_prefixed;
      Alcotest.test_case "learned only keeper_*" `Quick test_learned_only_keeper_prefixed;
    ]);
    ("research_boundary", [
      Alcotest.test_case "research extras are research-only" `Quick
        test_research_extra_tools_are_research_only;
      Alcotest.test_case "write_done empty" `Quick test_write_done_returns_empty;
    ]);
    ("agent_no_keeper_tools", [
      Alcotest.test_case "spawned agent surface" `Quick test_agent_surface_no_keeper_tools;
      Alcotest.test_case "mdal surface" `Quick test_mdal_surface_no_keeper_tools;
    ]);
    ("disjoint_namespaces", [
      Alcotest.test_case "heuristic vs agent" `Quick test_no_overlap_heuristic_vs_agent;
      Alcotest.test_case "research vs agent" `Quick test_no_overlap_research_vs_agent;
      Alcotest.test_case "shard vs agent" `Quick test_shard_tools_disjoint_from_agent;
    ]);
    ("admin_boundary", [
      Alcotest.test_case "research admin overlap documented" `Quick
        test_research_admin_overlap_documented;
      Alcotest.test_case "non-research no admin" `Quick test_non_research_no_admin_tools;
    ]);
    ("policy_consistency", [
      Alcotest.test_case "learned >= heuristic" `Quick test_heuristic_has_fewer_tools_than_learned;
    ]);
  ]
