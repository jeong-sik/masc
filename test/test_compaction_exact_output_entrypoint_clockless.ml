(** Production-entrypoint proof for a runtime context that deliberately has no
    Eio clock. This executable is isolated because [Eio_context]'s clock is a
    process-global write-only binding: another test in the same process could
    install a clock that cannot be masked safely. *)

open Alcotest

module Compact_policy = Masc.Keeper_compact_policy
module Exact_fixture = Compaction_exact_output_fixture
module Schema = Masc.Keeper_structured_output_schema

let exact_flow_base_path = "/tmp/masc-compaction-clockless"

let compaction_decision ?summary unit_index action =
  `Assoc
    [ Schema.compaction_plan_field_unit_index, `Int unit_index
    ; Schema.compaction_plan_field_action, `String action
    ; ( Schema.compaction_plan_field_summary
      , Option.fold ~none:`Null ~some:(fun value -> `String value) summary )
    ]
;;

let exact_response decisions =
  Exact_fixture.openai_response
    (`Assoc [ Schema.compaction_plan_field_decisions, `List decisions ])
;;

let summarize_response summary =
  exact_response
    [ compaction_decision
        ~summary
        1
        Schema.compaction_plan_action_summarize
    ]
;;

let invalid_keep_response =
  exact_response [ compaction_decision 1 Schema.compaction_plan_action_keep ]
;;

let init_runtime_fixture () =
  let runtime_path =
    Filename.concat (Masc_test_deps.find_project_root ()) "config/runtime.toml"
  in
  match Runtime.init_default ~config_path:runtime_path with
  | Ok () -> ()
  | Error detail -> failf "runtime fixture initialization failed: %s" detail
;;

let publish_exact_fixture ?connect_timeout_s ~source
    (server : Exact_fixture.test_server) =
  Exact_fixture.publish_runtime_lane
    ?connect_timeout_s
    ~source
    ~base_url:server.Exact_fixture.base_url
    ()
  |> ignore
;;

let make_meta () : Masc.Keeper_meta_contract.keeper_meta =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String "clockless-exact-output"
        ; "trace_id", `String "trace-clockless-exact-output"
        ])
  with
  | Ok meta -> meta
  | Error detail -> failf "keeper meta fixture failed: %s" detail
;;

let make_checkpoint () =
  Agent_sdk.Checkpoint.
    { version = checkpoint_version
    ; session_id = "trace-clockless-exact-output"
    ; agent_name = "clockless-exact-output"
    ; model = "test-model"
    ; system_prompt = None
    ; messages =
        [ Agent_sdk.Types.text_message Agent_sdk.Types.User "keep"
        ; Agent_sdk.Types.text_message Agent_sdk.Types.Assistant (String.make 2048 'x')
        ; Agent_sdk.Types.text_message Agent_sdk.Types.User (String.make 2048 'y')
        ]
    ; usage = Agent_sdk.Types.empty_usage
    ; turn_count = 7
    ; created_at = 1_700_000_000.0
    ; tools = []
    ; tool_choice = None
    ; disable_parallel_tool_use = false
    ; temperature = None
    ; top_p = None
    ; top_k = None
    ; min_p = None
    ; enable_thinking = None
    ; preserve_thinking = None
    ; response_format = Agent_sdk.Types.Off
    ; thinking_budget = None
    ; reasoning_effort = None
    ; cache_system_prompt = false
    ; context = Agent_sdk.Context.create_sync ()
    ; mcp_sessions = []
    ; working_context = None
    }
;;

let with_clockless_eio_context env sw f =
  (match Eio_context.get_clock_opt () with
   | None -> ()
   | Some _ -> fail "clockless exact-output process already has an Eio clock");
  Eio_context.set_net (Eio.Stdenv.net env);
  Eio_context.with_turn_switch sw (fun () ->
    match Eio_context.get_clock_opt () with
    | None -> f ()
    | Some _ -> fail "clock was installed inside the clockless exact-output scope")
;;

let test_domain_invalid_and_clockless_flow_failure_are_terminal () =
  (* Both typed failures cross the real production composition boundary.
     MASC never reads receipt phase/count: domain-invalid output remains a
     domain terminal, while the opaque OAS flow failure becomes a generic
     source-bound execution terminal. *)
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  with_clockless_eio_context env sw @@ fun () ->
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore runtime_snapshot)
    (fun () ->
      init_runtime_fixture ();
      let meta = make_meta () in
      Masc.Keeper_registry.For_testing.clear ();
      ignore
        (Masc.Keeper_registry.register_offline
           ~base_path:exact_flow_base_path
           meta.name
           meta);
      let context =
        Masc.Keeper_context_core.context_of_oas_checkpoint (make_checkpoint ())
      in
      let decision () =
        Compact_policy.compact_for_request_typed
          ~base_path:exact_flow_base_path
          ~meta
          ~trigger:Compaction_trigger.Manual
          ~exact_execution_guard:Exact_fixture.permissive_exact_execution_guard
          context
        |> fun preparation -> preparation.Compact_policy.decision
      in
      let invalid_server =
        Exact_fixture.start_server
          ~sw
          ~net:(Eio.Stdenv.net env)
          ~clock:(Eio.Stdenv.clock env)
          (Exact_fixture.Reply invalid_keep_response)
      in
      publish_exact_fixture
        ~source:"post-turn domain-invalid plan"
        invalid_server;
      (match decision () with
       | Compact_policy.Rejected
           ( Manual
           , Exact_execution_terminal
               { cause = Keeper_event_queue_state.Domain_invalid_output; _ } ) ->
         ()
       | _ -> fail "invalid domain plan was not a typed source terminal");
      check int
        "domain-invalid plan dispatches exactly once"
        1
        (Exact_fixture.post_count invalid_server);
      let before_dispatch_server =
        Exact_fixture.start_server
          ~sw
          ~net:(Eio.Stdenv.net env)
          ~clock:(Eio.Stdenv.clock env)
          (Exact_fixture.Reply (summarize_response "unreachable"))
      in
      publish_exact_fixture
        ~connect_timeout_s:1.0
        ~source:"post-turn before-dispatch rejection"
        before_dispatch_server;
      (match decision () with
       | Compact_policy.Rejected
           ( Manual
           , Exact_execution_terminal
               { cause = Keeper_event_queue_state.Exact_execution_failed; _ } ) ->
         ()
       | _ -> fail "clockless OAS flow failure was not a generic source terminal");
      check int
        "before-dispatch lane performs no HTTP request"
        0
        (Exact_fixture.post_count before_dispatch_server))
;;

let test_absent_guard_refuses_before_the_summarizer_call () =
  (* The summarizer refuses a plan built without a guard
     (keeper_compaction_llm_summarizer.ml:1329-1330) only after the plan exists, so
     the provider call is paid for and discarded. In production the guard is
     constructed only when the cycle claimed an event-queue stimulus lease
     (keeper_heartbeat_loop.ml:1362-1370), so a proactive-tick cycle can never
     satisfy it and the outcome is known before any work starts. Measured cost of
     the old order: sangsu 2026-07-25T09:31:46Z spent elapsed_ms=100507 on a
     provider_overflow compaction and settled retryable_failure with
     exact_execution_guard_failed.

     What this test proves is the typed distinction, which is #25713's complaint:
     before the hoist, an absent guard reached the summarizer and settled as
     exact_execution_bind_failed, collapsing "no lease" and "the bind did not reach
     the flow" into one string. After it, the absence reports itself.

     What it does NOT prove is the saved provider call. This process has no Eio clock
     by construction, so the unfixed path also refuses before dispatch here and the
     post count is 0 either way — measured, not assumed. The saved call is evidenced
     by the production record cited above, not by this fixture. The assertion stays
     as a regression guard: if a future edit makes this boundary dispatch first, it
     fails. *)
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  with_clockless_eio_context env sw @@ fun () ->
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore runtime_snapshot)
    (fun () ->
      init_runtime_fixture ();
      let meta = make_meta () in
      Masc.Keeper_registry.For_testing.clear ();
      ignore
        (Masc.Keeper_registry.register_offline
           ~base_path:exact_flow_base_path
           meta.name
           meta);
      let context =
        Masc.Keeper_context_core.context_of_oas_checkpoint (make_checkpoint ())
      in
      let server =
        Exact_fixture.start_server
          ~sw
          ~net:(Eio.Stdenv.net env)
          ~clock:(Eio.Stdenv.clock env)
          (Exact_fixture.Reply (summarize_response "would have summarized"))
      in
      publish_exact_fixture ~source:"absent guard" server;
      let preparation =
        (* No ~exact_execution_guard: the argument is optional at this boundary and
           its absence is the production shape being pinned. *)
        Compact_policy.compact_for_request_typed
          ~base_path:exact_flow_base_path
          ~meta
          ~trigger:Compaction_trigger.Manual
          context
      in
      (* Asserted before the constructor so an ordering regression cannot abort the
         run before this line is reached. *)
      check int
        "no provider request is made when the guard is absent"
        0
        (Exact_fixture.post_count server);
      (match preparation.Compact_policy.decision with
       | Compact_policy.Rejected (Manual, Exact_execution_guard_absent) -> ()
       | _ ->
         fail
           "an absent exact-execution guard did not reject as \
            Exact_execution_guard_absent");
      check bool
        "the original context is preserved"
        true
        (Masc.Keeper_context_core.message_count preparation.Compact_policy.context
         = Masc.Keeper_context_core.message_count context))
;;

let () =
  run
    "compaction exact-output clockless entrypoint"
    [ ( "production entrypoint"
      , [ test_case
            "domain invalid and clockless flow failure are terminal"
            `Quick
            test_domain_invalid_and_clockless_flow_failure_are_terminal
        ; test_case
            "an absent guard refuses before the summarizer call"
            `Quick
            test_absent_guard_refuses_before_the_summarizer_call
        ] )
    ]
;;
