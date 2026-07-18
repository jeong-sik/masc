module Live_delta = Masc.Keeper_compaction_live_delta

let message text =
  Agent_sdk.Types.
    { role = User
    ; content = [ Text text ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
;;

let checkpoint ?(session_id = "trace") ?(agent_name = "keeper")
    ?(generation = 2) ?(turn_count = 7) ?(created_at = 1.0)
    ?(usage = Agent_sdk.Types.empty_usage) ?(working_context = None) messages =
  let context = Agent_sdk.Context.create_sync () in
  Agent_sdk.Context.set_scoped
    context
    Agent_sdk.Context.Session
    Masc.Keeper_checkpoint_store.keeper_generation_context_key
    (`Int generation);
  Agent_sdk.Checkpoint.
    { version = checkpoint_version
    ; session_id
    ; agent_name
    ; model = "model"
    ; system_prompt = Some "system"
    ; messages
    ; usage
    ; turn_count
    ; created_at
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
    ; context
    ; mcp_sessions = []
    ; working_context
    }
;;

let trace value =
  match Keeper_id.Trace_id.of_string value with
  | Ok trace_id -> trace_id
  | Error detail -> Alcotest.fail detail
;;

let snapshot ?session_id ?agent_name ?generation ?turn_count ?created_at ?usage
    ?working_context messages =
  let checkpoint =
    checkpoint
      ?session_id
      ?agent_name
      ?generation
      ?turn_count
      ?created_at
      ?usage
      ?working_context
      messages
  in
  match
    Masc.Keeper_checkpoint_store.exact_snapshot_of_canonical_bytes
      ~expected_session_id:(trace checkpoint.session_id)
      (Agent_sdk.Checkpoint.to_string checkpoint)
  with
  | Ok snapshot -> snapshot
  | Error _ -> Alcotest.fail "exact checkpoint snapshot construction failed"
;;

let expect_ok = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "live delta rebase failed"
;;

let check_messages expected actual =
  Alcotest.(check bool) "exact structural messages" true (expected = actual)
;;

let test_exact_source_returns_compacted_candidate () =
  let source = snapshot [ message "old" ] in
  let source_checkpoint =
    Masc.Keeper_checkpoint_store.exact_snapshot_checkpoint source
  in
  let compacted_messages = [ message "summary" ] in
  let result =
    Live_delta.rebase
      ~source
      ~compacted_messages
      ~current:source
    |> expect_ok
  in
  check_messages compacted_messages result.messages;
  Alcotest.(check string)
    "source metadata"
    source_checkpoint.session_id
    result.session_id;
  Alcotest.(check bool)
    "source context"
    true
    (source_checkpoint.context == result.context)
;;

let test_append_only_delta_preserves_exact_suffix () =
  let source_messages = [ message "a"; message "b" ] in
  let exact_suffix = [ message "c"; message "d" ] in
  let compacted_messages = [ message "summary"; message "b" ] in
  let source = snapshot source_messages in
  let current = snapshot ~turn_count:9 (source_messages @ exact_suffix) in
  let result =
    Live_delta.rebase ~source ~compacted_messages ~current
    |> expect_ok
  in
  check_messages (compacted_messages @ exact_suffix) result.messages
;;

let test_non_prefix_fails () =
  let source = snapshot [ message "a"; message "b" ] in
  let current = snapshot ~turn_count:8 [ message "a"; message "changed" ] in
  match
    Live_delta.rebase
      ~source
      ~compacted_messages:[ message "summary" ]
      ~current
  with
  | Error
      (Live_delta.Current_messages_prefix_mismatch
         Masc.Keeper_replay_prefix.Prefix_message_mismatch) -> ()
  | Ok _ | Error _ -> Alcotest.fail "non-prefix current checkpoint was accepted"
;;

let expect_superseded source current =
  match
    Live_delta.rebase
      ~source
      ~compacted_messages:[ message "summary" ]
      ~current
  with
  | Error (Live_delta.Source_superseded _) -> ()
  | Ok _ | Error _ -> Alcotest.fail "superseded source was accepted"
;;

let test_trace_mismatch_fails () =
  expect_superseded
    (snapshot [ message "a" ])
    (snapshot ~session_id:"other" ~turn_count:8 [ message "a"; message "b" ])
;;

let test_generation_mismatch_fails () =
  expect_superseded
    (snapshot [ message "a" ])
    (snapshot ~generation:3 ~turn_count:8 [ message "a"; message "b" ])
;;

let test_current_turn_regression_fails () =
  let source = snapshot ~turn_count:7 [ message "a" ] in
  let current = snapshot ~turn_count:6 [ message "a"; message "live" ] in
  match
    Live_delta.rebase
      ~source
      ~compacted_messages:[ message "summary" ]
      ~current
  with
  | Error
      (Live_delta.Current_turn_regressed
         { source_turn_count = 7; current_turn_count = 6 }) -> ()
  | Ok _ | Error _ -> Alcotest.fail "regressed current turn was accepted"
;;

let test_current_metadata_is_preserved () =
  let source = snapshot [ message "a" ] in
  let usage =
    Agent_sdk.Types.
      { empty_usage with total_input_tokens = 42; api_calls = 3 }
  in
  let current =
    snapshot
      ~agent_name:"live-keeper"
      ~turn_count:11
      ~created_at:9.0
      ~usage
      ~working_context:(Some (`Assoc [ "live", `Bool true ]))
      [ message "a"; message "live" ]
  in
  let result =
    Live_delta.rebase
      ~source
      ~compacted_messages:[ message "summary" ]
      ~current
    |> expect_ok
  in
  let current_checkpoint =
    Masc.Keeper_checkpoint_store.exact_snapshot_checkpoint current
  in
  Alcotest.(check string) "session" current_checkpoint.session_id result.session_id;
  Alcotest.(check string) "agent" current_checkpoint.agent_name result.agent_name;
  Alcotest.(check int) "turn count" current_checkpoint.turn_count result.turn_count;
  Alcotest.(check (float 0.0))
    "created at"
    current_checkpoint.created_at
    result.created_at;
  Alcotest.(check bool) "usage" true (current_checkpoint.usage = result.usage);
  Alcotest.(check bool)
    "context"
    true
    (current_checkpoint.context == result.context);
  Alcotest.(check bool)
    "working context"
    true
    (current_checkpoint.working_context = result.working_context)
;;

let () =
  Alcotest.run
    "keeper compaction live delta"
    [ ( "rebase"
      , [ Alcotest.test_case "exact source" `Quick test_exact_source_returns_compacted_candidate
        ; Alcotest.test_case "append-only delta" `Quick test_append_only_delta_preserves_exact_suffix
        ; Alcotest.test_case "non-prefix" `Quick test_non_prefix_fails
        ; Alcotest.test_case "trace mismatch" `Quick test_trace_mismatch_fails
        ; Alcotest.test_case "generation mismatch" `Quick test_generation_mismatch_fails
        ; Alcotest.test_case "current turn regression" `Quick
            test_current_turn_regression_fails
        ; Alcotest.test_case "metadata preservation" `Quick test_current_metadata_is_preserved
        ] )
    ]
