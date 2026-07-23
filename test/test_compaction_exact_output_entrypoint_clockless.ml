(** Production-entrypoint proof for a runtime context that deliberately has no
    Eio clock. This executable is isolated because [Eio_context]'s clock is a
    process-global write-only binding: another test in the same process could
    install a clock that cannot be masked safely. *)

open Alcotest

module Compact_policy = Masc.Keeper_compact_policy
module Exact_fixture = Compaction_exact_output_fixture
module Schema = Masc.Keeper_structured_output_schema

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

let test_invalid_plan_is_distinct_from_before_dispatch_failure () =
  (* Both typed failures cross the real production composition boundary:
     domain-invalid output dispatches once, while a timeout requiring an absent
     clock is rejected before dispatch and performs no POST. *)
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
      let context =
        Masc.Keeper_context_core.context_of_oas_checkpoint (make_checkpoint ())
      in
      let decision () =
        Compact_policy.compact_for_request_typed
          ~meta
          ~trigger:Compaction_trigger.Manual
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
       | Compact_policy.Rejected (Manual, Invalid_compaction_plan) -> ()
       | _ -> fail "invalid provider plan was not a typed source terminal");
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
       | Compact_policy.Rejected (Manual, Exact_execution_failed_before_dispatch) -> ()
       | _ -> fail "pre-dispatch execution failure was collapsed into an invalid plan");
      check int
        "before-dispatch lane performs no HTTP request"
        0
        (Exact_fixture.post_count before_dispatch_server))
;;

let () =
  run
    "compaction exact-output clockless entrypoint"
    [ ( "production entrypoint"
      , [ test_case
            "invalid plan is distinct from before-dispatch failure"
            `Quick
            test_invalid_plan_is_distinct_from_before_dispatch_failure
        ] )
    ]
;;
