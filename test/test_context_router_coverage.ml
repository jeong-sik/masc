(** Context Router — Selective Retrieval Tests *)

open Masc_mcp.Context_router

let () = Printexc.record_backtrace true

(* ---------- Intent Classification ---------- *)

let test_conversational_intent () =
  let (intent, conf) = classify_intent "hello" in
  assert (intent = Conversational);
  assert (conf > 0.8);
  let (intent2, _) = classify_intent "감사합니다" in
  assert (intent2 = Conversational);
  let (intent3, _) = classify_intent "ok" in
  assert (intent3 = Conversational)

let test_command_intent () =
  let (intent, conf) = classify_intent "masc_claim task-001" in
  assert (intent = Task_command);
  assert (conf > 0.9);
  let (intent2, _) = classify_intent "masc_done task-001" in
  assert (intent2 = Task_command);
  let (intent3, _) = classify_intent "masc_broadcast hello everyone" in
  assert (intent3 = Task_command)

let test_status_intent () =
  let (intent, _) = classify_intent "masc_status" in
  assert (intent = Status_check);
  let (intent2, _) = classify_intent "who is working on task-001" in
  assert (intent2 = Status_check);
  let (intent3, _) = classify_intent "현재 상태 확인" in
  assert (intent3 = Status_check)

let test_knowledge_intent () =
  let (intent, _) = classify_intent "how to implement authentication" in
  assert (intent = Knowledge_query);
  let (intent2, _) = classify_intent "explain the board system" in
  assert (intent2 = Knowledge_query);
  let (intent3, _) = classify_intent "어떻게 설정하나요" in
  assert (intent3 = Knowledge_query)

let test_coordination_intent () =
  let (intent, _) = classify_intent "@claude can you review this" in
  assert (intent = Coordination)

let test_short_query () =
  let (intent, _) = classify_intent "hi" in
  assert (intent = Conversational);
  let (intent2, _) = classify_intent "ok" in
  assert (intent2 = Conversational)

let test_very_short_query () =
  let (intent, _) = classify_intent "y" in
  assert (intent = Conversational)

(* ---------- Routing Decisions ---------- *)

let test_route_skip () =
  let d = route "hello everyone" in
  assert (d.depth = Skip);
  assert (d.intent = Conversational)

let test_route_skip_command () =
  let d = route "masc_claim task-001" in
  assert (d.depth = Skip);
  assert (d.intent = Task_command)

let test_route_light () =
  let d = route "masc_status" in
  assert (d.depth = Light);
  assert (d.intent = Status_check)

let test_route_full () =
  let d = route "how to debug authentication errors" in
  assert (d.depth = Full);
  assert (d.intent = Knowledge_query)

let test_route_knowledge_with_broadcasts () =
  let broadcasts = [
    "Authentication uses JWT tokens with 1h expiry";
    "Debug auth by checking the token validation middleware";
  ] in
  let d = route ~recent_broadcasts:broadcasts
    "how to debug authentication" in
  (* Should downgrade to Light because broadcasts cover the query *)
  assert (d.depth = Light)

let test_route_knowledge_without_broadcasts () =
  let d = route ~recent_broadcasts:[]
    "how to debug authentication" in
  assert (d.depth = Full)

(* ---------- Broadcasts Coverage Check ---------- *)

let test_broadcasts_cover_query_positive () =
  let broadcasts = [
    "The deployment pipeline uses GitHub Actions and Railway";
    "Railway auto-deploys on push to main branch";
  ] in
  assert (broadcasts_cover_query
    ~recent_broadcasts:broadcasts
    ~query:"deployment pipeline uses Railway")

let test_broadcasts_cover_query_negative () =
  let broadcasts = [
    "Agent claude joined the room";
    "Task task-001 claimed by gemini";
  ] in
  assert (not (broadcasts_cover_query
    ~recent_broadcasts:broadcasts
    ~query:"how to configure authentication"))

let test_broadcasts_cover_query_empty () =
  assert (not (broadcasts_cover_query
    ~recent_broadcasts:[]
    ~query:"anything"))

let test_broadcasts_cover_short_query () =
  (* Short words (<4 chars) are filtered out, so no match possible *)
  assert (not (broadcasts_cover_query
    ~recent_broadcasts:["something"]
    ~query:"hi ok"))

(* ---------- Depth to Sources ---------- *)

let test_depth_to_sources_skip () =
  let sources = depth_to_sources Skip in
  assert (sources = [])

let test_depth_to_sources_light () =
  let sources = depth_to_sources Light in
  assert (List.length sources = 2)

let test_depth_to_sources_full () =
  let sources = depth_to_sources Full in
  assert (List.length sources = 3)

(* ---------- Recall Config Generation ---------- *)

let test_to_recall_config_skip () =
  let decision = { depth = Skip; intent = Conversational;
                   reason = "test"; confidence = 0.9 } in
  let config = to_recall_config decision in
  (* Skip should disable retrieval *)
  assert (not config.enabled)

let test_to_recall_config_light () =
  let decision = { depth = Light; intent = Status_check;
                   reason = "test"; confidence = 0.9 } in
  let config = to_recall_config decision in
  assert config.enabled;
  assert (config.max_tokens = 1000)  (* Half of default 2000 *)

let test_to_recall_config_full () =
  let decision = { depth = Full; intent = Knowledge_query;
                   reason = "test"; confidence = 0.9 } in
  let config = to_recall_config decision in
  assert config.enabled;
  assert (config.max_tokens = 2000)

(* ---------- JSON Serialization ---------- *)

let test_decision_to_json () =
  let d = { depth = Full; intent = Knowledge_query;
            reason = "needs search"; confidence = 0.85 } in
  let json = decision_to_json d in
  let open Yojson.Safe.Util in
  assert (json |> member "depth" |> to_string = "full");
  assert (json |> member "confidence" |> to_float > 0.8);
  assert (String.length (json |> member "reason" |> to_string) > 0)

let test_decision_to_json_skip () =
  let d = { depth = Skip; intent = Conversational;
            reason = "greeting"; confidence = 0.95 } in
  let json = decision_to_json d in
  let open Yojson.Safe.Util in
  assert (json |> member "depth" |> to_string = "skip")

(* ---------- MODEL Intent Classification Unit Tests ---------- *)

let test_parse_intent_conversational () =
  assert (parse_intent_response "Conversational" = Some (Conversational, 0.90));
  assert (parse_intent_response "conversational" = Some (Conversational, 0.90));
  assert (parse_intent_response "  Conversational  " = Some (Conversational, 0.90))

let test_parse_intent_task_command () =
  assert (parse_intent_response "Task_command" = Some (Task_command, 0.90));
  assert (parse_intent_response "task command" = Some (Task_command, 0.90));
  assert (parse_intent_response "TASK_COMMAND" = Some (Task_command, 0.90))

let test_parse_intent_status_check () =
  assert (parse_intent_response "Status_check" = Some (Status_check, 0.90));
  assert (parse_intent_response "status check" = Some (Status_check, 0.90))

let test_parse_intent_knowledge () =
  assert (parse_intent_response "Knowledge_query" = Some (Knowledge_query, 0.85));
  assert (parse_intent_response "knowledge query" = Some (Knowledge_query, 0.85))

let test_parse_intent_coordination () =
  assert (parse_intent_response "Coordination" = Some (Coordination, 0.85));
  assert (parse_intent_response "coordination" = Some (Coordination, 0.85))

let test_parse_intent_with_explanation () =
  (* MODEL might add extra text — parser should still extract the intent *)
  assert (parse_intent_response "The intent is Conversational because it is a greeting."
    = Some (Conversational, 0.90));
  assert (parse_intent_response "I classify this as Knowledge_query."
    = Some (Knowledge_query, 0.85))

let test_parse_intent_does_not_match_prompt_echo () =
  assert
    (parse_intent_response
       "Conversational: greetings, thanks, acknowledgements, small talk, yes/no"
     = Some (Conversational, 0.90));
  assert
    (parse_intent_response
       "Knowledge_query: needs domain knowledge, how-to, debugging, explanations, search"
     = Some (Knowledge_query, 0.85));
  assert
    (parse_intent_response
       "Categories: greetings, thanks, acknowledgements, small talk"
     = None)

let test_parse_intent_garbage () =
  assert (parse_intent_response "" = None);
  assert (parse_intent_response "no valid intent here" = None);
  assert (parse_intent_response "42" = None)

let test_build_intent_prompt () =
  let prompt = build_intent_prompt "최근 이슈 보여줘" in
  (* Should contain the query *)
  assert (String.length prompt > 50);
  let has_sub pat s =
    let p_len = String.length pat in
    let s_len = String.length s in
    let rec check i =
      if i > s_len - p_len then false
      else if String.sub s i p_len = pat then true
      else check (i + 1)
    in check 0
  in
  assert (has_sub "이슈" prompt);
  (* Should contain all 5 category names *)
  assert (has_sub "Conversational" prompt);
  assert (has_sub "Task_command" prompt);
  assert (has_sub "Status_check" prompt);
  assert (has_sub "Knowledge_query" prompt);
  assert (has_sub "Coordination" prompt)

let test_router_mode_dispatch () =
  let mode = get_router_mode () in
  match Sys.getenv_opt "MASC_CONTEXT_ROUTER_MODE" with
  | Some "model" -> assert (mode = Model_mode)
  | Some "hybrid" -> assert (mode = Hybrid_mode)
  | _ -> assert (mode = Heuristic)

let test_heuristic_direct () =
  (* classify_intent_heuristic should behave identically to old classify_intent *)
  let (intent, conf) = classify_intent_heuristic "masc_claim task-001" in
  assert (intent = Task_command);
  assert (conf > 0.9);
  let (intent2, _) = classify_intent_heuristic "hello" in
  assert (intent2 = Conversational)

let test_heuristic_korean_gap () =
  (* This is the known gap: "이슈 보여줘" has no matching heuristic pattern,
     so it falls through to low-confidence Coordination *)
  let (intent, conf) = classify_intent_heuristic "최근 이슈 보여줘" in
  (* No status_patterns match "이슈" → falls to short ambiguous *)
  assert (intent = Coordination);
  assert (conf < 0.6)

(* ---------- Test Runner ---------- *)

let () =
  let tests = [
    ("conversational_intent", test_conversational_intent);
    ("command_intent", test_command_intent);
    ("status_intent", test_status_intent);
    ("knowledge_intent", test_knowledge_intent);
    ("coordination_intent", test_coordination_intent);
    ("short_query", test_short_query);
    ("very_short_query", test_very_short_query);
    ("route_skip", test_route_skip);
    ("route_skip_command", test_route_skip_command);
    ("route_light", test_route_light);
    ("route_full", test_route_full);
    ("route_knowledge_with_broadcasts", test_route_knowledge_with_broadcasts);
    ("route_knowledge_without_broadcasts", test_route_knowledge_without_broadcasts);
    ("broadcasts_cover_positive", test_broadcasts_cover_query_positive);
    ("broadcasts_cover_negative", test_broadcasts_cover_query_negative);
    ("broadcasts_cover_empty", test_broadcasts_cover_query_empty);
    ("broadcasts_cover_short_query", test_broadcasts_cover_short_query);
    ("depth_to_sources_skip", test_depth_to_sources_skip);
    ("depth_to_sources_light", test_depth_to_sources_light);
    ("depth_to_sources_full", test_depth_to_sources_full);
    ("to_recall_config_skip", test_to_recall_config_skip);
    ("to_recall_config_light", test_to_recall_config_light);
    ("to_recall_config_full", test_to_recall_config_full);
    ("decision_to_json", test_decision_to_json);
    ("decision_to_json_skip", test_decision_to_json_skip);
    (* MODEL intent classification unit tests *)
    ("parse_intent_conversational", test_parse_intent_conversational);
    ("parse_intent_task_command", test_parse_intent_task_command);
    ("parse_intent_status_check", test_parse_intent_status_check);
    ("parse_intent_knowledge", test_parse_intent_knowledge);
    ("parse_intent_coordination", test_parse_intent_coordination);
    ("parse_intent_with_explanation", test_parse_intent_with_explanation);
    ("parse_intent_does_not_match_prompt_echo", test_parse_intent_does_not_match_prompt_echo);
    ("parse_intent_garbage", test_parse_intent_garbage);
    ("build_intent_prompt", test_build_intent_prompt);
    ("router_mode_dispatch", test_router_mode_dispatch);
    ("heuristic_direct", test_heuristic_direct);
    ("heuristic_korean_gap", test_heuristic_korean_gap);
  ] in
  let passed = ref 0 in
  let failed = ref 0 in
  List.iter (fun (name, test) ->
    try
      test ();
      incr passed;
      Printf.printf "  \027[32m[OK]\027[0m  %s\n" name
    with e ->
      incr failed;
      Printf.printf "  \027[31m[FAIL]\027[0m %s: %s\n" name (Printexc.to_string e)
  ) tests;
  Printf.printf "\n%d passed, %d failed (%d total)\n" !passed !failed (!passed + !failed);
  if !failed > 0 then exit 1
