(** Tests for keeper-agent tool isolation.

    Validates the structural invariant that keeper tools and agent
    coordination tools occupy disjoint namespaces.

    Note: research-profile keepers intentionally receive masc_autoresearch_*
    tools via the shard system. The isolation boundary is between keeper
    tools and agent coordination tools (spawned_agent_public).

    Pure synchronous tests — no Eio or network required. *)

module Keeper_exec_tools = Masc_mcp.Keeper_exec_tools
module Agent_tool_surfaces = Masc_mcp.Agent_tool_surfaces
module Tool_shard = Masc_mcp.Tool_shard
module Tool_catalog = Masc_mcp.Tool_catalog
module Keeper_types = Masc_mcp.Keeper_types
module Tool_code_write = Masc_mcp.Tool_code_write
module Keeper_tool_registry = Masc_mcp.Keeper_tool_registry
module Config = Masc_mcp.Config

(* ============================================================
   Helper: create keeper_meta via meta_of_json (canonical pattern)
   ============================================================ *)

let make_meta
    ?(name = "test-keeper")
    ?(policy_voice_enabled = false)
    
    ()
  : Keeper_types.keeper_meta =
  match Keeper_types.meta_of_json
    (`Assoc [
      ("name", `String name);
      ("agent_name", `String name);
      ("trace_id", `String "test-isolation-001");
      
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

(** Non-keeper_ tool names legitimately granted to keepers.
    Derived from actual module exports — no prefix guessing.
    Must be a function (not a let-binding) because injected_masc_tool_names
    depends on inject_masc_schemas which runs after module init. *)
let known_non_keeper_tool_names () : string list =
  List.concat [
    Tool_shard.autoresearch_keeper_tools
    |> List.map (fun (t : Types.tool_schema) -> t.name);
    Tool_shard.coding_tools
    |> List.map (fun (t : Types.tool_schema) -> t.name);
    Tool_code_write.tool_names;
    (* MASC tools injected via tool_policy.toml masc groups *)
    Keeper_tool_registry.injected_masc_tool_names ();
  ]
  |> List.sort_uniq String.compare

let known_shared_agent_keeper_tool_names : string list =
  [
    "masc_worktree_create";
    "masc_worktree_list";
    "masc_code_write";
    "masc_code_edit";
    "masc_code_shell";
    "masc_code_git";
    "masc_status";
    "masc_tasks";
    "masc_claim_next";
    "masc_transition";
    "masc_add_task";
    "masc_broadcast";
    "masc_heartbeat";
  ]

let test_known_shared_tools_exist_on_agent_surface () =
  let agent_names = Agent_tool_surfaces.spawned_agent_public_tool_names in
  List.iter
    (fun name ->
      Alcotest.(check bool)
        (name ^ " is exposed on spawned agent surface")
        true (List.mem name agent_names))
    known_shared_agent_keeper_tool_names

(* ============================================================
   Invariant 1: Non-research keepers only get keeper_* tools plus
   curated canonical masc_* keeper workflows
   ============================================================ *)

let test_heuristic_only_keeper_prefixed () =
  let meta = make_meta () in
  let names = Keeper_exec_tools.keeper_allowed_tool_names meta in
  let non_keeper = List.filter (fun n -> not (has_keeper_prefix n)) names in
  let unexpected =
    List.filter (fun n -> not (List.mem n (known_non_keeper_tool_names ()))) non_keeper
  in
  Alcotest.(check (list string))
    "heuristic keeper only has keeper_* or curated masc_* tools" [] unexpected

let test_learned_only_keeper_prefixed () =
  let meta = make_meta ~policy_voice_enabled:true () in
  let names = Keeper_exec_tools.keeper_allowed_tool_names meta in
  let non_keeper = List.filter (fun n -> not (has_keeper_prefix n)) names in
  let unexpected =
    List.filter (fun n -> not (List.mem n (known_non_keeper_tool_names ()))) non_keeper
  in
  Alcotest.(check (list string))
    "learned keeper only has keeper_* or curated masc_* tools" [] unexpected

(* ============================================================
   Invariant 2: Research keepers only add research/autoresearch tools
   ============================================================ *)

let test_research_extra_tools_are_research_only () =
  let meta = make_meta ~policy_voice_enabled:true
       () in
  let names = Keeper_exec_tools.keeper_allowed_tool_names meta in
  let non_keeper = List.filter (fun n -> not (has_keeper_prefix n)) names in
  let unexpected = List.filter (fun n ->
    not (List.mem n (known_non_keeper_tool_names ()))) non_keeper in
  Alcotest.(check (list string))
    "non-keeper tools come from known sources" [] unexpected

let test_write_done_returns_empty () =
  let meta = make_meta () in
  let names = Keeper_exec_tools.keeper_allowed_tool_names ~write_done:true meta in
  Alcotest.(check (list string)) "write_done returns empty" [] names

(* ============================================================
   Invariant 3: Agent coordination tools never contain keeper_*
   ============================================================ *)

let test_agent_surface_no_keeper_tools () =
  let names = Agent_tool_surfaces.spawned_agent_public_tool_names in
  let leaked = List.filter has_keeper_prefix names in
  Alcotest.(check (list string)) "no keeper_* in agent surface" [] leaked

(* ============================================================
   Invariant 4: Keeper tools never overlap with agent coordination
   ============================================================ *)

let test_no_overlap_heuristic_vs_agent () =
  let meta = make_meta () in
  let keeper_names = Keeper_exec_tools.keeper_allowed_tool_names meta in
  let agent_names = Agent_tool_surfaces.spawned_agent_public_tool_names in
  (* Mode removal: all keepers now get the approved shared agent/keeper tools,
     which include worktree and masc_code_* tools. *)
  let overlap =
    List.filter
      (fun n ->
        List.mem n agent_names
        && not (List.mem n known_shared_agent_keeper_tool_names))
      keeper_names
  in
  Alcotest.(check (list string))
    "heuristic keeper only shares approved worktree/code tools with agent surface"
    [] overlap

let test_no_overlap_research_vs_agent () =
  let meta = make_meta ~policy_voice_enabled:true
       () in
  let keeper_names = Keeper_exec_tools.keeper_allowed_tool_names meta in
  let agent_names = Agent_tool_surfaces.spawned_agent_public_tool_names in
  let overlap =
    List.filter
      (fun n ->
        List.mem n agent_names
        && not (List.mem n known_shared_agent_keeper_tool_names))
      keeper_names
  in
  Alcotest.(check (list string))
    "research keeper only shares approved worktree/code tools with agent surface"
    [] overlap

let test_shard_tools_overlap_with_agent_documented () =
  (* Mode removal: coding shard (now in defaults) includes the approved shared
     worktree/code tools that also appear in the agent surface. *)
  let keeper_tools = Tool_shard.keeper_model_tools
    |> List.map (fun (t : Types.tool_schema) -> t.name) in
  let agent_tools = Agent_tool_surfaces.spawned_agent_public_tool_names in
  let overlap = List.filter (fun name -> List.mem name agent_tools) keeper_tools in
  List.iter (fun name ->
    Alcotest.(check bool) (name ^ " is approved shared tool") true
      (List.mem name known_shared_agent_keeper_tool_names)
  ) overlap

(* ============================================================
   Invariant 5: Research shard tools that overlap with admin list
   (documenting the intentional design — keeper shard bypasses
   the dispatch pre-hook permission check for these tools)
   ============================================================ *)

let test_research_admin_overlap_documented () =
  let admin = Tool_catalog.tools_for_surface Tool_catalog.Admin in
  let meta = make_meta  () in
  let keeper_names = Keeper_exec_tools.keeper_allowed_tool_names meta in
  let overlap = List.filter (fun n -> List.mem n admin) keeper_names in
  (* These research tools are intentionally in both lists.
     Keepers access them via shard allocation, not dispatch pre-hook.
     This test documents the overlap rather than preventing it. *)
  List.iter (fun name ->
    Alcotest.(check bool) (name ^ " is a research tool") true
      (List.mem name (known_non_keeper_tool_names ()))
  ) overlap

(* ============================================================
   Invariant 6: All keepers now have admin-listed tools (mode removed).
   Document the overlap rather than preventing it.
   ============================================================ *)

let test_non_research_admin_tools_documented () =
  let admin = Tool_catalog.tools_for_surface Tool_catalog.Admin in
  let meta = make_meta ~policy_voice_enabled:true () in
  let keeper_names = Keeper_exec_tools.keeper_allowed_tool_names meta in
  let overlap = List.filter (fun n -> List.mem n admin) keeper_names in
  (* Mode removal: all keepers get all tools. Admin-listed tools that
     appear in keeper tool set come from known sources (coding, research shards). *)
  List.iter (fun name ->
    Alcotest.(check bool) (name ^ " is from known source") true
      (List.mem name (known_non_keeper_tool_names ()))
  ) overlap

(* ============================================================
   Invariant 7: Tool count consistency across policy modes
   ============================================================ *)

let test_heuristic_has_fewer_tools_than_learned () =
  let heuristic = make_meta () in
  let learned = make_meta ~policy_voice_enabled:true
       () in
  let h_count = List.length (Keeper_exec_tools.keeper_allowed_tool_names heuristic) in
  let l_count = List.length (Keeper_exec_tools.keeper_allowed_tool_names learned) in
  Alcotest.(check bool)
    "learned mode has >= heuristic tools"
    true (l_count >= h_count)

(* ============================================================
   Invariant 8: keeper- prefix is never double-attached (#5104)
   ============================================================ *)

let test_strip_keeper_prefix_no_prefix () =
  Alcotest.(check string)
    "plain name unchanged" "sangsu"
    (Keeper_types.strip_keeper_prefix "sangsu")

let test_strip_keeper_prefix_has_prefix () =
  Alcotest.(check string)
    "strips single keeper- prefix" "admin"
    (Keeper_types.strip_keeper_prefix "keeper-admin")

let test_strip_keeper_prefix_double () =
  Alcotest.(check string)
    "strips outer keeper- leaving keeper-admin" "keeper-admin"
    (Keeper_types.strip_keeper_prefix "keeper-keeper-admin")

let test_keeper_agent_sender_plain_name () =
  (* keeper_agent_sender now delegates to meta.agent_name (#5625) *)
  let meta = make_meta ~name:"sangsu" () in
  Alcotest.(check string)
    "returns meta.agent_name" "sangsu"
    (Masc_mcp.Keeper_exec_shared.keeper_agent_sender ~meta)

let test_keeper_agent_sender_prefixed_name () =
  let meta = make_meta ~name:"keeper-admin" () in
  Alcotest.(check string)
    "returns meta.agent_name" "keeper-admin"
    (Masc_mcp.Keeper_exec_shared.keeper_agent_sender ~meta)

let test_keeper_agent_name_plain () =
  Alcotest.(check string)
    "keeper-sangsu-agent" "keeper-sangsu-agent"
    (Keeper_types.keeper_agent_name "sangsu")

let test_keeper_agent_name_prefixed () =
  Alcotest.(check string)
    "no double prefix in agent_name" "keeper-admin-agent"
    (Keeper_types.keeper_agent_name "keeper-admin")

let test_keeper_name_from_agent_name_roundtrip () =
  Alcotest.(check (option string))
    "agent alias resolves to keeper name" (Some "sangsu")
    (Keeper_types.keeper_name_from_agent_name "keeper-sangsu-agent")

let test_keeper_name_from_generated_nickname () =
  Alcotest.(check (option string))
    "generated nickname resolves directly" (Some "claude-swift-fox")
    (Keeper_types.keeper_name_from_agent_name "claude-swift-fox")

let test_keeper_name_from_agent_name_rejects_plain_name () =
  Alcotest.(check (option string))
    "plain keeper name is not treated as agent alias" None
    (Keeper_types.keeper_name_from_agent_name "sangsu")

(* ============================================================
   Test runner
   ============================================================ *)

let () =
  let base_path = Masc_test_deps.find_project_root () in
  Keeper_exec_tools.inject_masc_schemas Config.raw_all_tool_schemas;
  ignore (Result.get_ok (Keeper_exec_tools.init_policy_config ~base_path));
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
    ]);
    ("disjoint_namespaces", [
      Alcotest.test_case "shared tool whitelist stays real" `Quick
        test_known_shared_tools_exist_on_agent_surface;
      Alcotest.test_case "heuristic vs agent" `Quick test_no_overlap_heuristic_vs_agent;
      Alcotest.test_case "research vs agent" `Quick test_no_overlap_research_vs_agent;
      Alcotest.test_case "shard vs agent" `Quick test_shard_tools_overlap_with_agent_documented;
    ]);
    ("admin_boundary", [
      Alcotest.test_case "research admin overlap documented" `Quick
        test_research_admin_overlap_documented;
      Alcotest.test_case "non-research admin documented" `Quick test_non_research_admin_tools_documented;
    ]);
    ("policy_consistency", [
      Alcotest.test_case "learned >= heuristic" `Quick test_heuristic_has_fewer_tools_than_learned;
    ]);
    ("keeper_prefix_no_double", [
      Alcotest.test_case "strip no prefix" `Quick test_strip_keeper_prefix_no_prefix;
      Alcotest.test_case "strip has prefix" `Quick test_strip_keeper_prefix_has_prefix;
      Alcotest.test_case "strip double prefix" `Quick test_strip_keeper_prefix_double;
      Alcotest.test_case "sender plain name" `Quick test_keeper_agent_sender_plain_name;
      Alcotest.test_case "sender prefixed name" `Quick test_keeper_agent_sender_prefixed_name;
      Alcotest.test_case "agent_name plain" `Quick test_keeper_agent_name_plain;
      Alcotest.test_case "agent_name prefixed" `Quick test_keeper_agent_name_prefixed;
      Alcotest.test_case "agent alias roundtrip" `Quick
        test_keeper_name_from_agent_name_roundtrip;
      Alcotest.test_case "generated nickname is alias" `Quick
        test_keeper_name_from_generated_nickname;
      Alcotest.test_case "plain name is not alias" `Quick
        test_keeper_name_from_agent_name_rejects_plain_name;
    ]);
  ]
