(** RFC-MASC-001 Phase 1: Tests for structured working_context in Checkpoint.

    Verifies:
    1. snapshot_to_json -> snapshot_of_json round-trip
    2. structured_working_context envelope (version 1)
    3. Empty snapshot produces None
    4. Malformed JSON produces None
    5. patch_checkpoint_last_assistant stores structured JSON when flag is on
    6. Structured JSON takes priority over text fallback in dual-source read *)

module KMP = Masc_mcp.Keeper_memory_policy
module KCC = Masc_mcp.Keeper_context_core

(* ── Round-trip tests ────────────────────────────────────────────── *)

let make_snapshot
    ?(goal = Some "Fix the build")
    ?(progress = Some "Compiled 3/5 modules")
    ?(done_summary = Some "Module A compiled")
    ?(next_summary = Some "Compile module B")
    ?(next_items = ["module B"; "module C"])
    ?(decisions = ["Use OCaml 5.x"])
    ?(open_questions = ["How to handle Eio?"])
    ?(constraints = ["Must pass CI"])
    () : KMP.keeper_state_snapshot =
  { goal; progress; done_summary; next_summary;
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
    response_format = Agent_sdk.Types.Off;
    thinking_budget = None;
    cache_system_prompt = false;
    max_input_tokens = None;
    max_total_tokens = None;
    context = Agent_sdk.Context.create ();
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
        ] );
      ( "patch_checkpoint",
        [
          Alcotest.test_case "stores replay metadata and clears wc" `Quick test_patch_stores_replay_metadata_and_clears_working_context;
          Alcotest.test_case "no [STATE] keeps text and no metadata" `Quick test_patch_without_state_block_keeps_text_and_no_metadata;
        ] );
      ( "dual_source",
        [
          Alcotest.test_case "text matches json" `Quick test_text_parse_matches_json_parse;
        ] );
    ]
