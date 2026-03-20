(** Tests for Tool_permissions — capability-based access control *)

module Tool_dispatch = Masc_mcp.Tool_dispatch
module Tool_permissions = Masc_mcp.Tool_permissions
module Tool_result = Masc_mcp.Tool_result

let setup () =
  Tool_dispatch.clear_hooks ();
  (* Reset capability checker to deny all *)
  Tool_permissions.set_capability_checker (fun _agent _cap -> false)

(* --- requires_admin tests --- *)

let test_admin_tools_classified () =
  Alcotest.(check bool) "operator_action is admin"
    true (Tool_permissions.requires_admin "masc_operator_action");
  Alcotest.(check bool) "tool_admin_snapshot is admin"
    true (Tool_permissions.requires_admin "masc_tool_admin_snapshot");
  Alcotest.(check bool) "operator_confirm is admin"
    true (Tool_permissions.requires_admin "masc_operator_confirm");
  Alcotest.(check bool) "status is not admin"
    false (Tool_permissions.requires_admin "masc_status");
  Alcotest.(check bool) "heartbeat is not admin"
    false (Tool_permissions.requires_admin "masc_heartbeat")

(* --- check tests --- *)

let test_check_allows_non_admin () =
  setup ();
  Alcotest.(check bool) "non-admin tool allowed"
    true
    (Result.is_ok (Tool_permissions.check
       ~agent_name:"anyone" ~tool_name:"masc_status"))

let test_check_denies_admin_without_cap () =
  setup ();
  Alcotest.(check bool) "admin tool denied"
    true
    (Result.is_error (Tool_permissions.check
       ~agent_name:"normal_agent" ~tool_name:"masc_operator_action"))

let test_check_allows_admin_with_cap () =
  setup ();
  Tool_permissions.set_capability_checker (fun _agent cap -> cap = "admin");
  Alcotest.(check bool) "admin tool allowed with cap"
    true
    (Result.is_ok (Tool_permissions.check
       ~agent_name:"admin_agent" ~tool_name:"masc_operator_action"))

(* --- pre-hook integration tests --- *)

let test_hook_blocks_admin_no_identity () =
  setup ();
  Tool_dispatch.register
    ~tool_name:"masc_operator_action"
    ~handler:(fun ~name:_ ~args:_ -> Some (true, "should not reach"));
  Tool_permissions.install ~get_agent_name:(fun () -> None);
  match Tool_dispatch.dispatch_structured
          ~name:"masc_operator_action" ~args:`Null with
  | Some r ->
    Alcotest.(check bool) "blocked" false r.success
  | None -> Alcotest.fail "expected Some from short-circuit"

let test_hook_blocks_admin_no_cap () =
  setup ();
  Tool_dispatch.register
    ~tool_name:"masc_tool_admin_snapshot"
    ~handler:(fun ~name:_ ~args:_ -> Some (true, "should not reach"));
  Tool_permissions.set_capability_checker (fun _agent _cap -> false);
  Tool_permissions.install ~get_agent_name:(fun () -> Some "normal");
  match Tool_dispatch.dispatch_structured
          ~name:"masc_tool_admin_snapshot" ~args:`Null with
  | Some r ->
    Alcotest.(check bool) "blocked" false r.success
  | None -> Alcotest.fail "expected Some from short-circuit"

let test_hook_allows_admin_with_cap () =
  setup ();
  Tool_dispatch.register
    ~tool_name:"masc_operator_confirm"
    ~handler:(fun ~name:_ ~args:_ -> Some (true, "allowed"));
  Tool_permissions.set_capability_checker (fun _agent cap -> cap = "admin");
  Tool_permissions.install ~get_agent_name:(fun () -> Some "admin_agent");
  match Tool_dispatch.dispatch_structured
          ~name:"masc_operator_confirm" ~args:`Null with
  | Some r ->
    Alcotest.(check bool) "allowed" true r.success
  | None -> Alcotest.fail "expected Some"

let test_hook_allows_non_admin () =
  setup ();
  Tool_dispatch.register
    ~tool_name:"masc_status"
    ~handler:(fun ~name:_ ~args:_ -> Some (true, "ok"));
  Tool_permissions.install ~get_agent_name:(fun () -> Some "anyone");
  match Tool_dispatch.dispatch_structured ~name:"masc_status" ~args:`Null with
  | Some r ->
    Alcotest.(check bool) "allowed" true r.success
  | None -> Alcotest.fail "expected Some"

let () =
  Alcotest.run "Tool_permissions" [
    "classification", [
      Alcotest.test_case "admin tools" `Quick test_admin_tools_classified;
    ];
    "check", [
      Alcotest.test_case "allows non-admin" `Quick test_check_allows_non_admin;
      Alcotest.test_case "denies without cap" `Quick test_check_denies_admin_without_cap;
      Alcotest.test_case "allows with cap" `Quick test_check_allows_admin_with_cap;
    ];
    "hook", [
      Alcotest.test_case "blocks no identity" `Quick test_hook_blocks_admin_no_identity;
      Alcotest.test_case "blocks no cap" `Quick test_hook_blocks_admin_no_cap;
      Alcotest.test_case "allows admin cap" `Quick test_hook_allows_admin_with_cap;
      Alcotest.test_case "allows non-admin" `Quick test_hook_allows_non_admin;
    ];
  ]
