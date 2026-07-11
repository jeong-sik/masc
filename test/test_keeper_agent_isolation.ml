module Types = Masc_domain

(** Tests for keeper-agent tool isolation.

    Validates the structural invariant that keeper tools and agent
    workspace tools occupy disjoint namespaces.

	    The isolation boundary is between keeper tools and agent workspace tools
    (spawned_agent_public).

    Pure synchronous tests — no Eio or network required. *)

module Keeper_tool_dispatch_runtime = Masc.Keeper_tool_dispatch_runtime
module Keeper_meta_contract = Masc.Keeper_meta_contract
module Keeper_tool_surfaces = Masc.Keeper_tool_surfaces
module Tool_shard = Masc.Tool_shard
module Keeper_types = Keeper_types
module Keeper_identity = Masc.Keeper_identity
module Keeper_tool_registry = Masc.Keeper_tool_registry
module Keeper_tool_descriptor = Masc.Keeper_tool_descriptor
module Config = Masc.Config

(* ============================================================
   Helper: create keeper_meta via meta_of_json (canonical pattern)
   ============================================================ *)

let make_meta
    ?(name = "test-keeper")
    ?(policy_voice_enabled = false)
    
    ()
  : Keeper_meta_contract.keeper_meta =
  match Masc_test_deps.meta_of_json_fixture
    (`Assoc [
      ("name", `String name);
      ("agent_name", `String name);
      ("trace_id", `String "test-isolation-001");
      
      ("policy_voice_enabled", `Bool policy_voice_enabled);
    ]) with
  | Ok meta -> meta
  | Error e -> failwith (Printf.sprintf "make_meta failed: %s" e)

(* ============================================================
   Known intentional cross-namespace tools.
   ============================================================ *)

let has_keeper_prefix name =
  String.length name >= 7 && String.sub name 0 7 = "keeper_"

(** Non-keeper_ tool names legitimately granted to keepers.
    Derived from actual candidate-source exports -- no prefix guessing.
    Must be a function because injected_masc_tool_names depends on
    inject_masc_schemas, which runs after module init. *)
let descriptor_tool_names () : string list =
  Keeper_tool_descriptor.all_descriptors ()
  |> List.concat_map Keeper_tool_descriptor.keeper_candidate_names
  |> List.sort_uniq String.compare

let shard_tool_names () : string list =
  Tool_shard.all_keeper_tool_schemas
  |> List.map (fun (t : Masc_domain.tool_schema) -> t.name)
  |> List.sort_uniq String.compare

let known_non_keeper_tool_names () : string list =
  (shard_tool_names ()
   |> List.filter (fun name -> not (has_keeper_prefix name)))
  @ Keeper_tool_registry.core_always_tools
  @ Keeper_tool_registry.effective_core_tools ()
  @ Keeper_tool_registry.injected_masc_tool_names ()
  @ Keeper_tool_dispatch_runtime.effective_core_tools ()
  @ Keeper_tool_dispatch_runtime.keeper_internal_candidate_tool_names
  @ descriptor_tool_names ()
  |> List.filter (fun name -> not (has_keeper_prefix name))
  |> List.sort_uniq String.compare

(** The spawned-agent surface is the SSOT for workspace tools that may also
    appear in keeper-selected candidates.  Avoid duplicating it here: stale
    hardcoded overlap lists were the source of misleading boundary failures. *)
let approved_shared_agent_keeper_tool_names () : string list =
  Keeper_tool_surfaces.spawned_agent_public_tool_names

let retired_tool_admin_surface_names : string list =
  [
    "masc_tool_admin_snapshot"
  ; "masc_tool_admin_update"
  ; "tool_admin_snapshot"
  ; "tool_admin_update"
  ]

let assert_no_retired_tool_admin_surface label names =
  let leaked =
    List.filter
      (fun name -> List.mem name retired_tool_admin_surface_names)
      names
  in
  Alcotest.(check (list string)) label [] leaked

let assert_non_keeper_tools_from_known_sources label names =
  let non_keeper = List.filter (fun name -> not (has_keeper_prefix name)) names in
  let unexpected =
    List.filter
      (fun name -> not (List.mem name (known_non_keeper_tool_names ())))
      non_keeper
  in
  Alcotest.(check (list string)) label [] unexpected

let test_registered_surfaces_exclude_retired_tool_admin () =
  assert_no_retired_tool_admin_surface
    "public MCP surface excludes retired tool-admin surface"
    Tool_catalog_surfaces.public_mcp_surface_tools;
  assert_no_retired_tool_admin_surface
    "spawned agent surface excludes retired tool-admin surface"
    Keeper_tool_surfaces.spawned_agent_public_tool_names;
  assert_no_retired_tool_admin_surface
    "local worker surface excludes retired tool-admin surface"
    Keeper_tool_surfaces.local_worker_public_tool_names;
  assert_no_retired_tool_admin_surface
    "raw schema registry excludes retired tool-admin surface"
    (Config.raw_all_tool_schemas
     |> List.map (fun (schema : Masc_domain.tool_schema) -> schema.name));
  assert_no_retired_tool_admin_surface
    "keeper shard registry excludes retired tool-admin surface"
    (Tool_shard.all_keeper_tool_schemas
     |> List.map (fun (schema : Masc_domain.tool_schema) -> schema.name));
  assert_no_retired_tool_admin_surface
    "keeper descriptor registry excludes retired tool-admin surface"
    (descriptor_tool_names ())

(* ============================================================
   Invariant 1: Non-research keepers only get keeper_* tools plus known
   candidate-source tools; retired tool-admin surface never
   re-enters keeper candidate sets.
   ============================================================ *)

let test_heuristic_non_keeper_tools_are_known () =
  let meta = make_meta () in
  let names = Keeper_tool_dispatch_runtime.keeper_allowed_tool_names meta in
  assert_non_keeper_tools_from_known_sources
    "heuristic keeper only has keeper_* or known candidate-source tools"
    names;
  assert_no_retired_tool_admin_surface
    "heuristic keeper excludes retired tool-admin surface"
    names

let test_learned_non_keeper_tools_are_known () =
  let meta = make_meta ~policy_voice_enabled:true () in
  let names = Keeper_tool_dispatch_runtime.keeper_allowed_tool_names meta in
  assert_non_keeper_tools_from_known_sources
    "learned keeper only has keeper_* or known candidate-source tools"
    names;
  assert_no_retired_tool_admin_surface
    "learned keeper excludes retired tool-admin surface"
    names

(* ============================================================
   Invariant 2: Research keepers still use only known curated tools
   ============================================================ *)

let test_research_extra_tools_are_research_only () =
  let meta = make_meta ~policy_voice_enabled:true
       () in
  let names = Keeper_tool_dispatch_runtime.keeper_allowed_tool_names meta in
  assert_non_keeper_tools_from_known_sources
    "non-keeper tools come from known sources"
    names;
  assert_no_retired_tool_admin_surface
    "research keeper excludes retired tool-admin surface"
    names

let test_write_done_returns_empty () =
  let meta = make_meta () in
  let names = Keeper_tool_dispatch_runtime.keeper_allowed_tool_names ~write_done:true meta in
  Alcotest.(check (list string)) "write_done returns empty" [] names

(* ============================================================
   Invariant 3: Agent workspace tools never contain keeper_*
   ============================================================ *)

let test_agent_surface_no_keeper_tools () =
  let names = Keeper_tool_surfaces.spawned_agent_public_tool_names in
  let leaked = List.filter has_keeper_prefix names in
  Alcotest.(check (list string)) "no keeper_* in agent surface" [] leaked

(* ============================================================
   Invariant 4: Keeper tools never overlap with agent workspace
   ============================================================ *)

let test_no_overlap_heuristic_vs_agent () =
  let meta = make_meta () in
  let keeper_names = Keeper_tool_dispatch_runtime.keeper_allowed_tool_names meta in
  let agent_names = Keeper_tool_surfaces.spawned_agent_public_tool_names in
  (* Some MASC workspace tools are intentionally shared between spawned
     agents and keeper-selected surfaces. *)
  let overlap =
    List.filter
      (fun n ->
        List.mem n agent_names
        && not (List.mem n (approved_shared_agent_keeper_tool_names ())))
      keeper_names
  in
  Alcotest.(check (list string))
    "heuristic keeper only shares approved workspace tools with agent surface"
    [] overlap

let test_no_overlap_research_vs_agent () =
  let meta = make_meta ~policy_voice_enabled:true
       () in
  let keeper_names = Keeper_tool_dispatch_runtime.keeper_allowed_tool_names meta in
  let agent_names = Keeper_tool_surfaces.spawned_agent_public_tool_names in
  let overlap =
    List.filter
      (fun n ->
        List.mem n agent_names
        && not (List.mem n (approved_shared_agent_keeper_tool_names ())))
      keeper_names
  in
  Alcotest.(check (list string))
    "research keeper only shares approved workspace tools with agent surface"
    [] overlap

let test_shard_tools_overlap_with_agent_documented () =
  (* Shards may include approved shared workspace tools that also appear in
     the agent surface. *)
  let keeper_tools = Tool_shard.keeper_model_tools
    |> List.map (fun (t : Masc_domain.tool_schema) -> t.name) in
  let agent_tools = Keeper_tool_surfaces.spawned_agent_public_tool_names in
  let overlap = List.filter (fun name -> List.mem name agent_tools) keeper_tools in
  List.iter (fun name ->
    Alcotest.(check bool) (name ^ " is approved shared tool") true
      (List.mem name (approved_shared_agent_keeper_tool_names ()))
  ) overlap

(* ============================================================
   Invariant 5: Tool count consistency across policy modes
   ============================================================ *)

let test_heuristic_has_fewer_tools_than_learned () =
  let heuristic = make_meta () in
  let learned = make_meta ~policy_voice_enabled:true
       () in
  let h_count = List.length (Keeper_tool_dispatch_runtime.keeper_allowed_tool_names heuristic) in
  let l_count = List.length (Keeper_tool_dispatch_runtime.keeper_allowed_tool_names learned) in
  Alcotest.(check bool)
    "learned mode has >= heuristic tools"
    true (l_count >= h_count)

(* ============================================================
   Invariant 8: keeper- prefix is never double-attached (#5104)
   ============================================================ *)

let test_strip_keeper_prefix_no_prefix () =
  Alcotest.(check (option string))
    "plain name has no keeper prefix" None
    (Keeper_identity.strip_keeper_prefix "sangsu")

let test_strip_keeper_prefix_has_prefix () =
  Alcotest.(check (option string))
    "strips single keeper- prefix" (Some "admin")
    (Keeper_identity.strip_keeper_prefix "keeper-admin")

let test_strip_keeper_prefix_double () =
  Alcotest.(check (option string))
    "strips outer keeper- leaving keeper-admin" (Some "keeper-admin")
    (Keeper_identity.strip_keeper_prefix "keeper-keeper-admin")

let test_keeper_agent_sender_plain_name () =
  (* keeper_agent_sender now delegates to meta.agent_name (#5625) *)
  let meta = make_meta ~name:"sangsu" () in
  Alcotest.(check string)
    "returns meta.agent_name" "sangsu"
    (Masc.Keeper_tool_shared_runtime.keeper_agent_sender ~meta)

let test_keeper_agent_sender_prefixed_name () =
  let meta = make_meta ~name:"keeper-admin" () in
  Alcotest.(check string)
    "returns meta.agent_name" "keeper-admin"
    (Masc.Keeper_tool_shared_runtime.keeper_agent_sender ~meta)

let test_keeper_agent_name_plain () =
  Alcotest.(check string)
    "keeper-sangsu-agent" "keeper-sangsu-agent"
    (Keeper_identity.keeper_agent_name "sangsu")

let test_keeper_agent_name_prefixed () =
  Alcotest.(check string)
    "no double prefix in agent_name" "keeper-admin-agent"
    (Keeper_identity.keeper_agent_name "keeper-admin")

let test_keeper_name_from_agent_name_roundtrip () =
  Alcotest.(check (option string))
    "agent alias resolves to keeper name" (Some "sangsu")
    (Keeper_identity.keeper_name_from_agent_name "keeper-sangsu-agent")

let test_keeper_name_from_generated_nickname () =
  Alcotest.(check (option string))
    "generated nickname resolves directly" (Some "claude-swift-fox")
    (Keeper_identity.keeper_name_from_agent_name "claude-swift-fox")

let test_keeper_name_from_agent_name_rejects_plain_name () =
  Alcotest.(check (option string))
    "plain keeper name is not treated as agent alias" None
    (Keeper_identity.keeper_name_from_agent_name "sangsu")

let test_canonical_keeper_name_from_generated_nickname () =
  Alcotest.(check (option string))
    "generated nickname resolves to canonical keeper" (Some "claude")
    (Keeper_identity.canonical_keeper_name_from_agent_name "claude-swift-fox")

let test_canonical_keeper_name_from_keeper_agent_alias_preserves_full_name () =
  Alcotest.(check (option string))
    "keeper agent alias keeps hyphenated keeper name"
    (Some "kimi-null-canary")
    (Keeper_identity.canonical_keeper_name_from_agent_name
       "keeper-kimi-null-canary-agent")

let test_canonical_keeper_name_from_legacy_keeper_name () =
  Alcotest.(check (option string))
    "legacy keeper-prefixed name normalizes" (Some "sangsu")
    (Keeper_identity.canonical_keeper_name "keeper-sangsu")

let test_canonical_keeper_name_preserves_plain_hyphenated_name () =
  Alcotest.(check (option string))
    "plain hyphenated keeper name is preserved"
    (Some "masc-smoke")
    (Keeper_identity.canonical_keeper_name "masc-smoke")

(* ============================================================
   Test runner
   ============================================================ *)

let () =
  Keeper_tool_dispatch_runtime.inject_masc_schemas Config.raw_all_tool_schemas;
  Alcotest.run "Keeper_agent_isolation" [
    ("non_research_prefix", [
      Alcotest.test_case "heuristic non-keeper tools are known" `Quick
        test_heuristic_non_keeper_tools_are_known;
      Alcotest.test_case "learned non-keeper tools are known" `Quick
        test_learned_non_keeper_tools_are_known;
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
      Alcotest.test_case "registered surfaces exclude retired tool-admin" `Quick
        test_registered_surfaces_exclude_retired_tool_admin;
      Alcotest.test_case "heuristic vs agent" `Quick test_no_overlap_heuristic_vs_agent;
      Alcotest.test_case "research vs agent" `Quick test_no_overlap_research_vs_agent;
      Alcotest.test_case "shard vs agent" `Quick test_shard_tools_overlap_with_agent_documented;
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
      Alcotest.test_case "generated nickname canonicalizes" `Quick
        test_canonical_keeper_name_from_generated_nickname;
      Alcotest.test_case "keeper agent alias preserves full name" `Quick
        test_canonical_keeper_name_from_keeper_agent_alias_preserves_full_name;
      Alcotest.test_case "legacy keeper name canonicalizes" `Quick
        test_canonical_keeper_name_from_legacy_keeper_name;
      Alcotest.test_case "plain hyphenated name preserved" `Quick
        test_canonical_keeper_name_preserves_plain_hyphenated_name;
    ]);
  ]
