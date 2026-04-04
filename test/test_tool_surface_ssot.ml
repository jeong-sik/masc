(** test_tool_surface_ssot — Surface SSOT tests for 3-surface system.

    Verifies that [Tool_catalog.tools_for_surface] produces consistent
    sets for the three surfaces: Public, Keeper, System. *)

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

(* {1 Parity Tests — public_mcp_tools alias matches Public surface} *)

let test_public_parity () =
  let legacy = set_of Tool_catalog.public_mcp_tools in
  let ssot = set_of (Tool_catalog.tools_for_surface Tool_catalog.Public) in
  check_set_equal "Public" ~expected:legacy ~actual:ssot

(* {1 Structural Invariants} *)

let test_keeper_disjoint_from_public () =
  let keeper = set_of (Tool_catalog.tools_for_surface Tool_catalog.Keeper) in
  let public = set_of (Tool_catalog.tools_for_surface Tool_catalog.Public) in
  let overlap = SS.inter keeper public in
  if not (SS.is_empty overlap) then
    Alcotest.failf "Keeper overlaps with Public: {%s}"
      (String.concat ", " (SS.elements overlap));
  Alcotest.(check bool) "Keeper disjoint from Public" true
    (SS.is_empty overlap)

let test_keeper_contains_known_tools () =
  let keeper = set_of (Tool_catalog.tools_for_surface Tool_catalog.Keeper) in
  List.iter
    (fun name ->
      Alcotest.(check bool) (name ^ " is keeper") true (SS.mem name keeper))
    [ "keeper_time_now"; "keeper_board_post"; "keeper_bash"; "keeper_memory_search" ]

let test_keeper_voice_replacement_contract () =
  Alcotest.(check (option string))
    "voice speak maps to hidden public tool"
    (Some "masc_voice_speak")
    (Tool_catalog_surfaces.keeper_internal_replacement "keeper_voice_speak");
  Alcotest.(check (option string))
    "voice agent maps to hidden public tool"
    (Some "masc_voice_agent")
    (Tool_catalog_surfaces.keeper_internal_replacement "keeper_voice_agent");
  Alcotest.(check (option string))
    "voice sessions map to hidden public tool"
    (Some "masc_voice_sessions")
    (Tool_catalog_surfaces.keeper_internal_replacement "keeper_voice_sessions");
  Alcotest.(check (option string))
    "voice session start maps to hidden public tool"
    (Some "masc_voice_session_start")
    (Tool_catalog_surfaces.keeper_internal_replacement "keeper_voice_session_start");
  Alcotest.(check (option string))
    "voice session end maps to hidden public tool"
    (Some "masc_voice_session_end")
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

(* {1 Cross-classification invariants} *)

let test_destructive_check_tools_are_privileged () =
  List.iter (fun name ->
    Alcotest.(check bool) (name ^ " is privileged") true
      (List.mem name Capability_registry.privileged_keeper_tool_names)
  ) Keeper_hooks_oas.destructive_check_tools

let test_privileged_keeper_tools_are_keeper () =
  let keeper = set_of (Tool_catalog.tools_for_surface Tool_catalog.Keeper) in
  List.iter (fun name ->
    if String.starts_with ~prefix:"keeper_" name then
      Alcotest.(check bool) (name ^ " in Keeper") true
        (SS.mem name keeper)
  ) Capability_registry.privileged_keeper_tool_names

let test_replacement_targets_have_schemas () =
  let keeper = Tool_catalog.tools_for_surface Tool_catalog.Keeper in
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
  ) keeper

let test_keeper_internal_tools_have_schemas () =
  let voice_schemas = match Tool_shard.get_shard "voice" with
    | Some shard -> shard.tools | None -> [] in
  let schema_names =
    (Tool_shard.keeper_model_tools @ voice_schemas)
    |> List.map (fun (s : Types.tool_schema) -> s.name)
    |> SS.of_list
  in
  let internal_names =
    Tool_catalog_surfaces.keeper_internal_tools |> SS.of_list
  in
  let missing = SS.diff internal_names schema_names in
  if not (SS.is_empty missing) then
    Alcotest.failf
      "keeper tools without schemas (LLM blind spots): {%s}"
      (String.concat ", " (SS.elements missing));
  Alcotest.(check bool) "all keeper tools have schemas" true
    (SS.is_empty missing)

(* {1 SSOT Validation} *)

let test_no_orphaned_tools () =
  let on_any_surface name =
    List.exists (fun surface ->
      Tool_catalog.is_on_surface surface name
    ) Tool_catalog.all_surfaces
  in
  let is_deprecated name =
    List.exists (fun (n, _) -> String.equal n name) Tool_catalog.deprecated_tool_entries
  in
  let orphaned =
    Config.raw_all_tool_schemas
    |> List.filter (fun (schema : Types.tool_schema) ->
         not (on_any_surface schema.name) && not (is_deprecated schema.name))
    |> List.map (fun (schema : Types.tool_schema) -> schema.name)
  in
  if orphaned <> [] then
    Alcotest.failf "Orphaned tools (no surface): {%s}"
      (String.concat ", " orphaned);
  Alcotest.(check bool) "zero orphans" true (orphaned = [])

let test_public_count_cap () =
  let count = List.length (Tool_catalog.tools_for_surface Tool_catalog.Public) in
  if count > 80 then
    Alcotest.failf "Public has %d tools (cap: 80)" count;
  Alcotest.(check bool) "public <= 80" true (count <= 80)

let test_system_not_visible () =
  let system_tools = Tool_catalog.tools_for_surface Tool_catalog.System in
  let visible =
    List.filter (fun name ->
      Tool_catalog.is_visible name
    ) system_tools
  in
  if visible <> [] then
    Alcotest.failf "System tools visible in tools/list: {%s}"
      (String.concat ", " visible);
  Alcotest.(check bool) "all system hidden" true (visible = [])

let test_system_callable () =
  let system_tools = Tool_catalog.tools_for_surface Tool_catalog.System in
  let uncallable =
    List.filter (fun name ->
      not (Tool_catalog.allow_direct_call name)
    ) system_tools
  in
  if uncallable <> [] then
    Alcotest.failf "System tools not callable: {%s}"
      (String.concat ", " uncallable);
  Alcotest.(check bool) "all system callable" true (uncallable = [])

let test_pruned_tools_registered_as_deprecated () =
  (* Tools pruned from user-facing surfaces in #4999 are registered as
     Deprecated in explicit_metadata (#5039). They remain on System_internal
     for backward compat but carry Deprecated lifecycle. *)
  let deprecated_names =
    List.map fst Tool_catalog.deprecated_tool_entries
  in
  List.iter
    (fun name ->
      Alcotest.(check bool) (name ^ " is Deprecated") true
        (List.mem name deprecated_names);
      Alcotest.(check bool) (name ^ " on System_internal") true
        (Tool_catalog.is_on_surface Tool_catalog.System_internal name);
      Alcotest.(check bool) (name ^ " hidden") false
        (Tool_catalog.is_visible name))
    [
      "masc_a2a_delegate";
      "masc_a2a_discover";
      "masc_a2a_query_skill";
      "masc_a2a_subscribe";
      "masc_a2a_unsubscribe";
      "masc_board_migrate";
      "masc_board_reclassify";
      "masc_episode_flush";
      "masc_episode_list";
      "masc_portal_close";
      "masc_portal_open";
      "masc_portal_send";
      "masc_portal_status";
      "masc_transport_status";
      "masc_websocket_discovery";
      "masc_webrtc_answer";
      "masc_webrtc_offer";
      "masc_voice_agent";
      "masc_voice_conference_end";
      "masc_voice_speak";
      "masc_voice_conference_start";
      "masc_voice_ping_pong";
      "masc_voice_session_end";
      "masc_voice_session_start";
      "masc_voice_sessions";
    ]

let test_workspace_mutating_canonical_used () =
  Alcotest.(check bool) "non-empty" true
    (List.length Tool_catalog_surfaces.workspace_mutating_tool_names > 0);
  List.iter (fun name ->
    Alcotest.(check bool) (name ^ " non-empty") true (String.length name > 0)
  ) Tool_catalog_surfaces.workspace_mutating_tool_names

let () =
  Alcotest.run "tool_surface_ssot"
    [
      ( "parity",
        [
          Alcotest.test_case "Public parity" `Quick test_public_parity;
        ] );
      ( "invariants",
        [
          Alcotest.test_case "Keeper disjoint from Public" `Quick
            test_keeper_disjoint_from_public;
          Alcotest.test_case "Keeper contains known tools" `Quick
            test_keeper_contains_known_tools;
          Alcotest.test_case "is_on_surface consistent" `Quick
            test_is_on_surface_consistent;
        ] );
      ( "cross_classification",
        [
          Alcotest.test_case "destructive check tools are privileged" `Quick
            test_destructive_check_tools_are_privileged;
          Alcotest.test_case "privileged keeper tools are keeper" `Quick
            test_privileged_keeper_tools_are_keeper;
          Alcotest.test_case "replacement targets have schemas" `Quick
            test_replacement_targets_have_schemas;
          Alcotest.test_case "keeper tools have schemas" `Quick
            test_keeper_internal_tools_have_schemas;
          Alcotest.test_case "workspace_mutating canonical used" `Quick
            test_workspace_mutating_canonical_used;
        ] );
      ( "ssot_validation",
        [
          Alcotest.test_case "no orphaned tools" `Quick
            test_no_orphaned_tools;
          Alcotest.test_case "Public count cap <= 80" `Quick
            test_public_count_cap;
          Alcotest.test_case "System not visible" `Quick
            test_system_not_visible;
          Alcotest.test_case "System callable" `Quick
            test_system_callable;
        ] );
    ]
