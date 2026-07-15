(** Behavioral post-turn durability and compaction tests. *)

open Alcotest

module Compact_policy = Masc.Keeper_compact_policy
module Post_turn = Masc.Keeper_post_turn

let test_prepared_becomes_applied_only_after_save () =
  let trigger = Compaction_trigger.Manual in
  check bool "Prepared is not Applied" false
    (Compact_policy.compaction_decision_applied
       (Compact_policy.Prepared trigger));
  (match
     Post_turn.For_testing.commit_prepared_after_save
       ~trigger
       ~save:(fun () -> Error "checkpoint unavailable")
   with
   | Error detail -> check string "save failure preserved" "checkpoint unavailable" detail
   | Ok _ -> fail "failed checkpoint save promoted Prepared to Applied");
  match
    Post_turn.For_testing.commit_prepared_after_save
      ~trigger
      ~save:(fun () -> Ok "durable-checkpoint")
  with
  | Error detail -> failf "successful checkpoint save failed: %s" detail
  | Ok (checkpoint, Compact_policy.Applied Compaction_trigger.Manual) ->
    check string "saved checkpoint returned" "durable-checkpoint" checkpoint
  | Ok _ -> fail "successful checkpoint save did not produce Applied Manual"

let make_meta
      ?(name = "post-turn-no-auto-compact")
      ?(trace_id = "trace-post-turn-no-auto-compact")
      ()
  : Masc.Keeper_meta_contract.keeper_meta
  =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String name
        ; "trace_id", `String trace_id
        ; "compaction_mode", `String "llm"
        ])
  with
  | Ok meta -> meta
  | Error detail -> failf "keeper meta fixture failed: %s" detail

let make_checkpoint () =
  Agent_sdk.Checkpoint.
    { version = checkpoint_version
    ; session_id = "trace-post-turn-no-auto-compact"
    ; agent_name = "post-turn-no-auto-compact"
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

let test_regular_post_turn_does_not_auto_compact () =
  Eio_main.run @@ fun _env ->
  let meta = make_meta () in
  let checkpoint = make_checkpoint () in
  let unexpected_callback () = fail "regular post-turn invoked a compaction callback" in
  let result =
    Post_turn.apply_post_turn_lifecycle_with_resilience_handles
      ~resilience_audit_store:None
      ~resilience_strategy_executor:None
      ~on_compaction_started:unexpected_callback
      ~on_handoff_started:unexpected_callback
      ~base_dir:"unused"
      ~meta
      ~model:"test-model"
      ~primary_model_max_tokens:8192
      ~current_turn_blocker_info:None
      ~checkpoint:(Some checkpoint)
  in
  check bool "compaction not attempted" false result.compaction.attempted;
  check bool "compaction not applied" false result.compaction.applied;
  (match result.compaction.decision with
   | Compact_policy.Not_requested -> ()
   | _ -> fail "regular post-turn returned a compaction decision");
  match result.checkpoint with
  | None -> fail "regular post-turn discarded the checkpoint"
  | Some retained ->
    check int "checkpoint turn retained" checkpoint.turn_count retained.turn_count;
    check bool "checkpoint messages retained exactly" true
      (retained.messages = checkpoint.messages)

let () =
  run "post-turn durability" [
    "durable compaction", [
      test_case "Prepared requires a successful checkpoint save"
        `Quick test_prepared_becomes_applied_only_after_save;
      test_case "regular post-turn does not auto-compact"
        `Quick test_regular_post_turn_does_not_auto_compact;
    ];
  ]
