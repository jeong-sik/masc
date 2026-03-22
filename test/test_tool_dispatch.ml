(** Tests for Tool_dispatch — O(1) central dispatch registry. *)

module Tool_dispatch = Masc_mcp.Tool_dispatch
module Types = Types

(** Helper: create a minimal tool_schema for registration. *)
let make_schema name =
  { Types.name; description = "test tool " ^ name;
    input_schema = `Assoc [("type", `String "object")] }

(** Helper: a handler that returns (true, "ok:<name>"). *)
let echo_handler ~name ~args:_ = Some (true, "ok:" ^ name)

(** Helper: a handler that returns (false, "fail"). *)
let fail_handler ~name:_ ~args:_ = Some (false, "fail")

let () =
  let open Alcotest in
  run "Tool_dispatch"
    [
      ( "register_and_dispatch",
        [
          test_case "register single tool and dispatch" `Quick (fun () ->
              let tool = "__test_dispatch_single" in
              Tool_dispatch.register ~tool_name:tool ~handler:echo_handler;
              let result = Tool_dispatch.dispatch ~name:tool ~args:`Null in
              check bool "found" true (Option.is_some result);
              let (ok, msg) = Option.get result in
              check bool "success" true ok;
              check string "message" ("ok:" ^ tool) msg);
          test_case "dispatch unknown tool returns None" `Quick (fun () ->
              let result =
                Tool_dispatch.dispatch
                  ~name:"__test_dispatch_nonexistent_xyz" ~args:`Null
              in
              check bool "not found" true (Option.is_none result));
          test_case "register_module bulk registers" `Quick (fun () ->
              let schemas =
                List.map make_schema
                  [ "__test_bulk_a"; "__test_bulk_b"; "__test_bulk_c" ]
              in
              Tool_dispatch.register_module ~schemas ~handler:echo_handler;
              List.iter
                (fun name ->
                  check bool (name ^ " registered") true
                    (Tool_dispatch.is_registered name))
                [ "__test_bulk_a"; "__test_bulk_b"; "__test_bulk_c" ]);
          test_case "register_module dispatches each name" `Quick (fun () ->
              let result =
                Tool_dispatch.dispatch ~name:"__test_bulk_b" ~args:`Null
              in
              let (ok, msg) = Option.get result in
              check bool "ok" true ok;
              check string "msg" "ok:__test_bulk_b" msg);
        ] );
      ( "replace_semantics",
        [
          test_case "re-register replaces handler" `Quick (fun () ->
              let tool = "__test_dispatch_replace" in
              Tool_dispatch.register ~tool_name:tool ~handler:echo_handler;
              let (ok1, _) =
                Option.get (Tool_dispatch.dispatch ~name:tool ~args:`Null)
              in
              check bool "first ok" true ok1;
              Tool_dispatch.register ~tool_name:tool ~handler:fail_handler;
              let (ok2, msg2) =
                Option.get (Tool_dispatch.dispatch ~name:tool ~args:`Null)
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
        ] );
      ( "requires_join_set",
        [
          test_case "known join-required tools" `Quick (fun () ->
              (* Simulate server init: populate the requires_join set *)
              Tool_dispatch.init_requires_join_set
                [ "masc_claim"; "masc_broadcast"; "masc_done" ];
              check bool "masc_claim" true
                (Tool_dispatch.is_join_required "masc_claim");
              check bool "masc_broadcast" true
                (Tool_dispatch.is_join_required "masc_broadcast");
              check bool "masc_done" true
                (Tool_dispatch.is_join_required "masc_done"));
          test_case "non-join-required tool returns false" `Quick (fun () ->
              check bool "masc_status" false
                (Tool_dispatch.is_join_required "masc_status");
              check bool "masc_who" false
                (Tool_dispatch.is_join_required "masc_who"));
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
              Tool_dispatch.register ~tool_name:tool ~handler:capture_handler;
              let test_args = `Assoc [("key", `String "value")] in
              let _ = Tool_dispatch.dispatch ~name:tool ~args:test_args in
              check bool "args match" true (!received_args = test_args));
        ] );
      ( "handler_exception_safety",
        [
          test_case "throwing handler returns error tuple" `Quick (fun () ->
              let tool = "__test_dispatch_throw" in
              let throwing_handler ~name:_ ~args:_ =
                failwith "boom"
              in
              Tool_dispatch.register ~tool_name:tool ~handler:throwing_handler;
              let result = Tool_dispatch.dispatch ~name:tool ~args:`Null in
              check bool "still returns Some" true (Option.is_some result);
              let (ok, msg) = Option.get result in
              check bool "marked as failure" false ok;
              check bool "contains error info" true
                (String.length msg > 0 && Astring.String.is_infix ~affix:"boom" msg));
        ] );
    ]
