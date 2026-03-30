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

(* {1 Parity Tests — each compares legacy hardcoded list vs surface SSOT} *)

let test_public_mcp_parity () =
  let legacy = set_of Tool_catalog.public_mcp_tools in
  let ssot = set_of (Tool_catalog.tools_for_surface Tool_catalog.Public_mcp) in
  check_set_equal "Public_mcp" ~expected:legacy ~actual:ssot

let test_spawned_agent_parity () =
  let legacy = set_of Agent_tool_surfaces.spawned_agent_public_tool_names in
  let ssot = set_of (Tool_catalog.tools_for_surface Tool_catalog.Spawned_agent) in
  check_set_equal "Spawned_agent" ~expected:legacy ~actual:ssot

let test_local_worker_parity () =
  let legacy = set_of Team_session_oas_bridge.supported_local_worker_tool_names in
  let ssot = set_of (Tool_catalog.tools_for_surface Tool_catalog.Local_worker) in
  check_set_equal "Local_worker" ~expected:legacy ~actual:ssot

let test_session_min_parity () =
  let legacy = set_of Worker_container.session_min_tool_names in
  let ssot = set_of (Tool_catalog.tools_for_surface Tool_catalog.Session_min) in
  check_set_equal "Session_min" ~expected:legacy ~actual:ssot

let test_admin_parity () =
  let legacy = set_of Tool_permissions.admin_tools in
  let ssot = set_of (Tool_catalog.tools_for_surface Tool_catalog.Admin) in
  check_set_equal "Admin" ~expected:legacy ~actual:ssot

let test_keeper_denied_parity () =
  let legacy = set_of Keeper_hooks_oas.keeper_denied_tools in
  let ssot = set_of (Tool_catalog.tools_for_surface Tool_catalog.Keeper_denied) in
  check_set_equal "Keeper_denied" ~expected:legacy ~actual:ssot

let test_mdal_auditable_parity () =
  let legacy = set_of Agent_tool_surfaces.mdal_auditable_tool_names in
  let ssot = set_of (Tool_catalog.tools_for_surface Tool_catalog.Mdal_auditable) in
  check_set_equal "Mdal_auditable" ~expected:legacy ~actual:ssot

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

let test_keeper_denied_disjoint_from_public_mcp () =
  let denied = set_of (Tool_catalog.tools_for_surface Tool_catalog.Keeper_denied) in
  let public = set_of (Tool_catalog.tools_for_surface Tool_catalog.Public_mcp) in
  let overlap = SS.inter denied public in
  if not (SS.is_empty overlap) then
    Alcotest.failf "Keeper_denied overlaps with Public_mcp: {%s}"
      (String.concat ", " (SS.elements overlap));
  Alcotest.(check bool) "Keeper_denied disjoint from Public_mcp" true
    (SS.is_empty overlap)

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
    [ "keeper_time_now"; "keeper_board_post"; "keeper_bash"; "keeper_search" ]

let test_is_on_surface_consistent () =
  List.iter (fun surface ->
    let tools = Tool_catalog.tools_for_surface surface in
    List.iter (fun name ->
      Alcotest.(check bool)
        (Printf.sprintf "%s on %s" name (Tool_catalog.surface_to_string surface))
        true (Tool_catalog.is_on_surface surface name)
    ) tools
  ) Tool_catalog.all_surfaces

let () =
  Alcotest.run "tool_surface_ssot"
    [
      ( "parity",
        [
          Alcotest.test_case "Public_mcp parity" `Quick test_public_mcp_parity;
          Alcotest.test_case "Spawned_agent parity" `Quick test_spawned_agent_parity;
          Alcotest.test_case "Local_worker parity" `Quick test_local_worker_parity;
          Alcotest.test_case "Session_min parity" `Quick test_session_min_parity;
          Alcotest.test_case "Admin parity" `Quick test_admin_parity;
          Alcotest.test_case "Keeper_denied parity" `Quick test_keeper_denied_parity;
          Alcotest.test_case "Mdal_auditable parity" `Quick test_mdal_auditable_parity;
        ] );
      ( "invariants",
        [
          Alcotest.test_case "Session_min ∩ Local_worker shared core" `Quick
            test_session_min_and_local_worker_share_core;
          Alcotest.test_case "Keeper_denied ∩ Public_mcp = ∅" `Quick
            test_keeper_denied_disjoint_from_public_mcp;
          Alcotest.test_case "Keeper_internal ∩ Public_mcp = ∅" `Quick
            test_keeper_internal_disjoint_from_public_mcp;
          Alcotest.test_case "Keeper_internal contains known tools" `Quick
            test_keeper_internal_contains_known_tools;
          Alcotest.test_case "is_on_surface consistent" `Quick
            test_is_on_surface_consistent;
        ] );
    ]
