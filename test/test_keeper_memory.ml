open Alcotest

module Mention = Mention
module Keeper_execution = Masc_mcp.Keeper_execution
module Keeper_memory = Masc_mcp.Keeper_memory
module Keeper_memory_recall = Masc_mcp.Keeper_memory_recall
module Keeper_world_observation = Masc_mcp.Keeper_world_observation
module Meas = Masc_mcp.Keeper_measurement
module Keeper_types = Masc_mcp.Keeper_types
module KET = Masc_mcp.Keeper_exec_tools
module KEC = Masc_mcp.Keeper_exec_context
module Types = Masc_domain

let keeper_meta ?(trace_id = "trace-1") ?(trace_history = []) ~name ~mention_targets () =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("trace_id", `String trace_id);
        ("goal", `String "keep continuity");
        ("mention_targets", `List (List.map (fun target -> `String target) mention_targets));
        ("trace_history", `List (List.map (fun s -> `String s) trace_history));
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error err -> fail ("failed to build keeper meta: " ^ err)

let room_message content =
  {
    Masc_domain.seq = 1;
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
  let meta = keeper_meta ~name:"sangsu" ~mention_targets:[ "sangsu"; "director" ] () in
  let obs =
    Keeper_memory.keeper_policy_observation_of_room_message
      ~meta ~room_id:"default" (room_message "@director, what do you think?")
  in
  check bool "keeper observation uses mention targets" true obs.direct_mention

let test_keeper_policy_observation_non_mention () =
  let meta = keeper_meta ~name:"sangsu" ~mention_targets:[ "sangsu"; "director" ] () in
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

let base_measurement : Meas.measurement_snapshot = {
  snapshot_id = "measurement-1";
  keeper_name = "memory-keeper";
  generation = 1;
  timestamp = 1000.0;
  thresholds = {
    compaction_ratio_gate = 0.5;
    compaction_message_gate = 100;
    compaction_token_gate = 1000;
    compaction_cooldown_sec = 60;
    handoff_threshold = 0.85;
    handoff_cooldown_sec = 300;
    auto_handoff_enabled = true;
    reflect_repetition_threshold = 0.7;
    plan_goal_alignment_threshold = 0.3;
    plan_response_alignment_threshold = 0.3;
    guardrail_repetition_threshold = 0.9;
    guardrail_goal_alignment_threshold = 0.2;
    guardrail_response_alignment_threshold = 0.2;
    guardrail_context_threshold = 0.8;
    max_consecutive_hb_failures = 5;
    max_consecutive_turn_failures = 3;
    model_ratio_multiplier = 1.0;
    model_handoff_multiplier = 1.0;
  };
  context = {
    context_ratio = 0.3;
    message_count = 20;
    token_count = 200;
    max_tokens = 10000;
  };
  similarity = {
    repetition_risk = 0.1;
    goal_alignment = 0.8;
    response_alignment = 0.8;
    similarity_measurable = true;
  };
  timing = {
    now_ts = 1000.0;
    idle_seconds = 0;
    since_last_compaction_sec = 600.0;
    since_last_handoff_sec = 600.0;
    proactive_warmup_elapsed = true;
  };
  failures = {
    consecutive_hb_failures = 0;
    consecutive_turn_failures = 0;
  };
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

let test_auto_rule_eval_of_measurement_respects_cooldown () =
  let measurement = {
    base_measurement with
    context = { base_measurement.context with context_ratio = 0.6 };
    timing = { base_measurement.timing with since_last_compaction_sec = 30.0 };
  } in
  let eval = Recall.keeper_auto_rule_eval_of_measurement measurement in
  check bool "compaction blocked by cooldown" false eval.compact

let test_auto_rule_eval_of_measurement_plan_requires_both_low () =
  let measurement = {
    base_measurement with
    similarity =
      { base_measurement.similarity with
        goal_alignment = 0.2;
        response_alignment = 0.8;
      };
  } in
  let eval = Recall.keeper_auto_rule_eval_of_measurement measurement in
  check bool "single low alignment does not plan" false eval.plan

let test_evaluate_keeper_auto_rules_plan_requires_both_low () =
  let meta = keeper_meta ~name:"rules-keeper" ~mention_targets:["rules-keeper"] () in
  let meta = {
    meta with
    compaction = {
      meta.compaction with
      ratio_gate = 0.5;
      message_gate = 100;
      token_gate = 1000;
      cooldown_sec = 60;
    };
    handoff_threshold = 0.85;
    handoff_cooldown_sec = 300;
    auto_handoff = true;
  } in
  let eval =
    Keeper_memory_recall.evaluate_keeper_auto_rules
      ~meta
      ~context_ratio:0.3
      ~message_count:20
      ~token_count:200
      ~repetition_risk:0.1
      ~goal_alignment:0.2
      ~response_alignment:0.8
      ()
  in
  check bool "public evaluator uses same plan contract" false eval.plan

(* #10012: status_tick / heartbeat / empty-reply turns used to trigger
   plan because the [goal_alignment_score] fallback was 0.0 — conflating
   "no data to measure alignment" with "total misalignment". The plan
   gate [goal_alignment <= 0.060] then fired on every such turn.  The
   fixed sentinel is 1.0 ("perfect alignment" ≡ "no intervention
   needed when we cannot measure"); the complement [goal_drift = 0.0]
   also reads clean, so neither the plan gate nor the drift-alert
   gate false-fires. *)
let test_goal_alignment_score_missing_messages_returns_sentinel () =
  let meta = keeper_meta ~name:"ga-keeper" ~mention_targets:["ga-keeper"] () in
  (* goal_horizon_candidates may return [] for the bare meta — this case
     is the first arm of the fix (goals = [] → 1.0). *)
  let empty_goals_score =
    Keeper_memory_recall.goal_alignment_score
      ~meta ~user_message:None ~assistant_reply:None
  in
  check (float 0.001)
    "goal_alignment=1.0 when no goals AND no messages (#10012)"
    1.0 empty_goals_score;
  let missing_both_score =
    Keeper_memory_recall.goal_alignment_score
      ~meta ~user_message:None ~assistant_reply:None
  in
  check (float 0.001)
    "goal_alignment=1.0 when both messages missing (#10012)"
    1.0 missing_both_score

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

let rec cleanup_tmpdir_recursive dir =
  if Sys.file_exists dir && Sys.is_directory dir then begin
    Array.iter (fun f ->
      let path = Filename.concat dir f in
      if Sys.is_directory path then cleanup_tmpdir_recursive path
      else (try Sys.remove path with _ -> ()))
      (Sys.readdir dir);
    (try Unix.rmdir dir with _ -> ())
  end

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

let test_load_history_user_messages_ignores_internal_prompt_entries () =
  let dir = test_tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup_tmpdir dir) (fun () ->
    let path = Filename.concat dir "history.jsonl" in
    let lines = [
      {|{"role":"user","source":"world_state_prompt","content":"## Current World State\n\n### Namespace State\n- Unclaimed tasks: 1\n\n### Available Tools\n- keeper_board_list\n\n### Continuity\nGoal: keep going"}|};
      {|{"role":"user","content":"real user question"}|};
      {|{"role":"user","source":"memory_jsonl","content":"## Current World State\n\n### Namespace State\n- User-authored world memory should survive history filtering"}|};
      {|{"role":"user","content":"second real question"}|};
    ] in
    let oc = open_out path in
    List.iter (fun l -> output_string oc (l ^ "\n")) lines;
    close_out oc;
    let result = Keeper_memory_recall.load_history_user_messages ~path ~max_n:10 in
    check int "prompt source dropped, user-authored world kept" 3 (List.length result);
    check string "first real" "real user question" (List.hd result);
    check string "world memory kept"
      "## Current World State\n\n### Namespace State\n- User-authored world memory should survive history filtering"
      (List.nth result 1);
    check string "second real" "second real question" (List.nth result 2))

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
module Coord = Masc_mcp.Coord

(** Create a minimal Coord.config for testing with a temp base_path.
    Uses Coord.default_config which creates FileSystem backend. *)
let make_test_room_config dir =
  Coord.default_config dir

(** E2E: write memory via append_memory_notes_from_reply, then read back via recall.
    Tests the full pipeline: reply → parse → snapshot → candidates → JSONL → recall.
    This is the test that was missing (RFC #3646 I1). *)
let test_memory_write_then_recall_with_state_block () =
  let dir = test_tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup_tmpdir dir) (fun () ->
    let config = make_test_room_config dir in
    let meta = keeper_meta ~name:"e2e-keeper" ~mention_targets:["e2e-keeper"] () in

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
      Keeper_memory_bank.append_memory_notes_from_reply config meta ~turn:1 ~reply ()
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
    let meta = keeper_meta ~name:"fallback-keeper" ~mention_targets:["fallback-keeper"] () in

    (* Reply WITHOUT [STATE] block — should trigger meta-based fallback *)
    let reply = "네, 이해했습니다. 바로 작업을 시작하겠습니다." in

    let (notes_written, kinds) =
      Keeper_memory_bank.append_memory_notes_from_reply config meta ~turn:1 ~reply ()
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

let read_memory_bank_entries config name =
  let path = Keeper_types.keeper_memory_bank_path config name in
  if not (Sys.file_exists path) then []
  else
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
      let rec loop acc =
        match input_line ic with
        | line when String.trim line = "" -> loop acc
        | line -> loop (Yojson.Safe.from_string line :: acc)
        | exception End_of_file -> List.rev acc
      in
      loop [])

let test_memory_write_persists_horizon_and_source () =
  let dir = test_tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup_tmpdir dir) (fun () ->
    let config = make_test_room_config dir in
    let meta = keeper_meta ~name:"meta-keeper" ~mention_targets:["meta-keeper"] () in
    let reply =
      "[STATE]\n\
       Goal: keep provenance\n\
       NEXT: verify continuity via filesystem evidence\n\
       [/STATE]"
    in
    let (_notes_written, _kinds) =
      Keeper_memory_bank.append_memory_notes_from_reply config meta ~turn:2 ~reply ()
    in
    let entries = read_memory_bank_entries config "meta-keeper" in
    check bool "entries persisted" true (entries <> []);
    let next_entry =
      List.find_opt
        (fun json ->
          Yojson.Safe.Util.(json |> member "kind" |> to_string = "next"))
        entries
    in
    match next_entry with
    | None -> fail "expected next memory entry"
    | Some json ->
        check string "horizon persisted" "short_term"
          Yojson.Safe.Util.(json |> member "horizon" |> to_string);
        check string "source persisted" "reply_state_block"
          Yojson.Safe.Util.(json |> member "source" |> to_string);
        check int "schema version persisted" 2
          Yojson.Safe.Util.(json |> member "schema_version" |> to_int))

let test_tool_result_promotes_to_long_term_memory () =
  let dir = test_tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup_tmpdir dir) (fun () ->
    let config = make_test_room_config dir in
    let meta =
      keeper_meta ~name:"tool-result-keeper"
        ~mention_targets:["tool-result-keeper"] ()
    in
    let tagged_result =
      `Assoc
        [
          ("__multimodal_kind", `String "doc");
          ( "__multimodal_id",
            `String "01900000-0000-7000-8000-0000000000aa" );
          ( "__multimodal_metadata",
            `Assoc [ ("source_tool", `String "keeper_doc_probe") ] );
          ( "body",
            `String "durable tool result evidence for the next turn" );
        ]
    in
    let untagged_result =
      `Assoc
        [
          ( "body",
            `String
              "ordinary tool result should stay out of long term memory" );
        ]
    in
    let written =
      Keeper_memory_bank.append_memory_notes_from_tool_results
        config meta ~turn:3 ~results:[ tagged_result; untagged_result ]
    in
    check int "only tagged tool result written" 1 written;
    let entries =
      read_memory_bank_entries config "tool-result-keeper"
    in
    check int "one memory row" 1 (List.length entries);
    match entries with
    | [ json ] ->
        check string "kind is long_term" "long_term"
          Yojson.Safe.Util.(json |> member "kind" |> to_string);
        check string "horizon is long_term" "long_term"
          Yojson.Safe.Util.(json |> member "horizon" |> to_string);
        check string "source is tool_result" "tool_result"
          Yojson.Safe.Util.(json |> member "source" |> to_string);
        check string "artifact kind persisted" "doc"
          Yojson.Safe.Util.(json |> member "artifact_kind" |> to_string);
        let text =
          Yojson.Safe.Util.(json |> member "text" |> to_string)
        in
        check bool "text carries payload evidence" true
          (Astring.String.is_infix
             ~affix:"durable tool result evidence" text)
    | _ -> fail "expected a single tool-result memory row")

let test_memory_candidates_capture_next_summary () =
  let snapshot =
    {
      Masc_mcp.Keeper_memory_policy.empty_keeper_state_snapshot with
      goal = Some "preserve next plan";
      next_summary = Some "verify harness output and update docs";
    }
  in
  let selection = Keeper_memory_bank.memory_candidates_from_snapshot snapshot in
  let candidates = selection.selected in
  check bool "next summary becomes a next candidate" true
    (List.exists
       (fun (kind, text, _) ->
         kind = "next"
         && String.equal text "verify harness output and update docs")
       candidates)

let test_priority_for_kind_long_term () =
  check int "long_term gets durable priority" 95
    (Masc_mcp.Keeper_memory_policy.priority_for_kind ~kind:"long_term")

let test_read_continuity_summary_prefers_progress_log () =
  let dir = test_tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup_tmpdir_recursive dir) (fun () ->
    let config = make_test_room_config dir in
    let meta = keeper_meta ~name:"progress-pref-keeper" ~mention_targets:["progress-pref-keeper"] () in
    let progress_path = Keeper_types.keeper_progress_path config "progress-pref-keeper" in
    Keeper_types.mkdir_p (Filename.dirname progress_path);
    (match
       Fs_compat.save_file_atomic progress_path
         "# Keeper Progress\nGoal: recover from progress file\nNEXT: verify only progress path is used\n"
     with
     | Ok () -> ()
     | Error err -> fail ("failed to seed progress log: " ^ err));
    let continuity =
      Keeper_world_observation.read_continuity_summary ~config ~meta
    in
    check bool "reads goal from progress log" true
      (String.contains continuity 'r' && Astring.String.is_infix ~affix:"recover from progress file" continuity);
    check bool "reads next plan from progress log" true
      (Astring.String.is_infix ~affix:"verify only progress path is used" continuity))

let test_keeper_context_status_reports_recovery_source_and_tiers () =
  let dir = test_tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup_tmpdir_recursive dir) (fun () ->
    let config = make_test_room_config dir in
    let meta = keeper_meta ~name:"status-keeper" ~mention_targets:["status-keeper"] () in
    let progress_path = Keeper_types.keeper_progress_path config "status-keeper" in
    Keeper_types.mkdir_p (Filename.dirname progress_path);
    (match
       Fs_compat.save_file_atomic progress_path
         "# Keeper Progress\nGoal: status recovery\nNEXT: emit recovery source\n"
     with
     | Ok () -> ()
     | Error err -> fail ("failed to seed progress log: " ^ err));
    let bank_path = Keeper_types.keeper_memory_bank_path config "status-keeper" in
    (match
       Fs_compat.save_file_atomic bank_path
         (Yojson.Safe.to_string
            (`Assoc
               [
                 "kind", `String "long_term";
                 "horizon", `String "long_term";
                 "source", `String "cross_trace_recurrence";
                 "schema_version", `Int 2;
                 "text", `String "durable note";
                 "priority", `Int 95;
                 "generation", `Int 1;
                 "turn", `Int 1;
                 "ts_unix", `Float 1000.0;
                 "ts", `String "2026-01-01T00:00:00Z";
               ])
          ^ "\n")
     with
     | Ok () -> ()
     | Error err -> fail ("failed to seed memory bank: " ^ err));
    let ctx_work = KEC.create ~system_prompt:"test" ~max_tokens:4096 in
    let json =
      Masc_mcp.Keeper_exec_memory.keeper_context_status_json
        ~config ~meta ~ctx_work
      |> Yojson.Safe.from_string
    in
    check string "recovery source exposed" "progress_log"
      Yojson.Safe.Util.(json |> member "recovery_source" |> to_string);
    check string "sandbox root is tool-ready" "."
      Yojson.Safe.Util.(json |> member "sandbox_root" |> to_string);
    check string "sandbox repos is tool-ready" "repos"
      Yojson.Safe.Util.(json |> member "sandbox_repos" |> to_string);
    check string "sandbox backend is local by default" "local"
      Yojson.Safe.Util.(json |> member "sandbox_backend" |> to_string);
    check int "long-term count exposed" 1
      Yojson.Safe.Util.(json |> member "memory_tier_summary" |> member "long_term" |> to_int))

let test_progress_snapshot_cache_tracks_generation () =
  let snapshot =
    {
      Masc_mcp.Keeper_memory_policy.empty_keeper_state_snapshot with
      goal = Some "stabilize recovery";
      next_summary = Some "verify generation gating";
    }
  in
  let text =
    Masc_mcp.Keeper_memory_policy.progress_markdown_of_snapshot
      ~generation:7 snapshot
  in
  match Masc_mcp.Keeper_memory_policy.progress_snapshot_cache_of_text text with
  | None -> fail "expected progress cache to parse"
  | Some cache ->
      check (option int) "generation parsed from progress header" (Some 7)
        cache.generation;
      check (option string) "snapshot goal preserved"
        (Some "stabilize recovery")
        cache.snapshot.goal

let test_prompt_memory_sections_drop_stale_short_term () =
  let snapshot =
    {
      Masc_mcp.Keeper_memory_policy.empty_keeper_state_snapshot with
      goal = Some "durable keeper goal";
      next_summary = Some "stale next step";
      next_items = [ "old action item" ];
    }
  in
  let stale_text =
    Masc_mcp.Keeper_memory_policy.prompt_memory_sections_of_snapshot
      ~current_generation:3
      ~source_generation:2
      snapshot
    |> String.concat "\n\n"
  in
  let fresh_text =
    Masc_mcp.Keeper_memory_policy.prompt_memory_sections_of_snapshot
      ~current_generation:3
      ~source_generation:3
      snapshot
    |> String.concat "\n\n"
  in
  check bool "stale progress hides short-term memory" false
    (Astring.String.is_infix ~affix:"Short-term memory" stale_text);
  check bool "stale progress keeps mid-term memory" true
    (Astring.String.is_infix ~affix:"Mid-term memory" stale_text);
  check bool "fresh progress keeps short-term memory" true
    (Astring.String.is_infix ~affix:"Short-term memory" fresh_text)

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
    let meta = keeper_meta ~name:"cross-gen-keeper" ~mention_targets:["cross-gen-keeper"] () in
    let trace_id = meta.runtime.trace_id in
    (* Write history.jsonl with messages from previous generations *)
    let history_path = Keeper_types.keeper_history_path config (Masc_mcp.Keeper_id.Trace_id.to_string trace_id) in
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
    let result = KET.execute_keeper_tool_call ~config ~meta ~ctx_work ~exec_cache:None
      ~name:"keeper_memory_search"
      ~input:(`Assoc [ ("query", `String "canary"); ("limit", `Int 5); ("source", `String "history") ])
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
    let meta = keeper_meta ~name:"ckpt-keeper" ~mention_targets:["ckpt-keeper"] () in
    (* No history.jsonl — only checkpoint messages *)
    let ctx_work = KEC.create ~system_prompt:"test" ~max_tokens:4096 in
    let ctx_work = KEC.append ctx_work
      (Agent_sdk.Types.text_message Agent_sdk.Types.User "optimize the database query") in
    let result = KET.execute_keeper_tool_call ~config ~meta ~ctx_work ~exec_cache:None
      ~name:"keeper_memory_search"
      ~input:(`Assoc [ ("query", `String "database"); ("limit", `Int 5); ("source", `String "history") ])
      () in
    let json = Yojson.Safe.from_string result in
    let match_count = Yojson.Safe.Util.(json |> member "match_count" |> to_int) in
    check bool "found database from checkpoint" true (match_count > 0))

(** Test: deduplication — same message in checkpoint and history appears once. *)
let test_memory_search_dedup () =
  let dir = test_tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup_tmpdir_r dir) (fun () ->
    let config = make_test_room_config dir in
    let meta = keeper_meta ~name:"dedup-keeper" ~mention_targets:["dedup-keeper"] () in
    let trace_id = meta.runtime.trace_id in
    let history_path = Keeper_types.keeper_history_path config (Masc_mcp.Keeper_id.Trace_id.to_string trace_id) in
    write_lines history_path [
      {|{"role":"user","content":"unique needle from history"}|};
      {|{"role":"user","content":"shared needle message"}|};
    ];
    let ctx_work = KEC.create ~system_prompt:"test" ~max_tokens:4096 in
    let ctx_work = KEC.append ctx_work
      (Agent_sdk.Types.text_message Agent_sdk.Types.User "shared needle message") in
    let result = KET.execute_keeper_tool_call ~config ~meta ~ctx_work ~exec_cache:None
      ~name:"keeper_memory_search"
      ~input:(`Assoc [ ("query", `String "needle"); ("limit", `Int 10); ("source", `String "history") ])
      () in
    let json = Yojson.Safe.from_string result in
    let match_count = Yojson.Safe.Util.(json |> member "match_count" |> to_int) in
    check int "2 unique matches (deduped)" 2 match_count)

(** Test: keeper_memory_search finds messages from a PREVIOUS generation's
    history.jsonl via trace_history.  This is the true cross-generation test. *)
let test_memory_search_prev_generation () =
  let dir = test_tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup_tmpdir_r dir) (fun () ->
    let config = make_test_room_config dir in
    let prev_trace = "gen-0-trace" in
    let curr_trace = "gen-1-trace" in
    let meta = keeper_meta
      ~trace_id:curr_trace
      ~trace_history:[prev_trace]
      ~name:"multi-gen-keeper"
      ~mention_targets:["multi-gen-keeper"]
      () in
    (* Previous generation's history — different trace_id directory *)
    let prev_history_path = Keeper_types.keeper_history_path config prev_trace in
    write_lines prev_history_path [
      {|{"role":"user","content":"migrate the postgres schema to v3"}|};
      {|{"role":"user","content":"rollback the failed deployment"}|};
    ];
    (* Current generation's history — empty (just started) *)
    let curr_history_path = Keeper_types.keeper_history_path config curr_trace in
    write_lines curr_history_path [
      {|{"role":"user","content":"check cluster health"}|};
    ];
    (* Checkpoint has only new-gen messages *)
    let ctx_work = KEC.create ~system_prompt:"test" ~max_tokens:4096 in
    let ctx_work = KEC.append ctx_work
      (Agent_sdk.Types.text_message Agent_sdk.Types.User "status report") in
    (* Search for "postgres" — only in previous generation's history *)
    let result = KET.execute_keeper_tool_call ~config ~meta ~ctx_work ~exec_cache:None
      ~name:"keeper_memory_search"
      ~input:(`Assoc [ ("query", `String "postgres"); ("limit", `Int 5); ("source", `String "history") ])
      () in
    let json = Yojson.Safe.from_string result in
    let match_count = Yojson.Safe.Util.(json |> member "match_count" |> to_int) in
    check bool "found postgres from previous generation" true (match_count > 0);
    let matches = Yojson.Safe.Util.(json |> member "matches" |> to_list
      |> List.map to_string) in
    check bool "match references schema migration" true
      (List.exists (fun m -> Re.execp (Re.str "postgres" |> Re.compile) m) matches);
    (* Also verify current generation is searchable *)
    let result2 = KET.execute_keeper_tool_call ~config ~meta ~ctx_work ~exec_cache:None
      ~name:"keeper_memory_search"
      ~input:(`Assoc [ ("query", `String "cluster"); ("limit", `Int 5); ("source", `String "history") ])
      () in
    let json2 = Yojson.Safe.from_string result2 in
    let match2 = Yojson.Safe.Util.(json2 |> member "match_count" |> to_int) in
    check bool "found cluster from current generation" true (match2 > 0))

(* ================================================================ *)
(* Memory Bank Search Tests (structured notes from memory.jsonl)     *)
(* ================================================================ *)

(** Helper: write memory bank JSONL lines for a keeper. *)
let write_memory_bank config name lines =
  let path = Keeper_types.keeper_memory_bank_path config name in
  write_lines path lines

let memory_note ?horizon ?source ~kind ~text ~priority ~generation ~turn ~ts_unix () =
  let extra_fields =
    (match horizon with
     | Some value -> [ ("horizon", `String value) ]
     | None -> [])
    @
    (match source with
     | Some value -> [ ("source", `String value) ]
     | None -> [])
  in
  Yojson.Safe.to_string
    (`Assoc
      ([
         ("ts", `String "2026-04-06T00:00:00Z");
         ("ts_unix", `Float ts_unix);
         ("name", `String "test");
         ("trace_id", `String "t1");
         ("generation", `Int generation);
         ("turn", `Int turn);
         ("kind", `String kind);
         ("priority", `Int priority);
         ("text", `String text);
       ] @ extra_fields))

(** Test: memory bank search returns structured results with scoring. *)
let test_memory_search_bank_basic () =
  let dir = test_tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup_tmpdir_r dir) (fun () ->
    let config = make_test_room_config dir in
    let meta = keeper_meta ~name:"bank-keeper" ~mention_targets:["bank-keeper"] () in
    write_memory_bank config "bank-keeper" [
      memory_note ~kind:"decision" ~text:"Switched to Postgres for persistence"
        ~priority:86 ~generation:1 ~turn:3 ~ts_unix:1000.0 ();
      memory_note ~kind:"goal" ~text:"Improve search quality"
        ~priority:72 ~generation:1 ~turn:1 ~ts_unix:900.0 ();
      memory_note ~kind:"progress" ~text:"Implemented basic keyword matching"
        ~priority:66 ~generation:2 ~turn:5 ~ts_unix:1100.0 ();
    ];
    let ctx_work = KEC.create ~system_prompt:"test" ~max_tokens:4096 in
    let result = KET.execute_keeper_tool_call ~config ~meta ~ctx_work ~exec_cache:None
      ~name:"keeper_memory_search"
      ~input:(`Assoc [ ("query", `String "Postgres") ])
      () in
    let json = Yojson.Safe.from_string result in
    let source = Yojson.Safe.Util.(json |> member "source" |> to_string) in
    check string "default source is memory" "memory" source;
    let match_count = Yojson.Safe.Util.(json |> member "match_count" |> to_int) in
    check bool "found Postgres" true (match_count > 0);
    let first_match = Yojson.Safe.Util.(json |> member "matches" |> to_list |> List.hd) in
    let kind = Yojson.Safe.Util.(first_match |> member "kind" |> to_string) in
    check string "match kind is decision" "decision" kind;
    let score = Yojson.Safe.Util.(first_match |> member "score" |> to_float) in
    check bool "score is positive" true (score > 0.0))

(** Test: kind filter narrows results to matching kind only. *)
let test_memory_search_bank_kind_filter () =
  let dir = test_tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup_tmpdir_r dir) (fun () ->
    let config = make_test_room_config dir in
    let meta = keeper_meta ~name:"filter-keeper" ~mention_targets:["filter-keeper"] () in
    write_memory_bank config "filter-keeper" [
      memory_note ~kind:"decision" ~text:"use Postgres" ~priority:86 ~generation:1 ~turn:1 ~ts_unix:1000.0 ();
      memory_note ~kind:"goal" ~text:"use Redis" ~priority:72 ~generation:1 ~turn:2 ~ts_unix:1100.0 ();
      memory_note ~kind:"progress" ~text:"use Postgres done" ~priority:66 ~generation:1 ~turn:3 ~ts_unix:1200.0 ();
    ];
    let ctx_work = KEC.create ~system_prompt:"test" ~max_tokens:4096 in
    (* Search with kind=goal — should only return "use Redis" *)
    let result = KET.execute_keeper_tool_call ~config ~meta ~ctx_work ~exec_cache:None
      ~name:"keeper_memory_search"
      ~input:(`Assoc [ ("query", `String "use"); ("kind", `String "goal") ])
      () in
    let json = Yojson.Safe.from_string result in
    let match_count = Yojson.Safe.Util.(json |> member "match_count" |> to_int) in
    check int "only 1 goal match" 1 match_count;
    let first = Yojson.Safe.Util.(json |> member "matches" |> to_list |> List.hd) in
    let text = Yojson.Safe.Util.(first |> member "text" |> to_string) in
    check bool "text contains Redis" true (Re.execp (Re.str "Redis" |> Re.compile) text))

(** Test: results sorted by score descending. *)
let test_memory_search_bank_scored_order () =
  let dir = test_tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup_tmpdir_r dir) (fun () ->
    let config = make_test_room_config dir in
    let meta = keeper_meta ~name:"score-keeper" ~mention_targets:["score-keeper"] () in
    write_memory_bank config "score-keeper" [
      memory_note ~kind:"progress" ~text:"task alpha" ~priority:50 ~generation:1 ~turn:1 ~ts_unix:100.0 ();
      memory_note ~kind:"decision" ~text:"task alpha upgrade" ~priority:90 ~generation:2 ~turn:3 ~ts_unix:200.0 ();
    ];
    let ctx_work = KEC.create ~system_prompt:"test" ~max_tokens:4096 in
    let result = KET.execute_keeper_tool_call ~config ~meta ~ctx_work ~exec_cache:None
      ~name:"keeper_memory_search"
      ~input:(`Assoc [ ("query", `String "alpha"); ("limit", `Int 5) ])
      () in
    let json = Yojson.Safe.from_string result in
    let matches = Yojson.Safe.Util.(json |> member "matches" |> to_list) in
    check bool "2 matches" true (List.length matches = 2);
    let s1 = Yojson.Safe.Util.(List.nth matches 0 |> member "score" |> to_float) in
    let s2 = Yojson.Safe.Util.(List.nth matches 1 |> member "score" |> to_float) in
    check bool "first score >= second score" true (s1 >= s2))

let test_memory_search_bank_prefers_long_term_over_stale_short_term () =
  let dir = test_tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup_tmpdir_r dir) (fun () ->
    let config = make_test_room_config dir in
    let base_meta =
      keeper_meta ~name:"horizon-keeper" ~mention_targets:["horizon-keeper"] ()
    in
    let meta =
      { base_meta with
        runtime = { base_meta.runtime with generation = 4 } }
    in
    write_memory_bank config "horizon-keeper" [
      memory_note
        ~kind:"next"
        ~horizon:"short_term"
        ~source:"reply_state_block"
        ~text:"postgres evidence trail"
        ~priority:80 ~generation:1 ~turn:1 ~ts_unix:2000.0 ();
      memory_note
        ~kind:"long_term"
        ~horizon:"long_term"
        ~source:"cross_trace_recurrence"
        ~text:"postgres evidence trail"
        ~priority:95 ~generation:1 ~turn:2 ~ts_unix:1000.0 ();
    ];
    let ctx_work = KEC.create ~system_prompt:"test" ~max_tokens:4096 in
    let result = KET.execute_keeper_tool_call ~config ~meta ~ctx_work ~exec_cache:None
      ~name:"keeper_memory_search"
      ~input:(`Assoc [ ("query", `String "postgres evidence trail") ])
      () in
    let json = Yojson.Safe.from_string result in
    let first = Yojson.Safe.Util.(json |> member "matches" |> to_list |> List.hd) in
    check string "long_term ranked first" "long_term"
      Yojson.Safe.Util.(first |> member "kind" |> to_string);
    check string "long_term horizon surfaced" "long_term"
      Yojson.Safe.Util.(first |> member "horizon" |> to_string))

(** Test: empty memory bank returns no_match: true *)
let test_memory_search_bank_empty () =
  let dir = test_tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup_tmpdir_r dir) (fun () ->
    let config = make_test_room_config dir in
    let meta = keeper_meta ~name:"empty-keeper" ~mention_targets:["empty-keeper"] () in
    let ctx_work = KEC.create ~system_prompt:"test" ~max_tokens:4096 in
    let result = KET.execute_keeper_tool_call ~config ~meta ~ctx_work ~exec_cache:None
      ~name:"keeper_memory_search"
      ~input:(`Assoc [ ("query", `String "anything") ])
      () in
    let json = Yojson.Safe.from_string result in
    let no_match = Yojson.Safe.Util.(json |> member "no_match" |> to_bool) in
    check bool "no_match is true" true no_match;
    let match_count = Yojson.Safe.Util.(json |> member "match_count" |> to_int) in
    check int "match_count is 0" 0 match_count)

let test_memory_search_decision_log_failure_is_observable () =
  let dir = test_tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup_tmpdir_r dir) (fun () ->
    let config = make_test_room_config dir in
    let keeper_name = "memory-search-log-failure" in
    let meta = keeper_meta ~name:keeper_name ~mention_targets:[keeper_name] () in
    Keeper_types.mkdir_p (Keeper_types.keeper_decision_log_path config keeper_name);
    let ctx_work = KEC.create ~system_prompt:"test" ~max_tokens:4096 in
    let before =
      Masc_mcp.Prometheus.metric_value_or_zero
        Masc_mcp.Prometheus.metric_keeper_decision_audit_flush_failures
        ~labels:[("keeper", keeper_name)]
        ()
    in
    let result = KET.execute_keeper_tool_call ~config ~meta ~ctx_work ~exec_cache:None
      ~name:"keeper_memory_search"
      ~input:(`Assoc [ ("query", `String "anything") ])
      () in
    let after =
      Masc_mcp.Prometheus.metric_value_or_zero
        Masc_mcp.Prometheus.metric_keeper_decision_audit_flush_failures
        ~labels:[("keeper", keeper_name)]
        ()
    in
    let json = Yojson.Safe.from_string result in
    let no_match = Yojson.Safe.Util.(json |> member "no_match" |> to_bool) in
    check bool "memory search still returns result" true no_match;
    check bool "decision-log append failure increments counter" true (after > before))

(** Test: query with no matching text returns no_match: true *)
let test_memory_search_bank_no_match () =
  let dir = test_tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup_tmpdir_r dir) (fun () ->
    let config = make_test_room_config dir in
    let meta = keeper_meta ~name:"nomatch-keeper" ~mention_targets:["nomatch-keeper"] () in
    write_memory_bank config "nomatch-keeper" [
      memory_note ~kind:"decision" ~text:"deploy to staging" ~priority:86 ~generation:1 ~turn:1 ~ts_unix:1000.0 ();
    ];
    let ctx_work = KEC.create ~system_prompt:"test" ~max_tokens:4096 in
    let result = KET.execute_keeper_tool_call ~config ~meta ~ctx_work ~exec_cache:None
      ~name:"keeper_memory_search"
      ~input:(`Assoc [ ("query", `String "nonexistent_keyword_xyz") ])
      () in
    let json = Yojson.Safe.from_string result in
    let no_match = Yojson.Safe.Util.(json |> member "no_match" |> to_bool) in
    check bool "no_match for unrelated query" true no_match)

(** Test: source=history uses legacy cross-generation search. *)
let test_memory_search_source_history () =
  let dir = test_tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup_tmpdir_r dir) (fun () ->
    let config = make_test_room_config dir in
    let meta = keeper_meta ~name:"hist-keeper" ~mention_targets:["hist-keeper"] () in
    let trace_id = meta.runtime.trace_id in
    let history_path = Keeper_types.keeper_history_path config (Masc_mcp.Keeper_id.Trace_id.to_string trace_id) in
    write_lines history_path [
      {|{"role":"user","content":"deploy the legacy service"}|};
    ];
    let ctx_work = KEC.create ~system_prompt:"test" ~max_tokens:4096 in
    let result = KET.execute_keeper_tool_call ~config ~meta ~ctx_work ~exec_cache:None
      ~name:"keeper_memory_search"
      ~input:(`Assoc [ ("query", `String "legacy"); ("source", `String "history") ])
      () in
    let json = Yojson.Safe.from_string result in
    let source = Yojson.Safe.Util.(json |> member "source" |> to_string) in
    check string "source is history" "history" source;
    let match_count = Yojson.Safe.Util.(json |> member "match_count" |> to_int) in
    check bool "found legacy in history" true (match_count > 0))

(** Test: source=all merges memory bank and history results. *)
let test_memory_search_source_all () =
  let dir = test_tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup_tmpdir_r dir) (fun () ->
    let config = make_test_room_config dir in
    let meta = keeper_meta ~name:"all-keeper" ~mention_targets:["all-keeper"] () in
    (* Memory bank has structured note *)
    write_memory_bank config "all-keeper" [
      memory_note ~kind:"decision" ~text:"alpha from bank" ~priority:86 ~generation:1 ~turn:1 ~ts_unix:1000.0 ();
    ];
    (* History has raw message *)
    let trace_id = meta.runtime.trace_id in
    let history_path = Keeper_types.keeper_history_path config (Masc_mcp.Keeper_id.Trace_id.to_string trace_id) in
    write_lines history_path [
      {|{"role":"user","content":"alpha from history"}|};
    ];
    let ctx_work = KEC.create ~system_prompt:"test" ~max_tokens:4096 in
    let result = KET.execute_keeper_tool_call ~config ~meta ~ctx_work ~exec_cache:None
      ~name:"keeper_memory_search"
      ~input:(`Assoc [ ("query", `String "alpha"); ("source", `String "all"); ("limit", `Int 10) ])
      () in
    let json = Yojson.Safe.from_string result in
    let source = Yojson.Safe.Util.(json |> member "source" |> to_string) in
    check string "source is all" "all" source;
    let match_count = Yojson.Safe.Util.(json |> member "match_count" |> to_int) in
    check bool "found matches from both sources" true (match_count >= 2))

(* ── Memory Quality Filter Tests ────────────────────────── *)

let test_quality_rejects_empty () =
  check bool "empty rejected" false (Keeper_memory_bank.is_meaningful_memory_text "")

let test_quality_rejects_none () =
  check bool "none rejected" false (Keeper_memory_bank.is_meaningful_memory_text "none")

let test_quality_rejects_korean_none () =
  check bool "없음 rejected" false (Keeper_memory_bank.is_meaningful_memory_text "없음")

let test_quality_rejects_korean_none_formal () =
  check bool "없습니다 rejected" false (Keeper_memory_bank.is_meaningful_memory_text "없습니다")

let test_quality_rejects_korean_dont_know () =
  check bool "모르겠음 rejected" false (Keeper_memory_bank.is_meaningful_memory_text "모르겠음")

let test_quality_rejects_synthetic () =
  check bool "[SYNTHETIC] rejected" false
    (Keeper_memory_bank.is_meaningful_memory_text "some [SYNTHETIC] note")

let with_env name value f =
  let previous = Sys.getenv_opt name in
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some old -> Unix.putenv name old
      | None -> Unix.putenv name "")
    (fun () ->
      Unix.putenv name value;
      f ())

let test_quality_rejects_consensus_spam () =
  with_env "MASC_KEEPER_MEMORY_CONSENSUS_PATTERN" "" @@ fun () ->
  check bool "1234567ep rejected" false
    (Keeper_memory_bank.is_meaningful_memory_text "1234567ep")

let test_quality_consensus_pattern_follows_env_changes () =
  with_env "MASC_KEEPER_MEMORY_CONSENSUS_PATTERN" "CUSTOMBLOCK" @@ fun () ->
  check bool "custom pattern rejected" false
    (Keeper_memory_bank.is_meaningful_memory_text "CUSTOMBLOCK");
  with_env "MASC_KEEPER_MEMORY_CONSENSUS_PATTERN" "OTHERBLOCK" @@ fun () ->
  check bool "new custom pattern rejected" false
    (Keeper_memory_bank.is_meaningful_memory_text "OTHERBLOCK");
  check bool "old custom pattern no longer rejected" true
    (Keeper_memory_bank.is_meaningful_memory_text "CUSTOMBLOCK")

let test_quality_invalid_consensus_pattern_falls_back () =
  with_env "MASC_KEEPER_MEMORY_CONSENSUS_PATTERN" "(" @@ fun () ->
  check bool "invalid pattern falls back to default" false
    (Keeper_memory_bank.is_meaningful_memory_text "1234567ep")

let test_quality_rejects_long_text () =
  let long = String.make 5000 'a' in
  check bool "5000 char rejected" false (Keeper_memory_bank.is_meaningful_memory_text long)

let test_quality_accepts_meaningful () =
  check bool "meaningful accepted" true
    (Keeper_memory_bank.is_meaningful_memory_text "Fix the authentication bug in login flow")

(* ── Memory Row Validation Tests ───────────────────────── *)

let test_priority_clamp_low () =
  let line =
    {|{"kind":"goal","text":"test","priority":-5,"ts_unix":1.0,"schema_version":2}|}
  in
  match Keeper_memory_bank.parse_memory_bank_row line with
  | Some row -> check int "clamped to 1" 1 row.priority
  | None -> fail "expected Some row"

let test_priority_clamp_high () =
  let line =
    {|{"kind":"goal","text":"test","priority":999,"ts_unix":1.0,"schema_version":2}|}
  in
  match Keeper_memory_bank.parse_memory_bank_row line with
  | Some row -> check int "clamped to 100" 100 row.priority
  | None -> fail "expected Some row"

let test_priority_valid_preserved () =
  let line =
    {|{"kind":"goal","text":"test","priority":42,"ts_unix":1.0,"schema_version":2}|}
  in
  match Keeper_memory_bank.parse_memory_bank_row line with
  | Some row -> check int "preserved 42" 42 row.priority
  | None -> fail "expected Some row"

let test_schema_version_mismatch () =
  let line =
    {|{"kind":"goal","text":"test","priority":1,"ts_unix":1.0,"schema_version":99}|}
  in
  check bool "mismatch rejected" true (Keeper_memory_bank.parse_memory_bank_row line = None)

let test_schema_version_match () =
  let line =
    {|{"kind":"goal","text":"test","priority":1,"ts_unix":1.0,"schema_version":2}|}
  in
  check bool "match accepted" true (Keeper_memory_bank.parse_memory_bank_row line <> None)

(* ── Memory Dedup Tests ────────────────────────────────── *)

let test_dedup_exact () =
  let items = [
    ("goal", "Fix bug", 10);
    ("goal", "Fix bug", 20);
    ("next", "Deploy", 30);
  ] in
  let result = Keeper_memory_bank.dedup_memory_candidates items in
  check int "exact dedup leaves 2" 2 (List.length result)

let test_dedup_semantic () =
  let items = [
    ("goal", "Fix the login bug", 10);
    ("next", "Fix the login bug", 20);
  ] in
  let result = Keeper_memory_bank.dedup_memory_candidates items in
  check int "semantic dedup leaves 1" 1 (List.length result)

let test_dedup_semantic_preserves_distinct () =
  let items = [
    ("goal", "Fix the login bug", 10);
    ("goal", "Refactor the database schema", 20);
  ] in
  let result = Keeper_memory_bank.dedup_memory_candidates items in
  check int "distinct preserved" 2 (List.length result)

(* ── Memory Cap Telemetry Tests ────────────────────────── *)

let test_cap_dropped_by_kind () =
  let rows = [
    ("goal", "Goal A", 10);
    ("goal", "Goal B", 9);
    ("goal", "Goal C", 8);
    ("progress", "Progress A", 7);
  ] in
  let result = Keeper_memory_bank.select_memory_candidates rows in
  let goal_dropped = List.assoc_opt "goal" result.dropped_by_kind in
  check (option int) "goal cap drops tracked" (Some 1) goal_dropped;
  let total = result.dropped_by_total_cap in
  check int "total cap drops 0 when under cap" 0 total

let test_cap_dropped_by_total () =
  let rows =
    List.init 2 (fun i -> ("constraints", "C" ^ string_of_int i, 100))
    @ List.init 2 (fun i -> ("decision", "D" ^ string_of_int i, 99))
    @ List.init 2 (fun i -> ("next", "N" ^ string_of_int i, 98))
    @ List.init 2 (fun i -> ("goal", "G" ^ string_of_int i, 97))
    @ List.init 2 (fun i -> ("progress", "P" ^ string_of_int i, 96))
    @ List.init 2 (fun i -> ("open_question", "Q" ^ string_of_int i, 95))
    @ List.init 4 (fun i -> ("long_term", "L" ^ string_of_int i, 94))
    @ List.init 4 (fun i -> ("long_term", "Extra " ^ string_of_int i, 1))
  in
  let result = Keeper_memory_bank.select_memory_candidates rows in
  let selected_count = List.length result.selected in
  let total_cap = Keeper_memory_bank.total_cap () in
  check int "selected within total cap" total_cap selected_count;
  let dropped = result.dropped_by_total_cap in
  check int "total drops 8" 8 dropped

let memory_metric_value ~keeper ~source ~outcome =
  Masc_mcp.Prometheus.metric_value_or_zero
    Masc_mcp.Prometheus.metric_keeper_memory_consolidations
    ~labels:[("keeper", keeper); ("source", source); ("outcome", outcome)]
    ()

let memory_bank_test_row ~kind ~trace_id ~text ~priority ~idx =
  Yojson.Safe.to_string
    (`Assoc
       [
         ("schema_version", `Int Keeper_memory_bank.keeper_memory_schema_version);
         ("kind", `String kind);
         ("horizon", `String (Keeper_memory_bank.memory_horizon_of_kind kind));
         ("source", `String "test_seed");
         ("text", `String text);
         ("priority", `Int priority);
         ("generation", `Int 1);
         ("trace_id", `String trace_id);
         ("turn", `Int idx);
         ("ts_unix", `Float (1000.0 +. float_of_int idx));
         ("ts", `String "2026-01-01T00:00:00Z");
       ])

let test_compaction_records_consolidation_metrics () =
  with_env "MASC_KEEPER_MEMORY_MAX_NOTES" "40" @@ fun () ->
  with_env "MASC_KEEPER_MEMORY_MAX_LENGTH" "4096" @@ fun () ->
  let dir = test_tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup_tmpdir_recursive dir) (fun () ->
    let keeper = "metric-memory-keeper" in
    let config = make_test_room_config dir in
    let meta = keeper_meta ~name:keeper ~mention_targets:[keeper] () in
    let bank_path = Keeper_types.keeper_memory_bank_path config keeper in
    Keeper_types.mkdir_p (Filename.dirname bank_path);
    let progress_rows =
      List.init 3 (fun i ->
        memory_bank_test_row
          ~kind:"progress"
          ~trace_id:"trace-progress"
          ~text:
            (Printf.sprintf
               "progress cluster item %d retains enough semantic detail %s"
               i (String.make 700 'p'))
          ~priority:80
          ~idx:i)
    in
    let recurring_text =
      "shared durable finding survives recurrence telemetry "
      ^ String.make 700 'r'
    in
    let recurring_rows =
      List.init 3 (fun i ->
        memory_bank_test_row
          ~kind:"decision"
          ~trace_id:(Printf.sprintf "trace-recurring-%d" i)
          ~text:recurring_text
          ~priority:85
          ~idx:(10 + i))
    in
    let filler_rows =
      List.init 74 (fun i ->
        memory_bank_test_row
          ~kind:"goal"
          ~trace_id:(Printf.sprintf "trace-fill-%d" i)
          ~text:
            (Printf.sprintf
               "filler note %03d pushes memory bank over compaction trigger %s"
               i (String.make 700 'f'))
          ~priority:10
          ~idx:(100 + i))
    in
    let content =
      String.concat "\n" (progress_rows @ recurring_rows @ filler_rows) ^ "\n"
    in
    (match Fs_compat.save_file_atomic bank_path content with
     | Ok () -> ()
     | Error err -> fail ("failed to seed memory bank: " ^ err));
    let generated_progress_before =
      memory_metric_value
        ~keeper
        ~source:"progress_consolidation"
        ~outcome:"generated"
    in
    let generated_recurrence_before =
      memory_metric_value
        ~keeper
        ~source:"cross_trace_recurrence"
        ~outcome:"generated"
    in
    let persisted_progress_before =
      memory_metric_value
        ~keeper
        ~source:"progress_consolidation"
        ~outcome:"persisted"
    in
    let persisted_recurrence_before =
      memory_metric_value
        ~keeper
        ~source:"cross_trace_recurrence"
        ~outcome:"persisted"
    in
    let compaction =
      Keeper_memory_bank.compact_memory_bank_if_needed config meta
    in
    check bool "compaction ran" true compaction.performed;
    check (float 0.001) "progress consolidation generated"
      (generated_progress_before +. 1.0)
      (memory_metric_value
         ~keeper
         ~source:"progress_consolidation"
         ~outcome:"generated");
    check (float 0.001) "recurrence consolidation generated"
      (generated_recurrence_before +. 1.0)
      (memory_metric_value
         ~keeper
         ~source:"cross_trace_recurrence"
         ~outcome:"generated");
    check (float 0.001) "progress consolidation persisted"
      (persisted_progress_before +. 1.0)
      (memory_metric_value
         ~keeper
         ~source:"progress_consolidation"
         ~outcome:"persisted");
    check (float 0.001) "recurrence consolidation persisted"
      (persisted_recurrence_before +. 1.0)
      (memory_metric_value
         ~keeper
         ~source:"cross_trace_recurrence"
         ~outcome:"persisted"))

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
          test_case "load_history_user_messages ignores internal prompt entries" `Quick
            test_load_history_user_messages_ignores_internal_prompt_entries;
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
          test_case "measurement evaluator respects cooldown" `Quick
            test_auto_rule_eval_of_measurement_respects_cooldown;
          test_case "measurement evaluator plan requires both low" `Quick
            test_auto_rule_eval_of_measurement_plan_requires_both_low;
          test_case "public evaluator plan requires both low" `Quick
            test_evaluate_keeper_auto_rules_plan_requires_both_low;
          test_case "goal_alignment_score returns sentinel on missing messages (#10012)" `Quick
            test_goal_alignment_score_missing_messages_returns_sentinel;
        ] );
      ( "e2e_memory_pipeline",
        [
          test_case "write with [STATE] then recall" `Quick
            test_memory_write_then_recall_with_state_block;
          test_case "write via meta fallback then recall" `Quick
            test_memory_write_then_recall_meta_fallback;
          test_case "memory note persists horizon + source" `Quick
            test_memory_write_persists_horizon_and_source;
          test_case "tagged tool result promotes to long_term" `Quick
            test_tool_result_promotes_to_long_term_memory;
          test_case "next summary is preserved as memory" `Quick
            test_memory_candidates_capture_next_summary;
          test_case "long_term priority matches durable tier" `Quick
            test_priority_for_kind_long_term;
        ] );
      ( "cross_generation_search",
        [
          test_case "finds messages from history.jsonl" `Quick
            test_memory_search_cross_generation;
          test_case "finds messages from checkpoint only" `Quick
            test_memory_search_checkpoint_only;
          test_case "deduplicates checkpoint and history" `Quick
            test_memory_search_dedup;
          test_case "finds messages from previous generation via trace_history" `Quick
            test_memory_search_prev_generation;
        ] );
      ( "recovery_context",
        [
          test_case "continuity prefers progress log" `Quick
            test_read_continuity_summary_prefers_progress_log;
          test_case "context status reports recovery source + tiers" `Quick
            test_keeper_context_status_reports_recovery_source_and_tiers;
          test_case "progress cache tracks generation" `Quick
            test_progress_snapshot_cache_tracks_generation;
          test_case "stale progress drops short-term prompt memory" `Quick
            test_prompt_memory_sections_drop_stale_short_term;
        ] );
      ( "memory_bank_search",
        [
          test_case "basic keyword search in memory bank" `Quick
            test_memory_search_bank_basic;
          test_case "kind filter narrows results" `Quick
            test_memory_search_bank_kind_filter;
          test_case "results sorted by score descending" `Quick
            test_memory_search_bank_scored_order;
          test_case "long_term outranks stale short-term" `Quick
            test_memory_search_bank_prefers_long_term_over_stale_short_term;
          test_case "empty bank returns no_match" `Quick
            test_memory_search_bank_empty;
          test_case "decision log append failure is observable" `Quick
            test_memory_search_decision_log_failure_is_observable;
          test_case "no matching query returns no_match" `Quick
            test_memory_search_bank_no_match;
          test_case "source=history uses legacy search" `Quick
            test_memory_search_source_history;
          test_case "source=all merges bank and history" `Quick
            test_memory_search_source_all;
        ] );
      ( "memory_quality_filter",
        [
          test_case "placeholder rejects empty" `Quick test_quality_rejects_empty;
          test_case "placeholder rejects none" `Quick test_quality_rejects_none;
          test_case "placeholder rejects korean 없음" `Quick test_quality_rejects_korean_none;
          test_case "placeholder rejects korean 없습니다" `Quick test_quality_rejects_korean_none_formal;
          test_case "placeholder rejects korean 모르겠음" `Quick test_quality_rejects_korean_dont_know;
          test_case "synthetic marker rejected" `Quick test_quality_rejects_synthetic;
          test_case "consensus spam rejected" `Quick test_quality_rejects_consensus_spam;
          test_case "consensus pattern follows env changes" `Quick
            test_quality_consensus_pattern_follows_env_changes;
          test_case "invalid consensus pattern falls back" `Quick
            test_quality_invalid_consensus_pattern_falls_back;
          test_case "max text length gate rejects long text" `Quick test_quality_rejects_long_text;
          test_case "meaningful text accepted" `Quick test_quality_accepts_meaningful;
        ] );
      ( "memory_row_validation",
        [
          test_case "priority clamped to 1 on low" `Quick test_priority_clamp_low;
          test_case "priority clamped to 100 on high" `Quick test_priority_clamp_high;
          test_case "valid priority preserved" `Quick test_priority_valid_preserved;
          test_case "schema version mismatch rejected" `Quick test_schema_version_mismatch;
          test_case "schema version match accepted" `Quick test_schema_version_match;
        ] );
      ( "memory_dedup",
        [
          test_case "exact dedup removes duplicates" `Quick test_dedup_exact;
          test_case "semantic dedup removes near-duplicates" `Quick test_dedup_semantic;
          test_case "semantic dedup preserves distinct" `Quick test_dedup_semantic_preserves_distinct;
        ] );
      ( "memory_cap_telemetry",
        [
          test_case "cap enforcement reports dropped_by_kind" `Quick test_cap_dropped_by_kind;
          test_case "total cap reports dropped_by_total_cap" `Quick test_cap_dropped_by_total;
          test_case "compaction records consolidation metrics" `Quick
            test_compaction_records_consolidation_metrics;
        ] );
    ]
