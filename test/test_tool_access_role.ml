module Types = Masc_domain

(** Tests for Tool_access_role — role-based policy equivalence and properties.

    The equivalence test is the critical gate: it verifies that the new
    policy_for_role produces identical allow/deny decisions to the legacy
    permission_for_tool + has_permission system for every registered tool
    and every role. *)

open Alcotest
open Masc_mcp

(* ================================================================ *)
(* Old system simulation (from legacy_permission_for_tool)           *)
(* ================================================================ *)

(** Simulate the old authorization logic:
    permission_for_tool(tool) → permission option
    has_permission(role, permission) → bool

    Tests at the POLICY level (not authorization level).
    Strict mode checks happen in authorize_tool_v2, not in the policy.
    For mapped tools, this matches both strict and non-strict behavior.
    For unmapped tools (None), the policy allows them (All-based),
    matching the non-strict fail-open path. Strict mode is an
    authorization-level overlay tested separately. *)
let old_allows (role : Masc_domain.agent_role) (tool_name : string) : bool =
  match Auth.permission_for_tool tool_name with
  | None -> true  (* Policy level: fail-open for unmapped tools *)
  | Some perm -> Masc_domain.has_permission role perm

let testable_permission =
  testable
    (Fmt.of_to_string Masc_domain.show_permission)
    (fun a b -> a = b)

(* ================================================================ *)
(* Equivalence tests                                                 *)
(* ================================================================ *)

(** Collect all tool names from all surfaces. *)
let all_surface_tools () =
  Tool_catalog.all_surfaces
  |> List.concat_map Tool_catalog.tools_for_surface
  |> List.sort_uniq String.compare

let test_equivalence_admin () =
  let tools = all_surface_tools () in
  List.iter (fun tool_name ->
    let old_result = old_allows Admin tool_name in
    let new_result =
      Tool_access_policy.allows_name
        (Tool_access_role.policy_for_role Admin) tool_name
    in
    check bool
      (Printf.sprintf "Admin/%s" tool_name)
      old_result new_result
  ) tools

let test_equivalence_worker () =
  let tools = all_surface_tools () in
  List.iter (fun tool_name ->
    let old_result = old_allows Worker tool_name in
    let new_result =
      Tool_access_policy.allows_name
        (Tool_access_role.policy_for_role Worker) tool_name
    in
    check bool
      (Printf.sprintf "Worker/%s" tool_name)
      old_result new_result
  ) tools

(* ================================================================ *)
(* Hierarchy tests                                                   *)
(* ================================================================ *)

let test_worker_subset_of_admin () =
  let tools = all_surface_tools () in
  let worker_policy = Tool_access_role.policy_for_role Worker in
  let admin_policy = Tool_access_role.policy_for_role Admin in
  List.iter (fun tool_name ->
    let worker_allows = Tool_access_policy.allows_name worker_policy tool_name in
    let admin_allows = Tool_access_policy.allows_name admin_policy tool_name in
    if worker_allows then
      check bool
        (Printf.sprintf "Worker allows %s, Admin must too" tool_name)
        true admin_allows
  ) tools

(* ================================================================ *)
(* Admin surface denial tests                                        *)
(* ================================================================ *)

let test_worker_denies_admin_only_tools () =
  let worker_policy = Tool_access_role.policy_for_role Worker in
  List.iter (fun tool_name ->
    check bool
      (Printf.sprintf "Worker denies %s" tool_name)
      false
      (Tool_access_policy.allows_name worker_policy tool_name)
  ) (Tool_access_role.admin_only_tools ())

let test_admin_allows_admin_only_tools () =
  let admin_policy = Tool_access_role.policy_for_role Admin in
  List.iter (fun tool_name ->
    check bool
      (Printf.sprintf "Admin allows %s" tool_name)
      true
      (Tool_access_policy.allows_name admin_policy tool_name)
  ) (Tool_access_role.admin_only_tools ())

let test_worker_allows_worker_only_tools () =
  let worker_policy = Tool_access_role.policy_for_role Worker in
  List.iter (fun tool_name ->
    check bool
      (Printf.sprintf "Worker allows %s" tool_name)
      true
      (Tool_access_policy.allows_name worker_policy tool_name)
  ) (Tool_access_role.worker_only_tools ())

let test_channel_gate_requires_worker () =
  let worker_policy = Tool_access_role.policy_for_role Worker in
  check bool "Worker allows channel_gate" true
    (Tool_access_policy.allows_name worker_policy "channel_gate")

let test_portal_tools_require_worker () =
  let worker_policy = Tool_access_role.policy_for_role Worker in
  List.iter (fun tool_name ->
    check bool
      (Printf.sprintf "Worker allows %s" tool_name)
      true
      (Tool_access_policy.allows_name worker_policy tool_name))
    [ "masc_portal_open"; "masc_portal_close"; "masc_portal_send" ]

let test_permissions_promoted_to_metadata_ssot () =
  ignore
    (Masc_mcp.Mcp_server_eio.create_state ~test_mode:true
       ~base_path:"/tmp/masc-permission-metadata-ssot" ());
  let expectations =
    [
      ("masc_status", Masc_domain.CanReadState);
      ("masc_add_task", Masc_domain.CanAddTask);
      ("masc_board_list", Masc_domain.CanReadState);
      (* CP purge: masc_operator_action, masc_unit_list and other command-plane
         tool metadata expectations removed with deletion of lib/command_plane/. *)
      ("masc_worktree_create", Masc_domain.CanCreateWorktree);
      ("masc_autoresearch_record_finding", Masc_domain.CanAdmin);
      ("masc_autoresearch_search_findings", Masc_domain.CanReadState);
      ("masc_autoresearch_status", Masc_domain.CanReadState);
      ("masc_agent_card", Masc_domain.CanReadState);
      ("masc_heartbeat", Masc_domain.CanBroadcast);
      ("masc_config", Masc_domain.CanReadState);
      ("masc_team_memory_read", Masc_domain.CanReadState);
      ("masc_team_memory_search", Masc_domain.CanReadState);
      ("masc_team_memory_write", Masc_domain.CanBroadcast);
      ("masc_tool_list", Masc_domain.CanReadState);
      ("masc_tool_admin_snapshot", Masc_domain.CanAdmin);
      ("masc_runtime_verify", Masc_domain.CanReadState);
      ("masc_persona_list", Masc_domain.CanReadState);
      ("masc_persona_schema", Masc_domain.CanReadState);
      ("masc_persona_generate", Masc_domain.CanBroadcast);
      ("masc_persona_save", Masc_domain.CanBroadcast);
      ("masc_keeper_reset", Masc_domain.CanBroadcast);
      ("masc_join", Masc_domain.CanJoin);
      ("masc_broadcast", Masc_domain.CanBroadcast);
      ("masc_portal_send", Masc_domain.CanSendPortal);
      ("channel_gate", Masc_domain.CanBroadcast);
    ]
  in
  List.iter
    (fun (tool_name, expected_permission) ->
      let meta = Tool_catalog.metadata tool_name in
      check (option testable_permission)
        (Printf.sprintf "%s uses metadata permission" tool_name)
        (Some expected_permission)
        meta.required_permission)
    expectations

(* ================================================================ *)
(* Unregistered tool behavior                                        *)
(* ================================================================ *)

let test_unregistered_tool_allowed_all_roles () =
  let unknown = "masc_future_unknown_tool_xyz" in
  List.iter (fun (role_name, role) ->
    let policy = Tool_access_role.policy_for_role role in
    check bool
      (Printf.sprintf "%s: unregistered tool allowed (fail-open)" role_name)
      true
      (Tool_access_policy.allows_name policy unknown)
  ) [("Admin", Admin); ("Worker", Worker)]

let test_empty_string_tool_allowed () =
  let policy = Tool_access_role.policy_for_role Worker in
  check bool "empty string tool allowed by All"
    true
    (Tool_access_policy.allows_name policy "")

(* ================================================================ *)
(* Tool list integrity tests                                         *)
(* ================================================================ *)

let test_admin_only_count () =
  let admin_only_tools = Tool_access_role.admin_only_tools () in
  let n = List.length admin_only_tools in
  check bool "admin_only_tools is non-empty" true (n > 0);
  check bool "admin_only_tools has no duplicates" true
    (List.length (List.sort_uniq String.compare admin_only_tools) = n)

let test_worker_only_count () =
  let worker_only_tools = Tool_access_role.worker_only_tools () in
  let n = List.length worker_only_tools in
  check bool "worker_only_tools is non-empty" true (n > 0);
  check bool "worker_only_tools has no duplicates" true
    (List.length (List.sort_uniq String.compare worker_only_tools) = n)

let test_no_overlap_admin_worker () =
  let admin_only_tools = Tool_access_role.admin_only_tools () in
  let worker_only_tools = Tool_access_role.worker_only_tools () in
  List.iter (fun tool_name ->
    check bool
      (Printf.sprintf "%s not in both admin and worker lists" tool_name)
      false
      (List.mem tool_name worker_only_tools)
  ) admin_only_tools

(* ================================================================ *)
(* Runner                                                            *)
(* ================================================================ *)

let () =
  run "Tool_access_role"
    [
      ( "equivalence",
        [
          test_case "Admin: old == new" `Quick test_equivalence_admin;
          test_case "Worker: old == new" `Quick test_equivalence_worker;
        ] );
      ( "hierarchy",
        [
          test_case "Worker ⊂ Admin" `Quick test_worker_subset_of_admin;
        ] );
      ( "role_boundaries",
        [
          test_case "Worker denies admin_only" `Quick
            test_worker_denies_admin_only_tools;
          test_case "Admin allows admin_only" `Quick
            test_admin_allows_admin_only_tools;
          test_case "Worker allows worker_only" `Quick
            test_worker_allows_worker_only_tools;
          test_case "channel_gate requires worker" `Quick
            test_channel_gate_requires_worker;
          test_case "portal tools require worker" `Quick
            test_portal_tools_require_worker;
          test_case "permissions promoted to metadata ssot" `Quick
            test_permissions_promoted_to_metadata_ssot;
        ] );
      ( "unregistered",
        [
          test_case "unregistered allowed (fail-open)" `Quick
            test_unregistered_tool_allowed_all_roles;
          test_case "empty string tool" `Quick
            test_empty_string_tool_allowed;
        ] );
      ( "integrity",
        [
          test_case "admin_only count" `Quick test_admin_only_count;
          test_case "worker_only count" `Quick test_worker_only_count;
          test_case "no overlap admin/worker" `Quick
            test_no_overlap_admin_worker;
        ] );
    ]
