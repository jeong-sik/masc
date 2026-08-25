(** Production-entrypoint proof for a runtime context that deliberately has no
    Eio clock. This executable is isolated because [Eio_context]'s clock is a
    process-global write-only binding: another test in the same process could
    install a clock that cannot be masked safely. *)

open Alcotest

module Compact_policy = Masc.Keeper_compact_policy
module Exact_fixture = Compaction_exact_output_fixture
module Schema = Masc.Keeper_structured_output_schema
module Keeper_compaction_outcome = Masc.Keeper_compaction_outcome

let exact_flow_base_path = "/tmp/masc-compaction-clockless"

let exact_response ~summary ~keep_from_unit_index =
  Exact_fixture.openai_response
    (`Assoc
       [ Schema.compaction_plan_field_summary, `String summary
       ; ( Schema.compaction_plan_field_keep_from_unit_index
         , `Int keep_from_unit_index )
       ])
;;

let summarize_response summary =
  exact_response ~summary ~keep_from_unit_index:2
;;

let invalid_keep_response =
  exact_response ~summary:"invalid boundary" ~keep_from_unit_index:1
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
  Agent_core.Checkpoint.
    { version = checkpoint_version
    ; session_id = "trace-clockless-exact-output"
    ; agent_name = "clockless-exact-output"
    ; model = "test-model"
    ; system_prompt = None
    ; messages =
        [ Agent_core.Types.text_message Agent_core.Types.User "keep"
        ; Agent_core.Types.text_message Agent_core.Types.Assistant (String.make 2048 'x')
        ; Agent_core.Types.text_message Agent_core.Types.User (String.make 2048 'y')
        ]
    ; usage = Agent_core.Types.empty_usage
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
    ; response_format = Agent_core.Types.Off
    ; thinking_budget = None
    ; reasoning_effort = None
    ; cache_system_prompt = false
    ; context = Agent_core.Context.create_sync ()
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
     domain terminal, while the opaque AGENT_CORE flow failure becomes a generic
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
        Masc.Keeper_context_core.context_of_agent_core_checkpoint (make_checkpoint ())
      in
      let decision () =
        Compact_policy.compact_for_request_typed
          ~before_dispatch_authority:(fun _ -> Ok ())
          ~base_path:exact_flow_base_path
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
       | Compact_policy.Rejected
           ( Manual
           , Exact_execution_terminal
               { cause = Keeper_compaction_outcome.Domain_invalid_output; _ } ) ->
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
               { cause = Keeper_compaction_outcome.Exact_execution_failed; _ } ) ->
         ()
       | _ -> fail "clockless AGENT_CORE flow failure was not a generic source terminal");
      check int
        "before-dispatch lane performs no HTTP request"
        0
        (Exact_fixture.post_count before_dispatch_server))
;;

let test_absent_source_authority_is_typed_at_before_dispatch () =
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
        Masc.Keeper_context_core.context_of_agent_core_checkpoint (make_checkpoint ())
      in
      let server =
        Exact_fixture.start_server
          ~sw
          ~net:(Eio.Stdenv.net env)
          ~clock:(Eio.Stdenv.clock env)
          (Exact_fixture.Reply (summarize_response "would have summarized"))
      in
      publish_exact_fixture ~source:"absent source authority" server;
      let preparation =
        Compact_policy.compact_for_request_typed
          ~base_path:exact_flow_base_path
          ~meta
          ~trigger:Compaction_trigger.Manual
          context
      in
      check int
        "missing lifecycle authority prevents provider dispatch"
        0
        (Exact_fixture.post_count server);
      (match preparation.Compact_policy.decision with
       | Compact_policy.Rejected (Manual, Exact_execution_authority_absent) -> ()
       | _ -> fail "missing lifecycle authority did not reject compaction"))
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
            "absent source authority is typed at before-dispatch"
            `Quick
            test_absent_source_authority_is_typed_at_before_dispatch
        ] )
    ]
;;
