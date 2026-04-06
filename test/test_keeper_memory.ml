open Alcotest

module Mention = Mention
module Keeper_execution = Masc_mcp.Keeper_execution
module Keeper_memory = Masc_mcp.Keeper_memory
module Keeper_memory_recall = Masc_mcp.Keeper_memory_recall
module Keeper_types = Masc_mcp.Keeper_types
module Types = Types

let keeper_meta ~name ~mention_targets =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("trace_id", `String "trace-1");
        ("goal", `String "keep continuity");
        ("mention_targets", `List (List.map (fun target -> `String target) mention_targets));
      ]
  in
  match Keeper_types.meta_of_json json with
  | Ok meta -> meta
  | Error err -> fail ("failed to build keeper meta: " ^ err)

let room_message content =
  {
    Types.seq = 1;
    from_agent = "tester";
    msg_type = "broadcast";
    content;
    mention = None;
    timestamp = "2026-03-12T00:00:00Z"; trace_context = None;
  }

let test_any_mentioned_exact_target () =
  check bool "exact direct mention" true
    (Mention.any_mentioned ~targets:[ "sangsu" ] "hello @sangsu, are you there?")

let test_any_mentioned_ambient_message () =
  check bool "ambient message not a direct mention" false
    (Mention.any_mentioned ~targets:[ "sangsu" ] "hello everyone, just chatting")

let test_keeper_policy_observation_direct_mention () =
  let meta = keeper_meta ~name:"sangsu" ~mention_targets:[ "sangsu"; "director" ] in
  let obs =
    Keeper_memory.keeper_policy_observation_of_room_message
      ~meta ~room_id:"default" (room_message "@director, what do you think?")
  in
  check bool "keeper observation uses mention targets" true obs.direct_mention

let test_keeper_policy_observation_non_mention () =
  let meta = keeper_meta ~name:"sangsu" ~mention_targets:[ "sangsu"; "director" ] in
  let obs =
    Keeper_memory.keeper_policy_observation_of_room_message
      ~meta ~room_id:"default" (room_message "ambient room chatter")
  in
  check bool "keeper observation no longer hardcodes direct mention" false obs.direct_mention

let test_user_visible_reply_strips_state_block () =
  let raw =
    "좋아요. 이어서 진행하겠습니다.\n\n[STATE]\nGoal: keep continuity\nProgress: ready\n[/STATE]"
  in
  check string "state block hidden from user text"
    "좋아요. 이어서 진행하겠습니다."
    (Keeper_execution.user_visible_reply_text raw)

let test_user_visible_reply_strips_skill_and_state_markers () =
  let raw =
    "SKILL: scene-director\nSKILL_REASON: continuity\n본문입니다.\n\n[STATE]\nGoal: keep continuity\n[/STATE]"
  in
  check string "skill route lines hidden from user text"
    "본문입니다."
    (Keeper_execution.user_visible_reply_text raw)

let test_user_visible_reply_falls_back_to_snapshot_progress () =
  let raw =
    "[STATE]\nGoal: keep continuity\nProgress: 다음 장면 전환 준비 완료\n[/STATE]"
  in
  check string "state-only reply falls back to progress"
    "다음 장면 전환 준비 완료"
    (Keeper_execution.user_visible_reply_text raw)

(* Recall is private; access via Keeper_memory which includes it *)
module Recall = Masc_mcp.Keeper_memory

(* Helper to build a keeper_auto_rule_eval with all flags off *)
let base_eval : Recall.keeper_auto_rule_eval = {
  repetition_risk = 0.0;
  goal_alignment = 1.0;
  response_alignment = 1.0;
  goal_drift = 0.0;
  reflect = false;
  plan = false;
  compact = false;
  handoff = false;
  guardrail_stop = false;
  guardrail_reason = None;
  reasons = [];
}

let test_prioritized_action_none () =
  let action = Recall.prioritized_action base_eval in
  check string "no rule fired" "none"
    (Recall.prioritized_action_to_string action)

let test_prioritized_action_guardrail_stop () =
  let eval = { base_eval with
    guardrail_stop = true;
    guardrail_reason = Some "all gates triggered";
    reflect = true;
    plan = true;
    compact = true;
    handoff = true;
  } in
  let action = Recall.prioritized_action eval in
  match action with
  | Recall.Act_guardrail_stop reason ->
      check bool "reason contains gates" true
        (String.length reason > 0)
  | _ -> fail "expected Act_guardrail_stop"

let test_prioritized_action_reflect_over_plan () =
  let eval = { base_eval with
    reflect = true;
    plan = true;
    compact = true;
  } in
  let action = Recall.prioritized_action eval in
  check string "reflect wins over plan" "reflect"
    (Recall.prioritized_action_to_string action)

let test_prioritized_action_plan_over_compact () =
  let eval = { base_eval with
    plan = true;
    compact = true;
    handoff = true;
  } in
  let action = Recall.prioritized_action eval in
  check string "plan wins over compact" "plan"
    (Recall.prioritized_action_to_string action)

let test_prioritized_action_compact_over_handoff () =
  let eval = { base_eval with
    compact = true;
    handoff = true;
  } in
  let action = Recall.prioritized_action eval in
  check string "compact wins over handoff" "compact"
    (Recall.prioritized_action_to_string action)

let test_prioritized_action_handoff_alone () =
  let eval = { base_eval with handoff = true } in
  let action = Recall.prioritized_action eval in
  check string "handoff alone" "handoff"
    (Recall.prioritized_action_to_string action)

let test_prioritized_action_guardrail_default_reason () =
  let eval = { base_eval with
    guardrail_stop = true;
    guardrail_reason = None;
  } in
  let action = Recall.prioritized_action eval in
  match action with
  | Recall.Act_guardrail_stop reason ->
      check string "default reason" "guardrail_stop" reason
  | _ -> fail "expected Act_guardrail_stop"

let test_prioritized_action_to_string_all_variants () =
  let open Recall in
  check string "guardrail" "guardrail_stop(safety)" (prioritized_action_to_string (Act_guardrail_stop "safety"));
  check string "reflect" "reflect" (prioritized_action_to_string Act_reflect);
  check string "plan" "plan" (prioritized_action_to_string Act_plan);
  check string "compact" "compact" (prioritized_action_to_string Act_compact);
  check string "handoff" "handoff" (prioritized_action_to_string Act_handoff);
  check string "none" "none" (prioritized_action_to_string Act_none)

(* --- history recall tests --- *)

let test_tmpdir () =
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc-test-%d" (Unix.getpid ())) in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  dir

let cleanup_tmpdir dir =
  (try
     Array.iter (fun f -> Sys.remove (Filename.concat dir f)) (Sys.readdir dir);
     Unix.rmdir dir
   with _ -> ())

let test_load_history_user_messages () =
  let dir = test_tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup_tmpdir dir) (fun () ->
    let path = Filename.concat dir "history.jsonl" in
    let lines = [
      {|{"role":"user","content":"hello world"}|};
      {|{"role":"assistant","content":"hi there"}|};
      {|{"role":"user","content":"second question"}|};
      {|{"role":"user","content":""}|};
      {|{"role":"user","content":"third question"}|};
    ] in
    let oc = open_out path in
    List.iter (fun l -> output_string oc (l ^ "\n")) lines;
    close_out oc;
    let result = Keeper_memory_recall.load_history_user_messages ~path ~max_n:10 in
    check int "3 user messages" 3 (List.length result);
    check string "first" "hello world" (List.hd result);
    check string "last" "third question" (List.nth result 2))

let test_recall_candidates_with_history_dedup () =
  let dir = test_tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup_tmpdir dir) (fun () ->
    let path = Filename.concat dir "history.jsonl" in
    (* history contains same message as checkpoint *)
    let lines = [
      {|{"role":"user","content":"hello world"}|};
      {|{"role":"user","content":"unique from history"}|};
    ] in
    let oc = open_out path in
    List.iter (fun l -> output_string oc (l ^ "\n")) lines;
    close_out oc;
    let checkpoint_msgs : Agent_sdk.Types.message list = [
      Agent_sdk.Types.text_message Agent_sdk.Types.User "hello world";
    ] in
    let result = Keeper_memory_recall.recall_candidates_with_history
      ~checkpoint_messages:checkpoint_msgs
      ~history_path:path
      ~max_checkpoint:32 ~max_history:64 in
    (* "hello world" from checkpoint, "unique from history" from history *)
    check int "2 total (deduped)" 2 (List.length result);
    check string "first from checkpoint" "hello world" (List.hd result);
    check string "second from history" "unique from history" (List.nth result 1))

let test_recall_candidates_with_history_appends () =
  let dir = test_tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup_tmpdir dir) (fun () ->
    let path = Filename.concat dir "history.jsonl" in
    let lines = [
      {|{"role":"user","content":"old question from 3 days ago"}|};
      {|{"role":"user","content":"another old question"}|};
    ] in
    let oc = open_out path in
    List.iter (fun l -> output_string oc (l ^ "\n")) lines;
    close_out oc;
    let checkpoint_msgs : Agent_sdk.Types.message list = [
      Agent_sdk.Types.text_message Agent_sdk.Types.User "recent question";
    ] in
    let result = Keeper_memory_recall.recall_candidates_with_history
      ~checkpoint_messages:checkpoint_msgs
      ~history_path:path
      ~max_checkpoint:32 ~max_history:64 in
    check int "3 total" 3 (List.length result);
    check string "checkpoint first" "recent question" (List.hd result))

(* --- E2E memory write → recall integration tests (I1) --- *)

module Keeper_memory_bank = Masc_mcp.Keeper_memory_bank
module Room = Masc_mcp.Room

(** Create a minimal Room.config for testing with a temp base_path.
    Uses Room.default_config which creates FileSystem backend. *)
let make_test_room_config dir =
  Room.default_config dir

(** E2E: write memory via append_memory_notes_from_reply, then read back via recall.
    Tests the full pipeline: reply → parse → snapshot → candidates → JSONL → recall.
    This is the test that was missing (RFC #3646 I1). *)
let test_memory_write_then_recall_with_state_block () =
  let dir = test_tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup_tmpdir dir) (fun () ->
    let config = make_test_room_config dir in
    let meta = keeper_meta ~name:"e2e-keeper" ~mention_targets:["e2e-keeper"] in

    (* Simulate a keeper reply with [STATE] block *)
    let reply =
      "네, 계속 진행하겠습니다.\n\n\
       [STATE]\n\
       Goal: test E2E memory pipeline\n\
       Progress: memory write verified\n\
       Next: recall verification\n\
       Decisions: use filesystem storage\n\
       [/STATE]"
    in

    let (notes_written, kinds) =
      Keeper_memory_bank.append_memory_notes_from_reply config meta ~turn:1 ~reply
    in

    (* Verify write happened *)
    check bool "at least one note written" true (notes_written > 0);
    check bool "goal kind present" true (List.mem "goal" kinds);

    (* Verify recall reads back what was written *)
    let summary =
      Keeper_memory_recall.read_keeper_memory_summary config
        ~name:"e2e-keeper" ~max_bytes:100000 ~max_lines:100 ~recent_limit:10
    in
    check bool "recall finds notes" true (summary.total_notes > 0);
    check bool "recall has goal kind" true
      (List.exists (fun (k, _) -> k = "goal") summary.kind_counts))

(** E2E: write memory via meta-based fallback (no [STATE] block).
    Verifies the deterministic fallback path from RFC #3646 Section 3. *)
let test_memory_write_then_recall_meta_fallback () =
  let dir = test_tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup_tmpdir dir) (fun () ->
    let config = make_test_room_config dir in
    let meta = keeper_meta ~name:"fallback-keeper" ~mention_targets:["fallback-keeper"] in

    (* Reply WITHOUT [STATE] block — should trigger meta-based fallback *)
    let reply = "네, 이해했습니다. 바로 작업을 시작하겠습니다." in

    let (notes_written, kinds) =
      Keeper_memory_bank.append_memory_notes_from_reply config meta ~turn:1 ~reply
    in

    (* Meta fallback should write the goal from meta.goal *)
    check bool "fallback wrote notes" true (notes_written > 0);
    check bool "fallback wrote goal kind" true (List.mem "goal" kinds);

    (* Recall should find the note *)
    let summary =
      Keeper_memory_recall.read_keeper_memory_summary config
        ~name:"fallback-keeper" ~max_bytes:100000 ~max_lines:100 ~recent_limit:10
    in
    check bool "recall finds fallback notes" true (summary.total_notes > 0))

module KET = Masc_mcp.Keeper_exec_tools
module KEC = Masc_mcp.Keeper_exec_context

(** Recursive cleanup for nested temp dirs (traces/<id>/history.jsonl). *)
let rec cleanup_tmpdir_r dir =
  if Sys.file_exists dir && Sys.is_directory dir then begin
    Array.iter (fun f ->
      let path = Filename.concat dir f in
      if Sys.is_directory path then cleanup_tmpdir_r path
      else (try Sys.remove path with _ -> ()))
      (Sys.readdir dir);
    (try Unix.rmdir dir with _ -> ())
  end

(** Write lines to a file, creating parent dirs as needed. *)
let write_lines path lines =
  Keeper_types.mkdir_p (Filename.dirname path);
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    List.iter (fun l -> output_string oc (l ^ "\n")) lines)

(** Test: keeper_memory_search finds messages from history.jsonl that are
    NOT in the current checkpoint messages.  This verifies cross-generation
    recall via execute_keeper_tool_call dispatch. *)
let test_memory_search_cross_generation () =
  let dir = test_tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup_tmpdir_r dir) (fun () ->
    let config = make_test_room_config dir in
    let meta = keeper_meta ~name:"cross-gen-keeper" ~mention_targets:["cross-gen-keeper"] in
    let trace_id = meta.runtime.trace_id in
    (* Write history.jsonl with messages from previous generations *)
    let history_path = Keeper_types.keeper_history_path config trace_id in
    write_lines history_path [
      {|{"role":"user","content":"deploy the canary release"}|};
      {|{"role":"assistant","content":"deploying now"}|};
      {|{"role":"user","content":"what was the incident root cause"}|};
      {|{"role":"user","content":"scale the fleet to 12 pods"}|};
    ];
    (* Current checkpoint has different messages — no overlap with history query *)
    let ctx_work = KEC.create ~system_prompt:"test" ~max_tokens:4096 in
    let ctx_work = KEC.append ctx_work
      (Agent_sdk.Types.text_message Agent_sdk.Types.User "hello keeper") in
    (* Search for "canary" — only exists in history.jsonl *)
    let result = KET.execute_keeper_tool_call ~config ~meta ~ctx_work
      ~name:"keeper_memory_search"
      ~input:(`Assoc [ ("query", `String "canary"); ("limit", `Int 5) ])
      () in
    let json = Yojson.Safe.from_string result in
    let match_count = Yojson.Safe.Util.(json |> member "match_count" |> to_int) in
    check bool "found canary from history" true (match_count > 0);
    let matches = Yojson.Safe.Util.(json |> member "matches" |> to_list
      |> List.map to_string) in
    check bool "match contains deploy canary" true
      (List.exists (fun m -> Re.execp (Re.str "canary" |> Re.compile) m) matches))

(** Test: keeper_memory_search still finds messages from current checkpoint. *)
let test_memory_search_checkpoint_only () =
  let dir = test_tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup_tmpdir_r dir) (fun () ->
    let config = make_test_room_config dir in
    let meta = keeper_meta ~name:"ckpt-keeper" ~mention_targets:["ckpt-keeper"] in
    (* No history.jsonl — only checkpoint messages *)
    let ctx_work = KEC.create ~system_prompt:"test" ~max_tokens:4096 in
    let ctx_work = KEC.append ctx_work
      (Agent_sdk.Types.text_message Agent_sdk.Types.User "optimize the database query") in
    let result = KET.execute_keeper_tool_call ~config ~meta ~ctx_work
      ~name:"keeper_memory_search"
      ~input:(`Assoc [ ("query", `String "database"); ("limit", `Int 5) ])
      () in
    let json = Yojson.Safe.from_string result in
    let match_count = Yojson.Safe.Util.(json |> member "match_count" |> to_int) in
    check bool "found database from checkpoint" true (match_count > 0))

(** Test: deduplication — same message in checkpoint and history appears once. *)
let test_memory_search_dedup () =
  let dir = test_tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup_tmpdir_r dir) (fun () ->
    let config = make_test_room_config dir in
    let meta = keeper_meta ~name:"dedup-keeper" ~mention_targets:["dedup-keeper"] in
    let trace_id = meta.runtime.trace_id in
    let history_path = Keeper_types.keeper_history_path config trace_id in
    write_lines history_path [
      {|{"role":"user","content":"unique needle from history"}|};
      {|{"role":"user","content":"shared needle message"}|};
    ];
    let ctx_work = KEC.create ~system_prompt:"test" ~max_tokens:4096 in
    let ctx_work = KEC.append ctx_work
      (Agent_sdk.Types.text_message Agent_sdk.Types.User "shared needle message") in
    let result = KET.execute_keeper_tool_call ~config ~meta ~ctx_work
      ~name:"keeper_memory_search"
      ~input:(`Assoc [ ("query", `String "needle"); ("limit", `Int 10) ])
      () in
    let json = Yojson.Safe.from_string result in
    let match_count = Yojson.Safe.Util.(json |> member "match_count" |> to_int) in
    check int "2 unique matches (deduped)" 2 match_count)

let () =
  run "Keeper_memory"
    [
      ( "mention",
        [
          test_case "any_mentioned exact target" `Quick test_any_mentioned_exact_target;
          test_case "any_mentioned ambient message" `Quick test_any_mentioned_ambient_message;
          test_case "policy observation direct mention" `Quick
            test_keeper_policy_observation_direct_mention;
          test_case "policy observation ambient message" `Quick
            test_keeper_policy_observation_non_mention;
          test_case "user visible reply strips state block" `Quick
            test_user_visible_reply_strips_state_block;
          test_case "user visible reply strips skill and state markers" `Quick
            test_user_visible_reply_strips_skill_and_state_markers;
          test_case "user visible reply falls back to snapshot progress" `Quick
            test_user_visible_reply_falls_back_to_snapshot_progress;
        ] );
      ( "history_recall",
        [
          test_case "load_history_user_messages from jsonl" `Quick
            test_load_history_user_messages;
          test_case "recall_candidates_with_history deduplicates" `Quick
            test_recall_candidates_with_history_dedup;
          test_case "recall_candidates_with_history appends history" `Quick
            test_recall_candidates_with_history_appends;
        ] );
      ( "prioritized_action",
        [
          test_case "none when no rules fire" `Quick test_prioritized_action_none;
          test_case "guardrail_stop highest priority" `Quick test_prioritized_action_guardrail_stop;
          test_case "reflect over plan" `Quick test_prioritized_action_reflect_over_plan;
          test_case "plan over compact" `Quick test_prioritized_action_plan_over_compact;
          test_case "compact over handoff" `Quick test_prioritized_action_compact_over_handoff;
          test_case "handoff alone" `Quick test_prioritized_action_handoff_alone;
          test_case "guardrail default reason" `Quick test_prioritized_action_guardrail_default_reason;
          test_case "to_string all variants" `Quick test_prioritized_action_to_string_all_variants;
        ] );
      ( "e2e_memory_pipeline",
        [
          test_case "write with [STATE] then recall" `Quick
            test_memory_write_then_recall_with_state_block;
          test_case "write via meta fallback then recall" `Quick
            test_memory_write_then_recall_meta_fallback;
        ] );
      ( "cross_generation_search",
        [
          test_case "finds messages from history.jsonl" `Quick
            test_memory_search_cross_generation;
          test_case "finds messages from checkpoint only" `Quick
            test_memory_search_checkpoint_only;
          test_case "deduplicates checkpoint and history" `Quick
            test_memory_search_dedup;
        ] );
    ]
