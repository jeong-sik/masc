(** Tests for Tool_dispatch — immutable central dispatch snapshots. *)

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
let echo_handler ~name ~args:_ = tool_ok ~tool_name:name ("ok:" ^ name)

(** Helper: a handler that returns (false, "fail"). *)
let fail_handler ~name:_ ~args:_ = tool_error "fail"

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
  Masc_test_deps.init_unified_tool_registry ();
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
          test_case "handler-only registration does not authorize token" `Quick
            (fun () ->
              let tool = "__test_dispatch_handler_only" in
              Tool_dispatch.register ~tool_name:tool ~handler:echo_handler;
              check bool "handler exists" true (Tool_dispatch.is_registered tool);
              check bool "handler-only mint rejected" true
                (Result.is_error (Tool_dispatch.mint_token ~name:tool));
              check bool "handler-only name absent from tag registry" true
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
              let tool = "__test_query_registered" in
              register_full ~tool_name:tool ~handler:echo_handler ();
              check bool "registered tool exists" true
                (Tool_dispatch.is_registered tool);
              check bool "unknown absent" false
                (Tool_dispatch.is_registered "__test_query_unknown"));
          test_case "registered_count >= registered tools" `Quick (fun () ->
              let before = Tool_dispatch.registered_count () in
              register_full
                ~tool_name:"__test_count_increment"
                ~handler:echo_handler
                ();
              check int
                "registration increments count"
                (before + 1)
                (Tool_dispatch.registered_count ()));
          test_case "all_registered_names enumerates registry" `Quick (fun () ->
              register_full ~tool_name:"__enum_check_xyz" ~handler:echo_handler ();
              let all = Tool_dispatch.all_registered_names () in
              check bool "contains registered name" true
                (List.mem "__enum_check_xyz" all));
        ] );
      ( "static_tag_routing",
        [
          test_case "known MCP names route through static tags" `Quick (fun () ->
              check bool "masc_board_delete -> Mod_inline" true
                (Tool_dispatch.lookup_tag "masc_board_delete"
                 = Some Tool_dispatch.Mod_inline);
              check bool "masc_board_cleanup -> Mod_inline" true
                (Tool_dispatch.lookup_tag "masc_board_cleanup"
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
                tool_ok "captured"
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
      ( "immutable_registry_snapshots",
        [
          test_case "concurrent registration and lookup stay coherent" `Quick
            (fun () ->
              let registrations_per_domain = 24 in
              let domain_count = 4 in
              let ready = Atomic.make 0 in
              let start = Atomic.make false in
              let domains =
                List.init domain_count (fun domain_index ->
                  Domain.spawn (fun () ->
                    Atomic.incr ready;
                    while not (Atomic.get start) do
                      Domain.cpu_relax ()
                    done;
                    for registration_index = 1 to registrations_per_domain do
                      let tool_name =
                        Printf.sprintf "__test_dispatch_concurrent_%d_%d"
                          domain_index registration_index
                      in
                      let schema = make_schema tool_name in
                      Tool_dispatch.register ~tool_name ~handler:echo_handler;
                      Tool_dispatch.register_module_tag
                        ~schemas:[ schema ]
                        ~tag:Mod_misc;
                      if not (Tool_dispatch.is_registered tool_name) then
                        Alcotest.failf "registered handler %s was not visible"
                          tool_name;
                      if Tool_dispatch.lookup_tag tool_name <> Some Mod_misc
                      then
                        Alcotest.failf "registered tag %s was not visible" tool_name;
                      if
                        Tool_dispatch.lookup_schema tool_name
                        <> Some schema.input_schema
                      then
                        Alcotest.failf
                          "registered schema %s was not visible"
                          tool_name
                    done))
              in
              while Atomic.get ready < domain_count do
                Domain.cpu_relax ()
              done;
              Atomic.set start true;
              List.iter Domain.join domains;
              for domain_index = 0 to domain_count - 1 do
                for registration_index = 1 to registrations_per_domain do
                  let tool_name =
                    Printf.sprintf "__test_dispatch_concurrent_%d_%d"
                      domain_index registration_index
                  in
                  check bool "registered snapshot contains handler" true
                    (Tool_dispatch.is_registered tool_name);
                  check
                    bool
                    "routing snapshot contains tag"
                    true
                    (Tool_dispatch.lookup_tag tool_name = Some Mod_misc);
                  check
                    bool
                    "routing snapshot contains schema"
                    true
                    (Option.is_some (Tool_dispatch.lookup_schema tool_name))
                done
              done);
        ] );
      (* PR-S3: the OTel/Otel_metric_store span wrapper is injected, not referenced
         inline. These tests assert the injection MECHANISM fires — they prove
         guarded_dispatch captures the immutable hook snapshot, so registering
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
