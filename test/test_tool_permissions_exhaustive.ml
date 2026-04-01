(** Exhaustive permission enforcement tests.

    Supplements test_tool_permissions.ml with:
    1. Sweeps ALL admin tools through deny-by-default path
    2. Verifies error messages contain agent and tool names
    3. Tests dispatch_structured integration for every admin tool
    4. Validates non-admin tools pass through unimpeded

    Pure synchronous tests — no Eio or network required. *)

module Tool_dispatch = Masc_mcp.Tool_dispatch
module Tool_permissions = Masc_mcp.Tool_permissions
module Tool_result = Masc_mcp.Tool_result

let setup () =
  Tool_dispatch.clear_hooks ();
  Tool_permissions.set_capability_checker (fun _agent _cap -> false)

(* ============================================================
   Exhaustive: every admin tool denied without capability
   ============================================================ *)

let test_all_admin_tools_denied () =
  List.iter (fun tool_name ->
    setup ();
    match Tool_permissions.check ~agent_name:"test_agent" ~tool_name with
    | Ok () ->
      Alcotest.failf "%s should be denied for non-admin" tool_name
    | Error msg ->
      Alcotest.(check bool)
        (tool_name ^ " error mentions agent")
        true (String.length msg > 0 &&
              try ignore (Str.search_forward
                (Str.regexp_string "test_agent") msg 0); true
              with Not_found -> false);
      Alcotest.(check bool)
        (tool_name ^ " error mentions tool")
        true
        (try ignore (Str.search_forward
           (Str.regexp_string tool_name) msg 0); true
         with Not_found -> false)
  ) Tool_permissions.admin_tools

(* ============================================================
   Exhaustive: every admin tool allowed WITH capability
   ============================================================ *)

let test_all_admin_tools_allowed_with_cap () =
  Tool_permissions.set_capability_checker (fun _agent cap -> cap = "admin");
  List.iter (fun tool_name ->
    match Tool_permissions.check ~agent_name:"admin_agent" ~tool_name with
    | Ok () -> ()
    | Error msg ->
      Alcotest.failf "%s should be allowed with admin cap: %s" tool_name msg
  ) Tool_permissions.admin_tools

(* ============================================================
   Dispatch integration: every admin tool blocked at pre-hook
   ============================================================ *)

let test_dispatch_blocks_all_admin_no_identity () =
  List.iter (fun tool_name ->
    setup ();
    Tool_dispatch.register ~tool_name
      ~handler:(fun ~name:_ ~args:_ -> Some (true, "should not reach"));
    Tool_permissions.install ~get_agent_name:(fun () -> None);
    let token = match Tool_dispatch.mint_token ~name:tool_name with Ok t -> t | Error e -> Alcotest.fail e in
    match Tool_dispatch.dispatch_structured ~token ~args:`Null with
    | Some r ->
      Alcotest.(check bool)
        (tool_name ^ " blocked at dispatch")
        false r.success;
      let msg = match r.data with `String s -> s | _ -> "" in
      Alcotest.(check bool)
        (tool_name ^ " mentions permission")
        true
        (try ignore (Str.search_forward
           (Str.regexp_string "permission") msg 0); true
         with Not_found -> false)
    | None ->
      Alcotest.failf "%s: expected Some from short-circuit" tool_name
  ) Tool_permissions.admin_tools

(* ============================================================
   Non-admin tools pass through: sample of common tools
   ============================================================ *)

let common_non_admin_tools =
  [ "masc_status"; "masc_join"; "masc_leave"; "masc_heartbeat";
    "masc_broadcast"; "masc_who"; "masc_tasks"; "masc_board_list";
    "masc_board_post"; "masc_board_comment" ]

let test_non_admin_always_allowed () =
  setup ();
  List.iter (fun tool_name ->
    match Tool_permissions.check ~agent_name:"any_agent" ~tool_name with
    | Ok () -> ()
    | Error msg ->
      Alcotest.failf "%s should be allowed (non-admin): %s" tool_name msg
  ) common_non_admin_tools

let test_non_admin_dispatch_passthrough () =
  List.iter (fun tool_name ->
    setup ();
    Tool_dispatch.register ~tool_name
      ~handler:(fun ~name:_ ~args:_ -> Some (true, "reached handler"));
    Tool_permissions.install ~get_agent_name:(fun () -> Some "regular_agent");
    let token = match Tool_dispatch.mint_token ~name:tool_name with Ok t -> t | Error e -> Alcotest.fail e in
    match Tool_dispatch.dispatch_structured ~token ~args:`Null with
    | Some r ->
      Alcotest.(check bool)
        (tool_name ^ " handler reached")
        true r.success
    | None ->
      Alcotest.failf "%s: expected dispatch result" tool_name
  ) common_non_admin_tools

(* ============================================================
   Admin tool list integrity
   ============================================================ *)

let test_admin_tool_count () =
  Alcotest.(check bool)
    "admin tool list nonempty"
    true (Tool_permissions.admin_tools <> []);
  let unique = List.sort_uniq String.compare Tool_permissions.admin_tools in
  Alcotest.(check int)
    "admin tool list deduped"
    (List.length unique) (List.length Tool_permissions.admin_tools)

let test_admin_tools_all_have_masc_prefix () =
  List.iter (fun name ->
    Alcotest.(check bool)
      (name ^ " has masc_ prefix")
      true
      (String.length name >= 5 && String.sub name 0 5 = "masc_")
  ) Tool_permissions.admin_tools

(* ============================================================
   Test runner
   ============================================================ *)

let () =
  Alcotest.run "Tool_permissions_exhaustive" [
    ("deny_all_admin", [
      Alcotest.test_case "every admin tool denied" `Quick
        test_all_admin_tools_denied;
      Alcotest.test_case "every admin tool allowed with cap" `Quick
        test_all_admin_tools_allowed_with_cap;
    ]);
    ("dispatch_integration", [
      Alcotest.test_case "dispatch blocks all admin (no identity)" `Quick
        test_dispatch_blocks_all_admin_no_identity;
    ]);
    ("non_admin_passthrough", [
      Alcotest.test_case "check allows common tools" `Quick
        test_non_admin_always_allowed;
      Alcotest.test_case "dispatch passes common tools" `Quick
        test_non_admin_dispatch_passthrough;
    ]);
    ("integrity", [
      Alcotest.test_case "admin tool list" `Quick test_admin_tool_count;
      Alcotest.test_case "admin tools prefixed" `Quick test_admin_tools_all_have_masc_prefix;
    ]);
  ]
