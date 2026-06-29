(** RFC-MASC-001 Phase 1: Tests for structured working_context in Checkpoint.

    Verifies:
    1. snapshot_to_json -> snapshot_of_json round-trip
    2. structured_working_context envelope (version 1)
    3. Empty snapshot produces None
    4. Malformed JSON produces None
    5. patch_checkpoint_last_assistant stores structured JSON when flag is on
    6. Structured JSON takes priority over text fallback in dual-source read *)

module KMP = Masc.Keeper_memory_policy
module KCC = Masc.Keeper_context_core
module KRT = Masc.Keeper_agent_run_response_text
module Receipt = Masc.Keeper_execution_receipt

let contains_substring text needle =
  let text_len = String.length text in
  let needle_len = String.length needle in
  let rec loop idx =
    if needle_len = 0 then true
    else if idx + needle_len > text_len then false
    else if String.sub text idx needle_len = needle then true
    else loop (idx + 1)
  in
  loop 0

(* ── Round-trip tests ────────────────────────────────────────────── *)

let make_snapshot
    ?(priority = None)
    ?(goal = Some "Fix the build")
    ?(progress = Some "Compiled 3/5 modules")
    ?(done_summary = Some "Module A compiled")
    ?(next_summary = Some "Compile module B")
    ?(next_items = ["module B"; "module C"])
    ?(decisions = ["Use OCaml 5.x"])
    ?(open_questions = ["How to handle Eio?"])
    ?(constraints = ["Must pass CI"])
    () : KMP.keeper_state_snapshot =
  { priority; goal; progress; done_summary; next_summary;
    next_items; decisions; open_questions; constraints }

let test_round_trip_full () =
  let original = make_snapshot () in
  let json = KMP.keeper_state_snapshot_to_json original in
  let restored = KMP.keeper_state_snapshot_of_json json in
  match restored with
  | None -> Alcotest.fail "round-trip returned None for populated snapshot"
  | Some snap ->
    Alcotest.(check (option string)) "goal" original.goal snap.goal;
    Alcotest.(check (option string)) "progress" original.progress snap.progress;
    Alcotest.(check (option string)) "done_summary" original.done_summary snap.done_summary;
    Alcotest.(check (option string)) "next_summary" original.next_summary snap.next_summary;
    Alcotest.(check (list string)) "next_items" original.next_items snap.next_items;
    Alcotest.(check (list string)) "decisions" original.decisions snap.decisions;
    Alcotest.(check (list string)) "open_questions" original.open_questions snap.open_questions;
    Alcotest.(check (list string)) "constraints" original.constraints snap.constraints

let test_round_trip_minimal () =
  let original = make_snapshot
    ~goal:(Some "Only goal")
    ~progress:None ~done_summary:None ~next_summary:None
    ~next_items:[] ~decisions:[] ~open_questions:[] ~constraints:[]
    ()
  in
  let json = KMP.keeper_state_snapshot_to_json original in
  let restored = KMP.keeper_state_snapshot_of_json json in
  match restored with
  | None -> Alcotest.fail "round-trip returned None for minimal snapshot"
  | Some snap ->
    Alcotest.(check (option string)) "goal" (Some "Only goal") snap.goal;
    Alcotest.(check (list string)) "next_items" [] snap.next_items

let test_empty_snapshot_returns_none () =
  let empty = KMP.empty_keeper_state_snapshot in
  let json = KMP.keeper_state_snapshot_to_json empty in
  let restored = KMP.keeper_state_snapshot_of_json json in
  Alcotest.(check bool) "empty snapshot -> None" true (restored = None)

let test_malformed_json_returns_none () =
  let bad_json = `String "not an object" in
  let restored = KMP.keeper_state_snapshot_of_json bad_json in
  Alcotest.(check bool) "malformed -> None" true (restored = None)

let test_null_json_returns_none () =
  let restored = KMP.keeper_state_snapshot_of_json `Null in
  Alcotest.(check bool) "null -> None" true (restored = None)

(* ── Structured working_context envelope tests ───────────────────── *)

let test_structured_envelope_round_trip () =
  let original = make_snapshot () in
  let envelope = KMP.structured_working_context_of_snapshot original in
  let restored = KMP.snapshot_of_structured_working_context envelope in
  match restored with
  | None -> Alcotest.fail "envelope round-trip returned None"
  | Some snap ->
    Alcotest.(check (option string)) "goal" original.goal snap.goal;
    Alcotest.(check (list string)) "decisions" original.decisions snap.decisions

let test_envelope_wrong_version_returns_none () =
  let json = `Assoc [
    ("version", `Int 99);
    ("state_snapshot", KMP.keeper_state_snapshot_to_json (make_snapshot ()));
  ] in
  let restored = KMP.snapshot_of_structured_working_context json in
  Alcotest.(check bool) "wrong version -> None" true (restored = None)

let test_envelope_missing_version_returns_none () =
  let json = `Assoc [
    ("state_snapshot", KMP.keeper_state_snapshot_to_json (make_snapshot ()));
  ] in
  let restored = KMP.snapshot_of_structured_working_context json in
  Alcotest.(check bool) "missing version -> None" true (restored = None)

let test_envelope_empty_snapshot_returns_none () =
  let json = `Assoc [
    ("version", `Int 1);
    ("state_snapshot", KMP.keeper_state_snapshot_to_json KMP.empty_keeper_state_snapshot);
  ] in
  let restored = KMP.snapshot_of_structured_working_context json in
  Alcotest.(check bool) "empty snapshot in envelope -> None" true (restored = None)

let test_structured_state_schema_parse_raw_snapshot_json () =
  let json =
    `Assoc
      [ ("progress", `String "Structured progress")
      ; ("decisions", `List [ `String "No blocker" ])
      ]
  in
  match KMP.structured_state_snapshot_schema.parse json with
  | Error msg -> Alcotest.fail ("schema parse returned Error: " ^ msg)
  | Ok snap ->
      Alcotest.(check (option string))
        "progress"
        (Some "Structured progress")
        snap.progress;
      Alcotest.(check (list string))
        "decisions"
        [ "No blocker" ]
        snap.decisions

let test_parse_structured_reply_accepts_envelope_json_fence () =
  let original =
    make_snapshot
      ~goal:(Some "Structured goal")
      ~progress:(Some "Parsed from fenced envelope")
      ~done_summary:None
      ~next_summary:None
      ~next_items:[]
      ~decisions:[]
      ~open_questions:[]
      ~constraints:[]
      ()
  in
  let raw =
    "```json\n"
    ^ Yojson.Safe.to_string (KMP.structured_working_context_of_snapshot original)
    ^ "\n```"
  in
  match KMP.parse_structured_state_snapshot_from_reply raw with
  | None -> Alcotest.fail "structured reply parse returned None"
  | Some snap ->
      Alcotest.(check (option string))
        "goal"
        (Some "Structured goal")
        snap.goal;
      Alcotest.(check (option string))
        "progress"
        (Some "Parsed from fenced envelope")
        snap.progress

let test_finalizer_uses_structured_state_source () =
  let raw =
    {|{"progress":"Structured progress","decisions":["No blocker"]}|}
  in
  let finalized =
    KRT.finalize
      ~reported_state_snapshot:None
      ~keeper_name:"test"
      ~goal:"Fix structured state"
      ~actual_keeper_tool_names:[ "masc_tasks" ]
      ~completion_contract_result:Receipt.Contract_satisfied_execution
      ~stop_reason:Runtime_agent.Completed
      ~raw_response_text:raw
      ()
  in
  let
    { KRT.state_snapshot
    ; state_snapshot_source
    ; response_text
    }
    =
    finalized
  in
  Alcotest.(check string)
    "source"
    "model_structured_state"
    (KMP.state_snapshot_source_to_string state_snapshot_source);
  Alcotest.(check (option string))
    "progress"
    (Some "Structured progress")
    state_snapshot.progress;
  Alcotest.(check string)
    "visible response"
    "Structured progress"
    response_text;
  Alcotest.(check (list string))
    "decisions"
    [ "No blocker" ]
    state_snapshot.decisions;
  Alcotest.(check bool)
    "no synthetic marker"
    false
    (List.exists
       (fun text -> contains_substring text "[SYNTHETIC]")
       state_snapshot.decisions)

let test_finalizer_prefers_reported_state_snapshot () =
  let reported_state_snapshot =
    make_snapshot
      ~goal:(Some "Tool state goal")
      ~progress:(Some "Reported through keeper_report_state")
      ~done_summary:None
      ~next_summary:None
      ~next_items:[]
      ~decisions:[ "Tool state wins" ]
      ~open_questions:[]
      ~constraints:[]
      ()
  in
  let finalized =
    KRT.finalize
      ~reported_state_snapshot:(Some reported_state_snapshot)
      ~keeper_name:"test"
      ~goal:"Fallback goal"
      ~actual_keeper_tool_names:[ "keeper_report_state" ]
      ~completion_contract_result:Receipt.Contract_satisfied_execution
      ~stop_reason:Runtime_agent.Completed
      ~raw_response_text:"Visible reply"
      ()
  in
  let
    { KRT.state_snapshot
    ; state_snapshot_source
    ; response_text
    }
    =
    finalized
  in
  Alcotest.(check string)
    "source"
    "model_structured_state_tool"
    (KMP.state_snapshot_source_to_string state_snapshot_source);
  Alcotest.(check (option string))
    "progress"
    (Some "Reported through keeper_report_state")
    state_snapshot.progress;
  Alcotest.(check string)
    "visible response"
    "Visible reply"
    response_text;
  Alcotest.(check (list string))
    "decisions"
    [ "Tool state wins" ]
    state_snapshot.decisions

(* ── patch_checkpoint_last_assistant tests ────────────────────────── *)

let make_test_checkpoint ?(working_context = None) ~response_text () =
  let messages = [
    Agent_sdk.Types.{ role = User; content = [Text "hello"]; name = None; tool_call_id = None; metadata = [] };
    Agent_sdk.Types.{ role = Assistant; content = [Text response_text]; name = None; tool_call_id = None; metadata = [] };
  ] in
  Agent_sdk.Checkpoint.{
    version = 4;
    session_id = "test-session";
    agent_name = "test-agent";
    model = "test-model";
    system_prompt = Some "you are helpful";
    messages;
    usage = Agent_sdk.Types.empty_usage;
    turn_count = 1;
    created_at = 1000.0;
    tools = [];
    tool_choice = None;
    disable_parallel_tool_use = false;
    temperature = None;
    top_p = None;
    top_k = None;
    min_p = None;
    enable_thinking = None;
    preserve_thinking = None;
    response_format = Agent_sdk.Types.Off;
    thinking_budget = None;
    cache_system_prompt = false;

    context = Agent_sdk.Context.create ~eio:false ();
    mcp_sessions = [];
    working_context;
  }

let test_patch_stores_replay_metadata_and_clears_working_context () =
  let response_text =
    "I fixed the build.\n[STATE]\nGoal: Fix CI\nDONE: All green\n[/STATE]"
  in
  let cp = make_test_checkpoint ~response_text () in
  let patched =
    KCC.patch_checkpoint_last_assistant cp
      ~session_id:"new-session"
      ~response_text
  in
  Alcotest.(check bool) "working_context cleared" true (patched.working_context = None);
  match List.rev patched.messages with
  | [] -> Alcotest.fail "patched checkpoint has no messages"
  | last :: _ ->
      (match KMP.snapshot_of_message_metadata last with
       | None -> Alcotest.fail "assistant message metadata missing replay snapshot"
       | Some snap ->
           Alcotest.(check (option string)) "goal from metadata" (Some "Fix CI") snap.goal;
           Alcotest.(check (option string)) "done from metadata" (Some "All green") snap.done_summary)

let test_patch_drops_legacy_state_working_context_sidecar () =
  let legacy_sidecar =
    KMP.structured_working_context_of_snapshot
      (make_snapshot
         ~goal:(Some "stale sidecar")
         ~progress:None
         ~done_summary:None
         ~next_summary:None
         ~next_items:[]
         ~decisions:[]
         ~open_questions:[]
         ~constraints:[]
         ())
  in
  let response_text =
    "New answer.\n[STATE]\nGoal: fresh metadata\nDONE: Stored in metadata\n[/STATE]"
  in
  let cp =
    make_test_checkpoint
      ~working_context:(Some legacy_sidecar)
      ~response_text
      ()
  in
  let patched =
    KCC.patch_checkpoint_last_assistant cp
      ~session_id:"new-session"
      ~response_text
  in
  Alcotest.(check bool)
    "legacy state sidecar cleared from working_context"
    true
    (patched.working_context = None);
  match List.rev patched.messages with
  | [] -> Alcotest.fail "patched checkpoint has no messages"
  | last :: _ ->
      let text = Agent_sdk.Types.text_of_message last in
      Alcotest.(check bool)
        "visible checkpoint text is state-free"
        false
        (contains_substring text "[STATE]");
      (match KMP.snapshot_of_message_metadata last with
       | None -> Alcotest.fail "assistant message metadata missing replay snapshot"
       | Some snap ->
           Alcotest.(check (option string))
             "fresh metadata wins"
             (Some "fresh metadata")
             snap.goal)

let test_patch_without_state_block_keeps_text_and_no_metadata () =
  let response_text = "I did some work but no state block." in
  let cp = make_test_checkpoint ~response_text () in
  let patched =
    KCC.patch_checkpoint_last_assistant cp
      ~session_id:"new-session"
      ~response_text
  in
  Alcotest.(check bool) "working_context still cleared" true (patched.working_context = None);
  match List.rev patched.messages with
  | [] -> Alcotest.fail "patched checkpoint has no messages"
  | last :: _ ->
      Alcotest.(check bool) "metadata absent without snapshot"
        true (KMP.snapshot_of_message_metadata last = None)

let checkpoint_msg role content =
  Agent_sdk.Types.{ role; content; name = None; tool_call_id = None; metadata = [] }

let replay_test_checkpoint messages =
  let cp = make_test_checkpoint ~response_text:"old answer" () in
  { cp with Agent_sdk.Checkpoint.messages; working_context = Some (`Assoc []) }

let has_tool_use (msg : Agent_sdk.Types.message) =
  List.exists
    (function
      | Agent_sdk.Types.ToolUse _ -> true
      | _ -> false)
    msg.Agent_sdk.Types.content

let prune_reason_to_string reason =
  Option.map
    Masc.Keeper_agent_run_finalize_response.For_testing.replay_suffix_prune_reason_to_string
    reason

let test_attention_checkpoint_prunes_current_turn_suffix () =
  let open Agent_sdk.Types in
  let old_user = checkpoint_msg User [ Text "old user" ] in
  let old_assistant = checkpoint_msg Assistant [ Text "old answer" ] in
  let current_user = checkpoint_msg User [ Text "current user" ] in
  let current_tool_use =
    checkpoint_msg Assistant
      [ ToolUse
          { id = "tool-1"
          ; name = "keeper_context_status"
          ; input = `Assoc []
          }
      ]
  in
  let current_tool_result =
    checkpoint_msg Tool
      [ ToolResult
          { tool_use_id = "tool-1"
          ; content = "status"
          ; is_error = false
          ; json = None
          ; content_blocks = None
          }
      ]
  in
  let current_final = checkpoint_msg Assistant [ Text "" ] in
  let cp =
    replay_test_checkpoint
      [ old_user; old_assistant; current_user; current_tool_use
      ; current_tool_result; current_final
      ]
  in
  let pre_turn_working_context = Some (`Assoc [ "pre_turn", `Bool true ]) in
  let patched, pruned =
    Masc.Keeper_agent_run_finalize_response.For_testing
    .checkpoint_for_replay_persistence
      ~history_messages:[ old_user; old_assistant ]
      ~pre_turn_working_context
      ~completion_contract_result:Receipt.Contract_passive_only
      ~session_id:"new-session"
      ~response_text:"synthetic no-progress"
      ~state_snapshot_source:KMP.State_block
      ~state_snapshot:None
      cp
  in
  Alcotest.(check (option string))
    "suffix pruned"
    (Some "completion_contract_requires_attention")
    (prune_reason_to_string pruned);
  Alcotest.(check int) "only prior history remains" 2
    (List.length patched.messages);
  Alcotest.(check bool) "pre-turn working context restored" true
    (patched.working_context = pre_turn_working_context);
  match List.rev patched.messages with
  | last :: _ ->
      Alcotest.(check string) "prior assistant not overwritten" "old answer"
        (Agent_sdk.Types.text_of_message last)
  | [] -> Alcotest.fail "expected prior messages"

let test_attention_checkpoint_refuses_mismatched_history_prefix () =
  let open Agent_sdk.Types in
  let expected_old_user = checkpoint_msg User [ Text "expected old user" ] in
  let actual_old_user = checkpoint_msg User [ Text "actual old user" ] in
  let old_assistant = checkpoint_msg Assistant [ Text "old answer" ] in
  let current_user = checkpoint_msg User [ Text "current user" ] in
  let current_final = checkpoint_msg Assistant [ Text "" ] in
  let cp =
    replay_test_checkpoint [ actual_old_user; old_assistant; current_user; current_final ]
  in
  let patched, pruned =
    Masc.Keeper_agent_run_finalize_response.For_testing
    .checkpoint_for_replay_persistence
      ~history_messages:[ expected_old_user; old_assistant ]
      ~pre_turn_working_context:(Some (`Assoc [ "pre_turn", `Bool true ]))
      ~completion_contract_result:Receipt.Contract_passive_only
      ~session_id:"new-session"
      ~response_text:"synthetic no-progress"
      ~state_snapshot_source:KMP.State_block
      ~state_snapshot:None
      cp
  in
  Alcotest.(check (option string))
    "mismatched prefix is not pruned"
    None
    (prune_reason_to_string pruned);
  Alcotest.(check int) "checkpoint messages kept" 4 (List.length patched.messages);
  Alcotest.(check bool)
    "working context not replaced without a verified prefix"
    true
    (patched.working_context = cp.working_context)

let test_synthetic_empty_checkpoint_prunes_current_turn_suffix () =
  let open Agent_sdk.Types in
  let old_user = checkpoint_msg User [ Text "old user" ] in
  let old_assistant = checkpoint_msg Assistant [ Text "old answer" ] in
  let current_user = checkpoint_msg User [ Text "current user" ] in
  let current_tool_use =
    checkpoint_msg Assistant
      [ ToolUse
          { id = "tool-1"
          ; name = "keeper_tasks_list"
          ; input = `Assoc []
          }
      ]
  in
  let current_tool_result =
    checkpoint_msg Tool
      [ ToolResult
          { tool_use_id = "tool-1"
          ; content = "[]"
          ; is_error = false
          ; json = None
          ; content_blocks = None
          }
      ]
  in
  let current_final = checkpoint_msg Assistant [ Text "" ] in
  let cp =
    replay_test_checkpoint
      [ old_user; old_assistant; current_user; current_tool_use
      ; current_tool_result; current_final
      ]
  in
  let pre_turn_working_context = Some (`Assoc [ "pre_turn", `Bool true ]) in
  let patched, pruned =
    Masc.Keeper_agent_run_finalize_response.For_testing
    .checkpoint_for_replay_persistence
      ~history_messages:[ old_user; old_assistant ]
      ~pre_turn_working_context
      ~completion_contract_result:Receipt.Contract_satisfied_execution
      ~session_id:"new-session"
      ~response_text:""
      ~state_snapshot_source:KMP.Synthesized
      ~state_snapshot:None
      cp
  in
  Alcotest.(check (option string))
    "synthetic empty suffix pruned"
    (Some "synthetic_empty_state_snapshot")
    (prune_reason_to_string pruned);
  Alcotest.(check int) "only prior history remains" 2
    (List.length patched.messages);
  Alcotest.(check bool) "pre-turn working context restored" true
    (patched.working_context = pre_turn_working_context);
  Alcotest.(check bool)
    "current tool replay is not persisted"
    false
    (List.exists has_tool_use patched.messages)

let test_satisfied_checkpoint_keeps_tool_suffix_and_patches_final () =
  let open Agent_sdk.Types in
  let old_user = checkpoint_msg User [ Text "old user" ] in
  let old_assistant = checkpoint_msg Assistant [ Text "old answer" ] in
  let current_user = checkpoint_msg User [ Text "current user" ] in
  let current_tool_use =
    checkpoint_msg Assistant
      [ ToolUse
          { id = "tool-1"
          ; name = "keeper_context_status"
          ; input = `Assoc []
          }
      ]
  in
  let current_tool_result =
    checkpoint_msg Tool
      [ ToolResult
          { tool_use_id = "tool-1"
          ; content = "status"
          ; is_error = false
          ; json = None
          ; content_blocks = None
          }
      ]
  in
  let current_final = checkpoint_msg Assistant [ Text "draft answer" ] in
  let cp =
    replay_test_checkpoint
      [ old_user; old_assistant; current_user; current_tool_use
      ; current_tool_result; current_final
      ]
  in
  let patched, pruned =
    Masc.Keeper_agent_run_finalize_response.For_testing
    .checkpoint_for_replay_persistence
      ~history_messages:[ old_user; old_assistant ]
      ~pre_turn_working_context:None
      ~completion_contract_result:Receipt.Contract_satisfied_execution
      ~session_id:"new-session"
      ~response_text:"visible answer"
      ~state_snapshot_source:KMP.State_block
      ~state_snapshot:None
      cp
  in
  Alcotest.(check (option string)) "suffix kept" None
    (prune_reason_to_string pruned);
  Alcotest.(check int) "turn transcript remains" 6
    (List.length patched.messages);
  Alcotest.(check bool) "tool use remains" true
    (List.exists has_tool_use patched.messages);
  match List.rev patched.messages with
  | last :: _ ->
      Alcotest.(check string) "final assistant patched" "visible answer"
        (Agent_sdk.Types.text_of_message last)
  | [] -> Alcotest.fail "expected messages"

(* ── Dual-source read test ───────────────────────────────────────── *)

let test_text_parse_matches_json_parse () =
  (* The text [STATE] parser and JSON parser should produce equivalent
     snapshots for the same source data. *)
  let response_text =
    "[STATE]\nGoal: Deploy\nDONE: Built\nNEXT: Push\nDecisions: Use main\nOpenQuestions: Timing?\nConstraints: No downtime\n[/STATE]"
  in
  let text_snapshot = KMP.parse_state_snapshot_from_reply response_text in
  match text_snapshot with
  | None -> Alcotest.fail "text parse returned None"
  | Some text_snap ->
    let json = KMP.keeper_state_snapshot_to_json text_snap in
    let json_snapshot = KMP.keeper_state_snapshot_of_json json in
    (match json_snapshot with
     | None -> Alcotest.fail "json parse returned None"
     | Some json_snap ->
       Alcotest.(check (option string)) "goal" text_snap.goal json_snap.goal;
       Alcotest.(check (option string)) "done" text_snap.done_summary json_snap.done_summary;
       Alcotest.(check (list string)) "decisions" text_snap.decisions json_snap.decisions;
       Alcotest.(check (list string)) "open_questions" text_snap.open_questions json_snap.open_questions;
       Alcotest.(check (list string)) "constraints" text_snap.constraints json_snap.constraints)

let test_budget_synthesis_does_not_invent_next_items () =
  let snapshot =
    KMP.synthesize_state_from_run_result
      ~goal:"Fix task"
      ~tools_used:["tool_execute"; "tool_read_file"]
      ~stop_reason:"budget_exhausted"
      ~response_text:"Continuation checkpoint saved; keeper remains scheduled"
  in
  Alcotest.(check (list string)) "no invented next_items" [] snapshot.next_items;
  Alcotest.(check (option string)) "budget continuation is not done" None
    snapshot.done_summary;
  Alcotest.(check bool)
    "checkpoint resume summary present"
    true
    (match snapshot.next_summary with
     | Some text -> contains_substring text "OAS checkpoint"
     | None -> false);
  Alcotest.(check (list string))
    "budget continuation does not invent decisions"
    []
    snapshot.decisions

let test_no_tool_synthesis_does_not_invent_progress_text () =
  let snapshot =
    KMP.synthesize_state_from_run_result
      ~goal:"Monitor keepers"
      ~tools_used:[]
      ~stop_reason:"completed"
      ~response_text:""
  in
  Alcotest.(check (option string))
    "no synthetic no-tool progress prose"
    None
    snapshot.progress;
  Alcotest.(check (option string))
    "no synthetic no-tool done summary"
    None
    snapshot.done_summary

let test_budget_finalizer_drops_synthetic_response_text () =
  let finalized =
    KRT.finalize
      ~reported_state_snapshot:None
      ~keeper_name:"test"
      ~goal:"Fix task"
      ~actual_keeper_tool_names:[]
      ~completion_contract_result:Receipt.Contract_satisfied_completion
      ~stop_reason:(Runtime_agent.TurnBudgetExhausted { turns_used = 3; limit = 3 })
      ~raw_response_text:
        "Continuation checkpoint saved; keeper remains scheduled"
      ()
  in
  Alcotest.(check string)
    "budget checkpoint has no model-authored response text"
    ""
    finalized.response_text;
  Alcotest.(check string)
    "synthetic state source"
    "synthesized"
    (KMP.state_snapshot_source_to_string finalized.state_snapshot_source);
  Alcotest.(check (list string))
    "budget continuation does not preserve synthetic text as a decision"
    []
    finalized.state_snapshot.decisions

let test_synthetic_finalizer_drops_generated_response_text () =
  let raw_response_text =
    String.concat
      "\n"
      [
        "The system context changed without new user input.";
        "What should I do next?";
        "Check keeper_tasks_list again.";
        "What should I do next?";
        "Check keeper_tasks_list again.";
      ]
  in
  let finalized =
    KRT.finalize
      ~reported_state_snapshot:None
      ~keeper_name:"test"
      ~goal:"Monitor keeper work"
      ~actual_keeper_tool_names:["keeper_tasks_list"]
      ~completion_contract_result:Receipt.Contract_satisfied_execution
      ~stop_reason:Runtime_agent.Completed
      ~raw_response_text
      ()
  in
  Alcotest.(check string)
    "synthetic state source"
    "synthesized"
    (KMP.state_snapshot_source_to_string finalized.state_snapshot_source);
  Alcotest.(check string)
    "synthetic source is not a user-visible reply"
    ""
    finalized.response_text;
  Alcotest.(check bool)
    "raw repeated text not persisted as response"
    false
    (contains_substring finalized.response_text "What should I do next?")

let test_contract_attention_finalizer_drops_raw_response_text () =
  let raw_response_text =
    "Good. I will read the code, edit it, and commit it now.\n\
     \n\
     Good. I will read the code, edit it, and commit it now."
  in
  let finalized =
    KRT.finalize
      ~reported_state_snapshot:None
      ~keeper_name:"albini"
      ~goal:"PM flow"
      ~actual_keeper_tool_names:["keeper_context_status"]
      ~completion_contract_result:Receipt.Contract_passive_only
      ~stop_reason:Runtime_agent.Completed
      ~raw_response_text
      ()
  in
  Alcotest.(check string)
    "contract attention suppresses visible response"
    ""
    finalized.response_text;
  Alcotest.(check string)
    "synthetic state source"
    "synthesized"
    (KMP.state_snapshot_source_to_string finalized.state_snapshot_source);
  Alcotest.(check bool)
    "raw repeated text not persisted as decision"
    false
    (List.exists
       (fun text -> contains_substring text "edit it, and commit")
       finalized.state_snapshot.decisions)

(* ── Test runner ─────────────────────────────────────────────────── *)

let () =
  Alcotest.run "keeper_state_snapshot_json"
    [
      ( "round_trip",
        [
          Alcotest.test_case "full snapshot" `Quick test_round_trip_full;
          Alcotest.test_case "minimal snapshot" `Quick test_round_trip_minimal;
          Alcotest.test_case "empty -> None" `Quick test_empty_snapshot_returns_none;
          Alcotest.test_case "malformed -> None" `Quick test_malformed_json_returns_none;
          Alcotest.test_case "null -> None" `Quick test_null_json_returns_none;
        ] );
      ( "structured_envelope",
        [
          Alcotest.test_case "envelope round-trip" `Quick test_structured_envelope_round_trip;
          Alcotest.test_case "wrong version -> None" `Quick test_envelope_wrong_version_returns_none;
          Alcotest.test_case "missing version -> None" `Quick test_envelope_missing_version_returns_none;
          Alcotest.test_case "empty in envelope -> None" `Quick test_envelope_empty_snapshot_returns_none;
          Alcotest.test_case
            "schema parses raw snapshot json"
            `Quick
            test_structured_state_schema_parse_raw_snapshot_json;
          Alcotest.test_case
            "reply parser accepts fenced envelope"
            `Quick
            test_parse_structured_reply_accepts_envelope_json_fence;
          Alcotest.test_case
            "finalizer keeps structured source"
            `Quick
            test_finalizer_uses_structured_state_source;
          Alcotest.test_case
            "finalizer prefers reported state"
            `Quick
            test_finalizer_prefers_reported_state_snapshot;
        ] );
      ( "patch_checkpoint",
        [
          Alcotest.test_case "stores replay metadata and clears wc" `Quick test_patch_stores_replay_metadata_and_clears_working_context;
          Alcotest.test_case "drops legacy state sidecar from wc" `Quick test_patch_drops_legacy_state_working_context_sidecar;
          Alcotest.test_case "no [STATE] keeps text and no metadata" `Quick test_patch_without_state_block_keeps_text_and_no_metadata;
          Alcotest.test_case
            "attention result prunes current replay suffix"
            `Quick
            test_attention_checkpoint_prunes_current_turn_suffix;
          Alcotest.test_case
            "attention result refuses mismatched replay prefix"
            `Quick
            test_attention_checkpoint_refuses_mismatched_history_prefix;
          Alcotest.test_case
            "synthetic empty result prunes current replay suffix"
            `Quick
            test_synthetic_empty_checkpoint_prunes_current_turn_suffix;
          Alcotest.test_case
            "satisfied result keeps tool replay suffix"
            `Quick
            test_satisfied_checkpoint_keeps_tool_suffix_and_patches_final;
        ] );
      ( "dual_source",
        [
          Alcotest.test_case "text matches json" `Quick test_text_parse_matches_json_parse;
          Alcotest.test_case
            "budget synthesis does not invent next items"
            `Quick
            test_budget_synthesis_does_not_invent_next_items;
          Alcotest.test_case
            "no-tool synthesis does not invent progress text"
            `Quick
            test_no_tool_synthesis_does_not_invent_progress_text;
          Alcotest.test_case
            "budget finalizer drops synthetic response text"
            `Quick
            test_budget_finalizer_drops_synthetic_response_text;
          Alcotest.test_case
            "synthetic finalizer drops generated response text"
            `Quick
            test_synthetic_finalizer_drops_generated_response_text;
          Alcotest.test_case
            "contract attention finalizer drops raw response text"
            `Quick
            test_contract_attention_finalizer_drops_raw_response_text;
        ] );
    ]
