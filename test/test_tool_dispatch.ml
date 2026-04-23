(** Tests for Tool_dispatch — O(1) central dispatch registry. *)

module Tool_dispatch = Masc_mcp.Tool_dispatch
module Mcp_eio = Masc_mcp.Mcp_server_eio
module KE = Masc_mcp.Keeper_exec_tools
module Types = Types

(** Helper: create a minimal tool_schema for registration. *)
let make_schema name =
  { Types.name; description = "test tool " ^ name;
    input_schema = `Assoc [("type", `String "object")] }

(** Helper: a handler that returns (true, "ok:<name>"). *)
let echo_handler ~name ~args:_ = Some (true, "ok:" ^ name)

(** Helper: a handler that returns (false, "fail"). *)
let fail_handler ~name:_ ~args:_ = Some (false, "fail")

(** Helper: register a tool in both handler and tag registries.
    mint_token validates against tag_registry, so tests that mint
    must register in both. *)
let register_full ~tool_name ~handler =
  Tool_dispatch.register ~tool_name ~handler;
  Tool_dispatch.register_name_tag ~tool_name ~tag:Mod_misc

let () =
  let open Alcotest in
  run "Tool_dispatch"
    [
      ( "register_and_dispatch",
        [
          test_case "register single tool and dispatch" `Quick (fun () ->
              let tool = "__test_dispatch_single" in
              register_full ~tool_name:tool ~handler:echo_handler;
              let token = match Tool_dispatch.mint_token ~name:tool with Ok t -> t | Error e -> Alcotest.fail e in
              let result = Tool_dispatch.dispatch ~token ~args:`Null in
              check bool "found" true (Option.is_some result);
              let (ok, msg) = Option.get result in
              check bool "success" true ok;
              check string "message" ("ok:" ^ tool) msg);
          test_case "mint_token unknown tool returns Error" `Quick (fun () ->
              let result =
                Tool_dispatch.mint_token
                  ~name:"__test_dispatch_nonexistent_xyz"
              in
              check bool "is Error" true (Result.is_error result));
          test_case "register_module bulk registers" `Quick (fun () ->
              let schemas =
                List.map make_schema
                  [ "__test_bulk_a"; "__test_bulk_b"; "__test_bulk_c" ]
              in
              Tool_dispatch.register_module ~schemas ~handler:echo_handler;
              List.iter (fun s -> Tool_dispatch.register_name_tag ~tool_name:s.Types.name ~tag:Mod_misc) schemas;
              List.iter
                (fun name ->
                  check bool (name ^ " registered") true
                    (Tool_dispatch.is_registered name))
                [ "__test_bulk_a"; "__test_bulk_b"; "__test_bulk_c" ]);
          test_case "register_module dispatches each name" `Quick (fun () ->
              let token = match Tool_dispatch.mint_token ~name:"__test_bulk_b" with Ok t -> t | Error e -> Alcotest.fail e in
              let result =
                Tool_dispatch.dispatch ~token ~args:`Null
              in
              let (ok, msg) = Option.get result in
              check bool "ok" true ok;
              check string "msg" "ok:__test_bulk_b" msg);
        ] );
      ( "replace_semantics",
        [
          test_case "re-register replaces handler" `Quick (fun () ->
              let tool = "__test_dispatch_replace" in
              register_full ~tool_name:tool ~handler:echo_handler;
              let token1 = match Tool_dispatch.mint_token ~name:tool with Ok t -> t | Error e -> Alcotest.fail e in
              let (ok1, _) =
                Option.get (Tool_dispatch.dispatch ~token:token1 ~args:`Null)
              in
              check bool "first ok" true ok1;
              register_full ~tool_name:tool ~handler:fail_handler;
              let token2 = match Tool_dispatch.mint_token ~name:tool with Ok t -> t | Error e -> Alcotest.fail e in
              let (ok2, msg2) =
                Option.get (Tool_dispatch.dispatch ~token:token2 ~args:`Null)
              in
              check bool "replaced fail" false ok2;
              check string "fail msg" "fail" msg2);
        ] );
      ( "registry_queries",
        [
          test_case "is_registered reflects state" `Quick (fun () ->
              check bool "bulk_a exists" true
                (Tool_dispatch.is_registered "__test_bulk_a");
              check bool "unknown absent" false
                (Tool_dispatch.is_registered "__test_query_unknown"));
          test_case "registered_count >= registered tools" `Quick (fun () ->
              (* We registered at least 5 tools above *)
              check bool "count >= 5" true
                (Tool_dispatch.registered_count () >= 5));
        ] );
      ( "read_only_set",
        [
          test_case "init and query read_only" `Quick (fun () ->
              (* Simulate server init: populate the read_only set *)
              Tool_dispatch.init_read_only_set
                [ "masc_status"; "masc_who"; "masc_dashboard" ];
              check bool "masc_status is read_only" true
                (Tool_dispatch.is_read_only "masc_status");
              check bool "masc_who is read_only" true
                (Tool_dispatch.is_read_only "masc_who");
              check bool "masc_dashboard is read_only" true
                (Tool_dispatch.is_read_only "masc_dashboard"));
          test_case "non-read-only tool returns false" `Quick (fun () ->
              check bool "masc_broadcast not read_only" false
                (Tool_dispatch.is_read_only "masc_broadcast");
              check bool "masc_add_task not read_only" false
                (Tool_dispatch.is_read_only "masc_add_task"));
          test_case "keeper read-only tools use shipped registry policy" `Quick (fun () ->
              ignore (Mcp_eio.get_clock_opt ());
              check bool "keeper_tasks_list read_only" true
                (Tool_dispatch.is_read_only "keeper_tasks_list");
              check bool "keeper_memory_search read_only" true
                (Tool_dispatch.is_read_only "keeper_memory_search"));
          test_case "keeper read-only helper matches canonical list" `Quick (fun () ->
              check bool "tasks_list helper" true
                (KE.is_keeper_read_only_tool "keeper_tasks_list");
              check bool "memory_search helper" true
                (KE.is_keeper_read_only_tool "keeper_memory_search");
              check bool "fs_edit helper false" false
                (KE.is_keeper_read_only_tool "keeper_fs_edit");
              check bool "effective helper keeps mutating false" false
                (KE.is_effectively_read_only_tool "keeper_fs_edit"));
        ] );
      ( "requires_join_set",
        [
          test_case "known join-required tools" `Quick (fun () ->
              (* Simulate server init: populate the requires_join set *)
              Tool_dispatch.init_requires_join_set
                [ "masc_broadcast"; "masc_transition" ];
              check bool "masc_broadcast" true
                (Tool_dispatch.is_join_required "masc_broadcast");
              check bool "masc_transition" true
                (Tool_dispatch.is_join_required "masc_transition"));
          test_case "non-join-required tool returns false" `Quick (fun () ->
              check bool "masc_status" false
                (Tool_dispatch.is_join_required "masc_status");
              check bool "masc_who" false
                (Tool_dispatch.is_join_required "masc_who"));
          test_case "worktree list uses shipped registry policy" `Quick (fun () ->
              ignore (Mcp_eio.get_clock_opt ());
              check bool "masc_claim_next join_required" true
                (Tool_dispatch.is_join_required "masc_claim_next");
              check bool "masc_worktree_list read_only" true
                (Tool_dispatch.is_read_only "masc_worktree_list");
              check bool "masc_worktree_list not join_required" false
                (Tool_dispatch.is_join_required "masc_worktree_list"));
        ] );
      ( "mcp_context_required_set",
        [
          test_case "inline tools can be marked as requiring mcp context" `Quick (fun () ->
              Tool_dispatch.init_mcp_context_required_set
                [ "masc_join"; "masc_messages" ];
              check bool "masc_join" true
                (Tool_dispatch.is_mcp_context_required "masc_join");
              check bool "masc_messages" true
                (Tool_dispatch.is_mcp_context_required "masc_messages"));
          test_case "non-inline tool returns false" `Quick (fun () ->
              check bool "masc_status" false
                (Tool_dispatch.is_mcp_context_required "masc_status");
              check bool "masc_board_list" false
                (Tool_dispatch.is_mcp_context_required "masc_board_list"));
        ] );
      ( "handler_receives_args",
        [
          test_case "args are passed through" `Quick (fun () ->
              let tool = "__test_dispatch_args" in
              let received_args = ref `Null in
              let capture_handler ~name:_ ~args =
                received_args := args;
                Some (true, "captured")
              in
              register_full ~tool_name:tool ~handler:capture_handler;
              let test_args = `Assoc [("key", `String "value")] in
              let token = match Tool_dispatch.mint_token ~name:tool with Ok t -> t | Error e -> Alcotest.fail e in
              let _ = Tool_dispatch.dispatch ~token ~args:test_args in
              check bool "args match" true (!received_args = test_args));
        ] );
      ( "handler_exception_safety",
        [
          test_case "throwing handler returns error tuple" `Quick (fun () ->
              let tool = "__test_dispatch_throw" in
              let throwing_handler ~name:_ ~args:_ =
                failwith "boom"
              in
              register_full ~tool_name:tool ~handler:throwing_handler;
              let token = match Tool_dispatch.mint_token ~name:tool with Ok t -> t | Error e -> Alcotest.fail e in
              let result = Tool_dispatch.dispatch ~token ~args:`Null in
              check bool "still returns Some" true (Option.is_some result);
              let (ok, msg) = Option.get result in
              check bool "marked as failure" false ok;
              check bool "contains error info" true
                (String.length msg > 0 && Astring.String.is_infix ~affix:"boom" msg));
        ] );
    ]
