(** Tests for Tool_dispatch — O(1) central dispatch registry. *)

module Tool_dispatch = Tool_dispatch
module Tool_result = Tool_result
module Types = Masc_domain

let tool_ok ?(tool_name = "") message =
  Tool_result.make_ok ~tool_name ~start_time:0.0 ~data:(`String message) ()
;;

let tool_error ?(tool_name = "") message =
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Runtime_failure
    ~start_time:0.0
    ~data:(`String message)
    message
;;

(** Helper: create a minimal tool_schema for registration. *)
let make_schema ?(props = []) name =
  let prop_entries =
    List.map
      (fun (field, type_name) -> field, `Assoc [ "type", `String type_name ])
      props
  in
  { Masc_domain.name; description = "test tool " ^ name;
    input_schema =
      `Assoc [ "type", `String "object"; "properties", `Assoc prop_entries ] }

(** Helper: a handler that returns a successful result with "ok:<name>". *)
let echo_handler ~name ~args:_ = Some (tool_ok ~tool_name:name ("ok:" ^ name))

(** Helper: a handler that returns (false, "fail"). *)
let fail_handler ~name:_ ~args:_ = Some (tool_error "fail")

(** Helper: register a tool in handler, tag, and schema registries.
    The validation pre-hook is fail-closed for schema-less tools. *)
let register_full ?schema ~tool_name ~handler () =
  let schema =
    match schema with
    | Some schema -> schema
    | None -> make_schema tool_name
  in
  Tool_dispatch.register ~tool_name ~handler;
  Tool_dispatch.register_module_tag ~schemas:[schema] ~tag:Mod_misc

let () =
  Masc_test_deps.init_keeper_tool_registry ();
  let open Alcotest in
  run "Tool_dispatch"
    [
      ( "register_and_dispatch",
        [
          test_case "register single tool and dispatch" `Quick (fun () ->
              let tool = "__test_dispatch_single" in
              register_full ~tool_name:tool ~handler:echo_handler ();
              let token = match Tool_dispatch.mint_token ~name:tool with Ok t -> t | Error e -> Alcotest.fail e in
              let result = Tool_dispatch.guarded_dispatch ~token ~args:`Null () in
              check bool "found" true (Option.is_some result);
              let tr = Option.get result in
              let ok = (Tool_result.is_success tr) in
              let msg = (Tool_result.message tr) in
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
              Tool_dispatch.register_module_tag ~schemas ~tag:Mod_misc;
              List.iter
                (fun name ->
                  check bool (name ^ " registered") true
                    (Tool_dispatch.is_registered name))
                [ "__test_bulk_a"; "__test_bulk_b"; "__test_bulk_c" ]);
          test_case "register_module dispatches each name" `Quick (fun () ->
              let token = match Tool_dispatch.mint_token ~name:"__test_bulk_b" with Ok t -> t | Error e -> Alcotest.fail e in
              let result =
                Tool_dispatch.guarded_dispatch ~token ~args:`Null ()
              in
              let tr = Option.get result in
              let ok = (Tool_result.is_success tr) in
              let msg = (Tool_result.message tr) in
              check bool "ok" true ok;
              check string "msg" "ok:__test_bulk_b" msg);
          test_case "handler-only registration does not authorize token" `Quick
            (fun () ->
              let tool = "__test_dispatch_handler_only" in
              Tool_dispatch.register ~tool_name:tool ~handler:echo_handler;
              check bool "handler exists" true (Tool_dispatch.is_registered tool);
              check bool "handler-only mint rejected" true
                (Result.is_error (Tool_dispatch.mint_token ~name:tool));
              check bool "handler-only name hidden from registry names" true
                (not (List.mem tool (Tool_dispatch.all_registered_names ()))));
        ] );
      ( "replace_semantics",
        [
          test_case "re-register replaces handler" `Quick (fun () ->
              let tool = "__test_dispatch_replace" in
              register_full ~tool_name:tool ~handler:echo_handler ();
              let token1 = match Tool_dispatch.mint_token ~name:tool with Ok t -> t | Error e -> Alcotest.fail e in
              let result1 = Option.get (Tool_dispatch.guarded_dispatch ~token:token1 ~args:`Null ()) in
              let ok1 = (Tool_result.is_success result1) in
              check bool "first ok" true ok1;
              register_full ~tool_name:tool ~handler:fail_handler ();
              let token2 = match Tool_dispatch.mint_token ~name:tool with Ok t -> t | Error e -> Alcotest.fail e in
              let result2 = Option.get (Tool_dispatch.guarded_dispatch ~token:token2 ~args:`Null ()) in
              let ok2 = (Tool_result.is_success result2) in
              let msg2 = (Tool_result.message result2) in
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
      ( "static_tag_routing",
        [
          test_case "known MCP names route through static tags" `Quick (fun () ->
              check bool "masc_board_delete -> Mod_inline" true
                (Tool_dispatch.lookup_tag "masc_board_delete"
                 = Some Tool_dispatch.Mod_inline);
              check bool "masc_status -> Mod_state" true
                (Tool_dispatch.lookup_tag "masc_status"
                 = Some Tool_dispatch.Mod_state);
              check bool "masc_check -> Mod_state" true
                (Tool_dispatch.lookup_tag "masc_check"
                 = Some Tool_dispatch.Mod_state);
              check bool "masc_goal_list -> Mod_state" true
                (Tool_dispatch.lookup_tag "masc_goal_list"
                 = Some Tool_dispatch.Mod_state);
              check bool "masc_goal_upsert -> Mod_state" true
                (Tool_dispatch.lookup_tag "masc_goal_upsert"
                 = Some Tool_dispatch.Mod_state);
              check bool "masc_goal_transition -> Mod_state" true
                (Tool_dispatch.lookup_tag "masc_goal_transition"
                 = Some Tool_dispatch.Mod_state);
              check bool "masc_goal_verify -> Mod_state" true
                (Tool_dispatch.lookup_tag "masc_goal_verify"
                 = Some Tool_dispatch.Mod_state);
              check bool "tool_execute -> Mod_external" true
                (Tool_dispatch.lookup_tag "tool_execute"
                 = Some Tool_dispatch.Mod_external));
          test_case "mint_token accepts active static tool names" `Quick (fun () ->
              check bool "masc_status mints" true
                (Result.is_ok
                   (Tool_dispatch.mint_token ~name:"masc_status")));
          test_case "retired typed names do not mint by type alone" `Quick (fun () ->
              check bool "complete_task has no static route" true
                (Option.is_none
                   (Tool_dispatch.lookup_tag "masc_complete_task"));
              check bool "complete_task mint fails" true
                (Result.is_error
                   (Tool_dispatch.mint_token ~name:"masc_complete_task")));
        ] );
      ( "handler_receives_args",
        [
          test_case "args are passed through" `Quick (fun () ->
              let tool = "__test_dispatch_args" in
              let received_args = ref `Null in
              let capture_handler ~name:_ ~args =
                received_args := args;
                Some (tool_ok "captured")
              in
              register_full
                ~tool_name:tool
                ~schema:(make_schema ~props:[ "key", "string" ] tool)
                ~handler:capture_handler
                ();
              let test_args = `Assoc [("key", `String "value")] in
              let token = match Tool_dispatch.mint_token ~name:tool with Ok t -> t | Error e -> Alcotest.fail e in
              let _ = Tool_dispatch.guarded_dispatch ~token ~args:test_args () in
              check bool "args match" true (!received_args = test_args));
        ] );
      ( "handler_exception_safety",
        [
          test_case "throwing handler returns typed error" `Quick (fun () ->
              let tool = "__test_dispatch_throw" in
              let throwing_handler ~name:_ ~args:_ =
                failwith "boom"
              in
              register_full ~tool_name:tool ~handler:throwing_handler ();
              let token = match Tool_dispatch.mint_token ~name:tool with Ok t -> t | Error e -> Alcotest.fail e in
              let result = Tool_dispatch.guarded_dispatch ~token ~args:`Null () in
              check bool "still returns Some" true (Option.is_some result);
              let tr = Option.get result in
              let ok = (Tool_result.is_success tr) in
              let msg = (Tool_result.message tr) in
              check bool "marked as failure" false ok;
              check bool "contains error info" true
                (String.length msg > 0 && Astring.String.is_infix ~affix:"boom" msg));
        ] );
      ( "registry_introspection",
        [
          test_case "all_registered_names enumerates registry" `Quick (fun () ->
              register_full ~tool_name:"__enum_check_xyz" ~handler:echo_handler ();
              let all = Tool_dispatch.all_registered_names () in
              check bool "contains registered name" true
                (List.mem "__enum_check_xyz" all));
        ] );
      (* PR-S3: the OTel/Otel_metric_store span wrapper is injected, not referenced
         inline. These tests assert the injection MECHANISM fires — they prove
         guarded_dispatch routes through [!span_wrapper_ref], so registering
         [Tool_telemetry.with_span] at the composition root is sufficient for
         telemetry. (The actual Otel emission is verified by code-read; this
         covers the wiring contract that a green @check alone cannot.) *)
      ( "span_wrapper_injection",
        [
          test_case "registered span wrapper wraps guarded_dispatch" `Quick
            (fun () ->
              Tool_dispatch.clear_hooks ();
              let tool = "__test_span_wrap_a" in
              register_full ~tool_name:tool ~handler:echo_handler ();
              let calls = ref [] in
              let probe : Tool_dispatch.span_wrapper =
                fun ?force_new_trace_id:_ ?surface:_ ~tool_name body ->
                  calls := tool_name :: !calls;
                  body (fun () -> Some ("probe-trace", "probe-trace"))
              in
              Tool_dispatch.set_span_wrapper probe;
              let token =
                match Tool_dispatch.mint_token ~name:tool with
                | Ok t -> t
                | Error e -> Alcotest.fail e
              in
              let result = Tool_dispatch.guarded_dispatch ~token ~args:`Null () in
              check bool "result produced" true (Option.is_some result);
              check int "wrapper invoked once" 1 (List.length !calls);
              check string "wrapper saw tool_name" tool (List.hd !calls);
              Tool_dispatch.clear_hooks ());
          test_case "clear_hooks restores identity wrapper" `Quick (fun () ->
              let tool = "__test_span_wrap_b" in
              register_full ~tool_name:tool ~handler:echo_handler ();
              let calls = ref 0 in
              Tool_dispatch.set_span_wrapper (fun ?force_new_trace_id:_ ?surface:_ ~tool_name:_ body ->
                  incr calls;
                  body (fun () -> None));
              Tool_dispatch.clear_hooks ();
              let token =
                match Tool_dispatch.mint_token ~name:tool with
                | Ok t -> t
                | Error e -> Alcotest.fail e
              in
              let result = Tool_dispatch.guarded_dispatch ~token ~args:`Null () in
              (* Identity wrapper restored: dispatch still works, probe silent. *)
              check bool "dispatch succeeds with identity" true
                (Option.is_some result);
              check int "cleared wrapper not invoked" 0 !calls);
        ] );
    ]
