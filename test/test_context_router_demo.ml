(** Context Router Demo — Compare heuristic vs MODEL intent classification.
    Run with: MASC_CONTEXT_ROUTER_MODE=model dune exec test/test_context_router_demo.exe *)

open Masc_mcp.Context_router

(* Queries that expose the gap between heuristic and MODEL classification.
   These are semantically clear to a human/MODEL but miss heuristic patterns. *)
let test_queries = [
  (* Korean queries not covered by keyword patterns *)
  ("최근 이슈 보여줘", "Status_check — asking to show recent issues");
  ("이 코드 리뷰해줘", "Coordination — requesting code review");
  ("뭐가 잘못됐는지 알아봐", "Knowledge_query — asking to investigate a problem");
  ("ㅇㅋ 진행해", "Conversational — simple acknowledgement");
  ("배포 상태 어때?", "Status_check — asking about deployment status");

  (* English queries that fall through heuristic patterns *)
  ("investigate the performance regression", "Knowledge_query — debugging");
  ("delegate this to the security team", "Coordination — delegation");
  ("what went wrong with the last deploy", "Knowledge_query — postmortem");
  ("are we done yet", "Status_check — progress check");
  ("nice work", "Conversational — praise");

  (* Queries that heuristic classifies correctly (baseline) *)
  ("masc_status", "Status_check — direct MASC command");
  ("hello", "Conversational — greeting");
  ("how to fix authentication", "Knowledge_query — has 'how to' pattern");
]

let intent_to_string = function
  | Conversational -> "Conversational"
  | Task_command -> "Task_command"
  | Status_check -> "Status_check"
  | Knowledge_query -> "Knowledge_query"
  | Coordination -> "Coordination"

let () =
  let mode = get_router_mode () in
  let mode_str = match mode with
    | Heuristic -> "heuristic"
    | Model_mode -> "model"
    | Hybrid_mode -> "hybrid"
  in
  Printf.printf "Mode: %s\n\n" mode_str;

  Printf.printf "%-40s  %-18s  %-18s  %s\n"
    "Query" "Heuristic" "Current Mode" "Expected";
  Printf.printf "%s\n" (String.make 110 '-');

  List.iter (fun (query, expected) ->
    let (h_intent, h_conf) = classify_intent_heuristic query in
    let (c_intent, c_conf) = classify_intent query in
    let match_marker =
      if h_intent <> c_intent then " <-- DIFF"
      else ""
    in
    Printf.printf "%-40s  %-14s %.2f  %-14s %.2f  %s%s\n"
      (if String.length query > 38
       then String.sub query 0 35 ^ "..."
       else query)
      (intent_to_string h_intent) h_conf
      (intent_to_string c_intent) c_conf
      expected match_marker
  ) test_queries
