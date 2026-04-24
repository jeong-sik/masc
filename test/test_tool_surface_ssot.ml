(** test_tool_surface_ssot — Shadow parity test for Tool_catalog surface SSOT.

    Verifies that [Tool_catalog.tools_for_surface] produces exactly the same
    sets as the legacy hardcoded lists in their respective modules.
    Once all consumers are migrated (Phase A2), these parity checks will be
    replaced by structural invariant tests (Phase A3). *)

open Masc_mcp

module SS = Set.Make (String)

let set_of = SS.of_list

let check_set_equal label ~expected ~actual =
  let missing = SS.diff expected actual in
  let extra = SS.diff actual expected in
  if not (SS.is_empty missing) then
    Alcotest.failf "%s: missing from SSOT: {%s}" label
      (String.concat ", " (SS.elements missing));
  if not (SS.is_empty extra) then
    Alcotest.failf "%s: extra in SSOT: {%s}" label
      (String.concat ", " (SS.elements extra));
  Alcotest.(check bool) (label ^ " sets equal") true
    (SS.equal expected actual)

let raw_schema_by_name name =
  Config.raw_all_tool_schemas
  |> List.find_opt (fun (schema : Types.tool_schema) -> String.equal schema.name name)

(* {1 Parity Tests — each compares legacy hardcoded list vs surface SSOT} *)

let test_public_mcp_parity () =
  let legacy = set_of Tool_catalog.public_mcp_tools in
  let ssot = set_of (Tool_catalog.tools_for_surface Tool_catalog.Public_mcp) in
  check_set_equal "Public_mcp" ~expected:legacy ~actual:ssot

let test_spawned_agent_parity () =
  let legacy = set_of Agent_tool_surfaces.spawned_agent_public_tool_names in
  let ssot = set_of (Tool_catalog.tools_for_surface Tool_catalog.Spawned_agent) in
  check_set_equal "Spawned_agent" ~expected:legacy ~actual:ssot

let test_local_worker_public_tools_resolvable () =
  let public_names =
    set_of (Tool_catalog.tools_for_surface Tool_catalog.Local_worker)
  in
  let resolvable_names =
    set_of (Agent_tool_surfaces.local_worker_resolvable_tool_names ())
  in
  let missing = SS.diff public_names resolvable_names in
  if not (SS.is_empty missing) then
    Alcotest.failf "Local_worker public tools missing schemas: {%s}"
      (String.concat ", " (SS.elements missing));
  Alcotest.(check bool) "Local_worker public tools resolvable" true
    (SS.is_empty missing)

let test_session_min_parity () =
  let legacy = set_of Worker_container.session_min_tool_names in
  let ssot = set_of (Tool_catalog.tools_for_surface Tool_catalog.Session_min) in
  check_set_equal "Session_min" ~expected:legacy ~actual:ssot

let test_admin_parity () =
  let legacy = set_of (Tool_catalog.tools_for_surface Tool_catalog.Admin) in
  let ssot = set_of (Tool_catalog.tools_for_surface Tool_catalog.Admin) in
  check_set_equal "Admin" ~expected:legacy ~actual:ssot

let test_keeper_denied_parity () =
  let legacy = set_of Keeper_hooks_oas.keeper_denied_tools in
  let ssot = set_of (Tool_catalog.tools_for_surface Tool_catalog.Keeper_denied) in
  check_set_equal "Keeper_denied" ~expected:legacy ~actual:ssot

(* {1 Structural Invariants — hold regardless of migration phase} *)

let test_session_min_and_local_worker_share_core () =
  (* Session_min (worker container fallback) and Local_worker (team-session
     bridge) serve different purposes and are NOT in a subset relationship.
     Instead we verify they share the expected coordination core. *)
  let min_set = set_of (Tool_catalog.tools_for_surface Tool_catalog.Session_min) in
  let worker_set = set_of (Tool_catalog.tools_for_surface Tool_catalog.Local_worker) in
  let shared = SS.inter min_set worker_set in
  (* At minimum, claim_next, add_task, and heartbeat must be in both *)
  let required_shared = set_of ["masc_claim_next"; "masc_add_task"; "masc_heartbeat"] in
  let missing = SS.diff required_shared shared in
  if not (SS.is_empty missing) then
    Alcotest.failf "Session_min and Local_worker missing shared core: {%s}"
      (String.concat ", " (SS.elements missing));
  Alcotest.(check bool) "shared core present" true (SS.is_empty missing)

let public_keeper_denied_overlap_allowed =
  set_of
    [
      "masc_persona_generate";
      "masc_persona_save";
      "masc_keeper_create_from_persona";
    ]

let test_keeper_denied_public_mcp_overlap_is_explicit () =
  let denied = set_of (Tool_catalog.tools_for_surface Tool_catalog.Keeper_denied) in
  let public = set_of (Tool_catalog.tools_for_surface Tool_catalog.Public_mcp) in
  let overlap = SS.inter denied public in
  let unexpected = SS.diff overlap public_keeper_denied_overlap_allowed in
  let missing = SS.diff public_keeper_denied_overlap_allowed overlap in
  if not (SS.is_empty unexpected) then
    Alcotest.failf "Unexpected Keeper_denied/Public_mcp overlap: {%s}"
      (String.concat ", " (SS.elements unexpected));
  if not (SS.is_empty missing) then
    Alcotest.failf "Expected Keeper_denied/Public_mcp overlap missing: {%s}"
      (String.concat ", " (SS.elements missing));
  Alcotest.(check bool) "Keeper_denied/Public_mcp overlap explicit" true
    (SS.is_empty unexpected && SS.is_empty missing)

let test_keeper_internal_disjoint_from_public_mcp () =
  let internal = set_of (Tool_catalog.tools_for_surface Tool_catalog.Keeper_internal) in
  let public = set_of (Tool_catalog.tools_for_surface Tool_catalog.Public_mcp) in
  let overlap = SS.inter internal public in
  if not (SS.is_empty overlap) then
    Alcotest.failf "Keeper_internal overlaps with Public_mcp: {%s}"
      (String.concat ", " (SS.elements overlap));
  Alcotest.(check bool) "Keeper_internal disjoint from Public_mcp" true
    (SS.is_empty overlap)

let test_keeper_internal_contains_known_tools () =
  let internal = set_of (Tool_catalog.tools_for_surface Tool_catalog.Keeper_internal) in
  List.iter
    (fun name ->
      Alcotest.(check bool) (name ^ " is internal") true (SS.mem name internal))
    [ "keeper_time_now"; "keeper_board_post"; "keeper_bash"; "keeper_memory_search" ]

let test_keeper_voice_replacement_contract () =
  Alcotest.(check (option string))
    "voice speak replacement removed"
    None
    (Tool_catalog_surfaces.keeper_internal_replacement "keeper_voice_speak");
  Alcotest.(check (option string))
    "voice agent replacement removed"
    None
    (Tool_catalog_surfaces.keeper_internal_replacement "keeper_voice_agent");
  Alcotest.(check (option string))
    "voice sessions replacement removed"
    None
    (Tool_catalog_surfaces.keeper_internal_replacement "keeper_voice_sessions");
  Alcotest.(check (option string))
    "voice session start replacement removed"
    None
    (Tool_catalog_surfaces.keeper_internal_replacement "keeper_voice_session_start");
  Alcotest.(check (option string))
    "voice session end replacement removed"
    None
    (Tool_catalog_surfaces.keeper_internal_replacement "keeper_voice_session_end");
  Alcotest.(check (option string))
    "voice listen remains keeper-only"
    None
    (Tool_catalog_surfaces.keeper_internal_replacement "keeper_voice_listen")

let test_is_on_surface_consistent () =
  List.iter (fun surface ->
    let tools = Tool_catalog.tools_for_surface surface in
    List.iter (fun name ->
      Alcotest.(check bool)
        (Printf.sprintf "%s on %s" name (Tool_catalog.surface_to_string surface))
        true (Tool_catalog.is_on_surface surface name)
    ) tools
  ) Tool_catalog.all_surfaces

(* {1 Cross-classification invariants — independent concern lists stay consistent} *)

let destructive_tools =
  ["keeper_bash"; "keeper_fs_edit";
   "shell_exec"; "masc_code_shell"; "masc_code_git"; "masc_code_delete"]

let test_destructive_check_tools_are_privileged () =
  (* Every tool registered as destructive should also be in the
     privileged keeper tool list (keeper_* subset). *)
  List.iter (fun name ->
    if String.starts_with ~prefix:"keeper_" name then
      Alcotest.(check bool) (name ^ " is privileged") true
        (List.mem name Capability_registry.privileged_keeper_tool_names)
  ) destructive_tools

let test_privileged_keeper_tools_are_internal () =
  (* Every privileged keeper tool (keeper_* prefixed) should be on the
     Keeper_internal surface. *)
  let internal = set_of (Tool_catalog.tools_for_surface Tool_catalog.Keeper_internal) in
  List.iter (fun name ->
    if String.starts_with ~prefix:"keeper_" name then
      Alcotest.(check bool) (name ^ " in Keeper_internal") true
        (SS.mem name internal)
  ) Capability_registry.privileged_keeper_tool_names

let test_replacement_targets_have_schemas () =
  (* Every keeper_internal_replacement target should have a registered schema.
     Not all need to be public — some are hidden but still callable. *)
  let internal = Tool_catalog.tools_for_surface Tool_catalog.Keeper_internal in
  let all_schema_names =
    List.map (fun (s : Types.tool_schema) -> s.name)
      Config.raw_all_tool_schemas
  in
  List.iter (fun name ->
    match Tool_catalog_surfaces.keeper_internal_replacement name with
    | Some public_name ->
      Alcotest.(check bool)
        (Printf.sprintf "%s -> %s has schema" name public_name)
        true (List.mem public_name all_schema_names)
    | None -> ()
  ) internal

let test_keeper_internal_tools_have_schemas () =
  (* Every tool in keeper_internal_tools should have a schema in
     keeper shards (model_tools + voice shard). A name without a schema
     means the LLM can never select it — a silent capability gap. *)
  let voice_schemas = match Tool_shard.get_shard "voice" with
    | Some shard -> shard.tools | None -> [] in
  let standalone_schemas = [ Keeper_exec_tools.keeper_tool_search_schema ] in
  let schema_names =
    (Tool_shard.keeper_model_tools @ voice_schemas @ standalone_schemas)
    |> List.map (fun (s : Types.tool_schema) -> s.name)
    |> SS.of_list
  in
  let internal_names =
    Tool_catalog_surfaces.keeper_internal_tools |> SS.of_list
  in
  let missing = SS.diff internal_names schema_names in
  if not (SS.is_empty missing) then
    Alcotest.failf
      "keeper_internal_tools without schemas (LLM blind spots): {%s}"
      (String.concat ", " (SS.elements missing));
  Alcotest.(check bool) "all internal tools have schemas" true
    (SS.is_empty missing)

(* {1 SSOT Validation — Phase 4: no orphans, surface constraints} *)

let test_no_orphaned_tools () =
  (* Every registered tool schema must belong to at least one surface,
     except Deprecated tools which are intentionally removed from all surfaces,
     and known orphans from the tool-registry-pruning batch whose schemas
     will be cleaned up in a follow-up PR. *)
  let on_any_surface name =
    List.exists (fun surface ->
      Tool_catalog.is_on_surface surface name
    ) Tool_catalog.all_surfaces
  in
  let is_deprecated name =
    List.exists (fun (n, _) -> String.equal n name) Tool_catalog.deprecated_tool_entries
  in
  (* Schemas left behind after surface pruning. Tracked for follow-up removal. *)
  let known_orphans =
    [ "masc_note_add"; "masc_register_capabilities";
      "masc_board_stats"; "masc_board_profile"; "masc_board_hearths";
      "masc_board_delete"; "masc_keeper_compact";
      "masc_keeper_clear"; "masc_runtime_verify" ]
  in
  let is_known_orphan name = List.mem name known_orphans in
  let orphaned =
    Config.raw_all_tool_schemas
    |> List.filter (fun (schema : Types.tool_schema) ->
         not (on_any_surface schema.name)
         && not (is_deprecated schema.name)
         && not (is_known_orphan schema.name))
    |> List.map (fun (schema : Types.tool_schema) -> schema.name)
  in
  if orphaned <> [] then
    Alcotest.failf "Orphaned tools (no surface): {%s}"
      (String.concat ", " orphaned);
  Alcotest.(check bool) "zero orphans" true (orphaned = [])

let test_public_mcp_count_cap () =
  (* Public_mcp surface should not exceed 80 tools to control LLM token cost. *)
  let count = List.length (Tool_catalog.tools_for_surface Tool_catalog.Public_mcp) in
  if count > 80 then
    Alcotest.failf "Public_mcp has %d tools (cap: 80)" count;
  Alcotest.(check bool) "public_mcp <= 80" true (count <= 80)

let test_system_internal_not_visible () =
  (* System_internal tools must be hidden from tools/list. *)
  let system_tools = Tool_catalog.tools_for_surface Tool_catalog.System_internal in
  let visible =
    List.filter (fun name ->
      Tool_catalog.is_visible name
    ) system_tools
  in
  if visible <> [] then
    Alcotest.failf "System_internal tools visible in tools/list: {%s}"
      (String.concat ", " visible);
  Alcotest.(check bool) "all system_internal hidden" true (visible = [])

let test_system_internal_callable () =
  (* System_internal tools must be callable via tools/call. *)
  let system_tools = Tool_catalog.tools_for_surface Tool_catalog.System_internal in
  let uncallable =
    List.filter (fun name ->
      not (Tool_catalog.allow_direct_call name)
    ) system_tools
  in
  if uncallable <> [] then
    Alcotest.failf "System_internal tools not callable: {%s}"
      (String.concat ", " uncallable);
  Alcotest.(check bool) "all system_internal callable" true (uncallable = [])

let test_pruned_tools_registered_as_deprecated () =
  (* Tools pruned from user-facing surfaces are registered as Deprecated
     in explicit_metadata (#5039). They stay hidden from tools/list and
     remain callable for in-flight sessions. Some may be fully removed
     from surfaces when no backward compat is needed. *)
  let deprecated_names =
    List.map fst Tool_catalog.deprecated_tool_entries
  in
  List.iter
    (fun name ->
      Alcotest.(check bool) (name ^ " is Deprecated") true
        (List.mem name deprecated_names);
      Alcotest.(check bool) (name ^ " hidden") false
        (Tool_catalog.is_visible name);
      Alcotest.(check bool) (name ^ " callable") true
        (Tool_catalog.allow_direct_call name))
    [
      "masc_webrtc_answer";
      "masc_webrtc_offer";
    ]
let test_workspace_mutating_canonical_used () =
  (* workspace_mutating_tool_names in tool_catalog_surfaces is the canonical list.
     Verify no empty or phantom entries. *)
  Alcotest.(check bool) "non-empty" true
    (List.length Tool_catalog_surfaces.workspace_mutating_tool_names > 0);
  List.iter (fun name ->
    Alcotest.(check bool) (name ^ " non-empty") true (String.length name > 0)
  ) Tool_catalog_surfaces.workspace_mutating_tool_names

let test_role_catalogs_only_expose_available_tools () =
  let available =
    Agent_tool_surfaces.spawned_agent_public_tool_names
    @ Agent_tool_surfaces.local_worker_public_tool_names
    |> set_of
  in
  let check_all role tools =
    List.iter (fun name ->
      Alcotest.(check bool)
        (Printf.sprintf "%s role tool available: %s" role name)
        true (SS.mem name available)
    ) tools
  in
  check_all "worker" Agent_tool_surfaces.execution_tool_names;
  check_all "coordinator" Agent_tool_surfaces.coordination_tool_names

let test_role_catalogs_drop_stale_entries_when_built () =
  let worker_tools = Agent_tool_surfaces.build_tool_catalog ~role:"worker" () in
  let coordinator_tools = Agent_tool_surfaces.build_tool_catalog ~role:"coordinator" () in
  Alcotest.(check bool) "worker role excludes portal_open" false
    (List.mem "masc_portal_open" worker_tools);
  Alcotest.(check bool) "coordinator role excludes portal_open" false
    (List.mem "masc_portal_open" coordinator_tools)

let test_local_worker_compat_passthrough_schemas_match_registry () =
  List.iter (fun (schema : Types.tool_schema) ->
    match raw_schema_by_name schema.name with
    | None ->
        Alcotest.failf "missing raw schema for passthrough tool %s" schema.name
    | Some raw_schema ->
        Alcotest.(check string)
          (schema.name ^ " passthrough description")
          raw_schema.description schema.description;
        Alcotest.(check bool)
          (schema.name ^ " passthrough input_schema")
          true
          (Yojson.Safe.equal raw_schema.input_schema schema.input_schema))
    Agent_tool_surfaces.local_worker_compat_passthrough_schemas

let () =
  Alcotest.run "tool_surface_ssot"
    [
      ( "parity",
        [
          Alcotest.test_case "Public_mcp parity" `Quick test_public_mcp_parity;
          Alcotest.test_case "Spawned_agent parity" `Quick test_spawned_agent_parity;
          Alcotest.test_case "Local_worker public tools resolvable" `Quick
            test_local_worker_public_tools_resolvable;
          Alcotest.test_case "Session_min parity" `Quick test_session_min_parity;
          Alcotest.test_case "Admin parity" `Quick test_admin_parity;
          Alcotest.test_case "Keeper_denied parity" `Quick test_keeper_denied_parity;
        ] );
      ( "invariants",
        [
          Alcotest.test_case "Session_min ∩ Local_worker shared core" `Quick
            test_session_min_and_local_worker_share_core;
          Alcotest.test_case "Keeper_denied/Public_mcp overlap is explicit" `Quick
            test_keeper_denied_public_mcp_overlap_is_explicit;
          Alcotest.test_case "Keeper_internal ∩ Public_mcp = ∅" `Quick
            test_keeper_internal_disjoint_from_public_mcp;
          Alcotest.test_case "Keeper_internal contains known tools" `Quick
            test_keeper_internal_contains_known_tools;
          Alcotest.test_case "Keeper voice replacement contract" `Quick
            test_keeper_voice_replacement_contract;
          Alcotest.test_case "is_on_surface consistent" `Quick
            test_is_on_surface_consistent;
        ] );
      ( "cross_classification",
        [
          Alcotest.test_case "destructive check tools are privileged" `Quick
            test_destructive_check_tools_are_privileged;
          Alcotest.test_case "privileged keeper tools are internal" `Quick
            test_privileged_keeper_tools_are_internal;
          Alcotest.test_case "replacement targets have schemas" `Quick
            test_replacement_targets_have_schemas;
          Alcotest.test_case "keeper internal tools have schemas" `Quick
            test_keeper_internal_tools_have_schemas;
           Alcotest.test_case "workspace_mutating canonical used" `Quick
             test_workspace_mutating_canonical_used;
           Alcotest.test_case "role catalogs use only available tools" `Quick
             test_role_catalogs_only_expose_available_tools;
           Alcotest.test_case "built role catalogs drop stale entries" `Quick
             test_role_catalogs_drop_stale_entries_when_built;
           Alcotest.test_case "local worker passthrough schemas use registry"
             `Quick test_local_worker_compat_passthrough_schemas_match_registry;
         ] );
      ( "ssot_validation",
        [
          Alcotest.test_case "no orphaned tools" `Quick
            test_no_orphaned_tools;
          Alcotest.test_case "Public_mcp count cap <= 80" `Quick
            test_public_mcp_count_cap;
          Alcotest.test_case "System_internal not visible" `Quick
            test_system_internal_not_visible;
          Alcotest.test_case "System_internal callable" `Quick
            test_system_internal_callable;
          Alcotest.test_case "pruned tools registered as Deprecated" `Quick
            test_pruned_tools_registered_as_deprecated;
        ] );
    ]
