(** Coverage tests for memory_stream (pure scoring functions) and agent_reputation (JSON roundtrip).
    Only tests pure functions that do not require filesystem or Eio. *)

open Alcotest
open Masc_mcp

(* ============================================================
   1. Memory_stream — recency_score
   ============================================================ *)

let make_entry ?(importance=5) ?(content="test content") ?(timestamp=1000.0) () : Memory_stream.memory_entry =
  { id = "test-001"; agent_name = "tester"; content; timestamp;
    importance; entry_type = Observation "obs";
    access_count = 0; last_accessed = timestamp; links = [] }

let test_recency_recent () =
  let entry = make_entry ~timestamp:1000.0 () in
  let s = Memory_stream.recency_score ~now:1000.0 entry in
  check (float 0.01) "same time" 1.0 s

let test_recency_old () =
  (* 24 hours ago *)
  let entry = make_entry ~timestamp:0.0 () in
  let s = Memory_stream.recency_score ~now:86400.0 entry in
  check bool "decayed" true (s < 1.0 && s > 0.0)

(* ============================================================
   2. Memory_stream — importance_score
   ============================================================ *)

let test_importance_min () =
  let entry = make_entry ~importance:0 () in
  let s = Memory_stream.importance_score entry in
  check (float 0.01) "min" 0.0 s

let test_importance_max () =
  let entry = make_entry ~importance:10 () in
  let s = Memory_stream.importance_score entry in
  check (float 0.01) "max" 1.0 s

let test_importance_mid () =
  let entry = make_entry ~importance:5 () in
  let s = Memory_stream.importance_score entry in
  check (float 0.01) "mid" 0.5 s

(* ============================================================
   3. Memory_stream — keyword_relevance
   ============================================================ *)

let test_relevance_exact_match () =
  let entry = make_entry ~content:"hello world test" () in
  let s = Memory_stream.keyword_relevance ~query:"hello world" entry in
  check (float 0.01) "full match" 1.0 s

let test_relevance_partial_match () =
  let entry = make_entry ~content:"hello beautiful world" () in
  let s = Memory_stream.keyword_relevance ~query:"hello test" entry in
  (* 1 out of 2 words match *)
  check (float 0.01) "partial" 0.5 s

let test_relevance_no_match () =
  let entry = make_entry ~content:"alpha beta gamma" () in
  let s = Memory_stream.keyword_relevance ~query:"delta epsilon" entry in
  check (float 0.01) "no match" 0.0 s

let test_relevance_empty_query () =
  let entry = make_entry ~content:"hello world" () in
  let s = Memory_stream.keyword_relevance ~query:"" entry in
  check (float 0.01) "empty query" 0.5 s

let test_relevance_single_char_words_filtered () =
  let entry = make_entry ~content:"a b c real word" () in
  let s = Memory_stream.keyword_relevance ~query:"a b real" entry in
  (* Only "real" has length > 1, 1 match out of 1 *)
  check (float 0.01) "filtered" 1.0 s

(* ============================================================
   4. Memory_stream — score_entry
   ============================================================ *)

let test_score_entry_default_weights () =
  let entry = make_entry ~importance:10 ~content:"query word here" ~timestamp:100.0 () in
  let s = Memory_stream.score_entry ~now:100.0 ~query:"query word here" entry in
  (* recency=1.0, importance=1.0, relevance=1.0, all weights=1.0 -> 3.0 *)
  check (float 0.1) "perfect score" 3.0 s

let test_score_entry_custom_weights () =
  let weights : Memory_stream.scoring_weights = { alpha = 2.0; beta = 0.5; gamma = 0.0 } in
  let entry = make_entry ~importance:10 ~timestamp:100.0 () in
  let s = Memory_stream.score_entry ~weights ~now:100.0 ~query:"nomatch" entry in
  (* recency=1.0*2.0=2.0, importance=1.0*0.5=0.5, relevance=0.0*0.0=0.0 -> 2.5 *)
  check (float 0.1) "custom weights" 2.5 s

(* ============================================================
   5. Memory_stream — JSON roundtrip
   ============================================================ *)

let test_memory_type_json_roundtrip () =
  let types = [
    Memory_stream.Observation "obs";
    Memory_stream.Action "act";
    Memory_stream.Reflection "ref";
    Memory_stream.Plan "plan";
  ] in
  List.iter (fun mt ->
    let entry = { (make_entry ()) with entry_type = mt } in
    let json = Memory_stream.entry_to_json entry in
    match Memory_stream.entry_of_json json with
    | Some e -> check string "content" entry.content e.content
    | None -> fail "roundtrip failed"
  ) types

let test_entry_to_json_fields () =
  let entry = { (make_entry ()) with links = ["link1"; "link2"]; access_count = 5 } in
  let json = Memory_stream.entry_to_json entry in
  (* Verify it's valid JSON *)
  let s = Yojson.Safe.to_string json in
  check bool "json string" true (String.length s > 10)

let test_entry_of_json_malformed () =
  let json = `Assoc [("bad", `String "data")] in
  check (option reject) "malformed" None (Memory_stream.entry_of_json json)

let test_entry_of_json_missing_phase2 () =
  (* Old-format JSON without access_count/last_accessed/links *)
  let json = `Assoc [
    ("id", `String "x"); ("agent_name", `String "a");
    ("content", `String "c"); ("timestamp", `Float 1.0);
    ("importance", `Int 5);
    ("entry_type", `Assoc [("type", `String "observation"); ("detail", `String "d")]);
  ] in
  match Memory_stream.entry_of_json json with
  | Some e ->
    check int "access_count default" 0 e.access_count;
    check (float 0.01) "last_accessed default" 1.0 e.last_accessed;
    check int "links default" 0 (List.length e.links)
  | None -> fail "should parse old format"

let test_memory_type_unknown () =
  let json = `Assoc [
    ("id", `String "x"); ("agent_name", `String "a");
    ("content", `String "c"); ("timestamp", `Float 1.0);
    ("importance", `Int 5);
    ("entry_type", `Assoc [("type", `String "unknown_type"); ("detail", `String "d")]);
  ] in
  match Memory_stream.entry_of_json json with
  | Some e ->
    (match e.entry_type with Observation _ -> () | _ -> fail "should default to Observation")
  | None -> fail "should parse"

(* ============================================================
   6. Memory_stream — default_weights, max_entries
   ============================================================ *)

let test_default_weights () =
  let w = Memory_stream.default_weights in
  check (float 0.01) "alpha" 1.0 w.alpha;
  check (float 0.01) "beta" 1.0 w.beta;
  check (float 0.01) "gamma" 1.0 w.gamma

let test_max_entries () =
  check int "max" 1000 Memory_stream.max_entries

(* ============================================================
   7. Agent_reputation — compute_overall_score
   ============================================================ *)

let test_overall_score_perfect () =
  let s = Agent_reputation.compute_overall_score
      ~completion_rate:1.0 ~response_rate:1.0
      ~board_posts:10 ~board_comments:10 ~debates_participated:10 in
  check (float 0.01) "perfect" 1.0 s

let test_overall_score_zero () =
  let s = Agent_reputation.compute_overall_score
      ~completion_rate:0.0 ~response_rate:0.0
      ~board_posts:0 ~board_comments:0 ~debates_participated:0 in
  check (float 0.01) "zero" 0.0 s

let test_overall_score_weights () =
  (* Only completion_rate=1.0, rest zero -> 0.4 *)
  let s = Agent_reputation.compute_overall_score
      ~completion_rate:1.0 ~response_rate:0.0
      ~board_posts:0 ~board_comments:0 ~debates_participated:0 in
  check (float 0.01) "completion only" 0.4 s

let test_overall_score_capped () =
  (* Board > 20 actions should still cap at 1.0 for that component *)
  let s = Agent_reputation.compute_overall_score
      ~completion_rate:0.0 ~response_rate:0.0
      ~board_posts:50 ~board_comments:50 ~debates_participated:0 in
  check (float 0.01) "board capped" 0.2 s

(* ============================================================
   8. Agent_reputation — JSON roundtrip
   ============================================================ *)

let test_reputation_json_roundtrip () =
  let r : Agent_reputation.agent_reputation = {
    agent_name = "test_agent";
    tasks_completed = 10; tasks_claimed = 15;
    completion_rate = 0.67;
    mentions_received = 20; mentions_responded = 15;
    response_rate = 0.75;
    board_posts = 5; board_comments = 12;
    debates_participated = 3;
    overall_score = 0.85;
  } in
  let json = Agent_reputation.reputation_to_json r in
  match Agent_reputation.reputation_of_json json with
  | Some r2 ->
    check string "name" "test_agent" r2.agent_name;
    check int "tasks_completed" 10 r2.tasks_completed;
    check int "tasks_claimed" 15 r2.tasks_claimed;
    check (float 0.01) "overall" 0.85 r2.overall_score
  | None -> fail "roundtrip failed"

let test_reputation_of_json_empty_name () =
  let json = `Assoc [("agent_name", `String "")] in
  check (option reject) "empty name" None (Agent_reputation.reputation_of_json json)

let test_reputation_of_json_missing_name () =
  let json = `Assoc [("tasks_completed", `Int 5)] in
  check (option reject) "missing name" None (Agent_reputation.reputation_of_json json)

let test_reputation_of_json_defaults () =
  let json = `Assoc [("agent_name", `String "agent")] in
  match Agent_reputation.reputation_of_json json with
  | Some r ->
    check int "tasks default" 0 r.tasks_completed;
    check (float 0.01) "rate default" 0.0 r.completion_rate
  | None -> fail "should parse with defaults"

let test_default_reputation () =
  let r = Agent_reputation.default_reputation ~agent_name:"test" in
  check string "name" "test" r.agent_name;
  check int "tasks" 0 r.tasks_completed;
  check (float 0.01) "score" 0.0 r.overall_score

(* ============================================================
   Runner
   ============================================================ *)

let () =
  run "memory_reputation_coverage" [
    "recency_score", [
      test_case "recent" `Quick test_recency_recent;
      test_case "old" `Quick test_recency_old;
    ];
    "importance_score", [
      test_case "min" `Quick test_importance_min;
      test_case "max" `Quick test_importance_max;
      test_case "mid" `Quick test_importance_mid;
    ];
    "keyword_relevance", [
      test_case "exact match" `Quick test_relevance_exact_match;
      test_case "partial" `Quick test_relevance_partial_match;
      test_case "no match" `Quick test_relevance_no_match;
      test_case "empty query" `Quick test_relevance_empty_query;
      test_case "short words filtered" `Quick test_relevance_single_char_words_filtered;
    ];
    "score_entry", [
      test_case "default weights" `Quick test_score_entry_default_weights;
      test_case "custom weights" `Quick test_score_entry_custom_weights;
    ];
    "JSON roundtrip", [
      test_case "memory_type" `Quick test_memory_type_json_roundtrip;
      test_case "entry fields" `Quick test_entry_to_json_fields;
      test_case "malformed" `Quick test_entry_of_json_malformed;
      test_case "missing phase2" `Quick test_entry_of_json_missing_phase2;
      test_case "unknown type" `Quick test_memory_type_unknown;
    ];
    "defaults", [
      test_case "default_weights" `Quick test_default_weights;
      test_case "max_entries" `Quick test_max_entries;
    ];
    "compute_overall_score", [
      test_case "perfect" `Quick test_overall_score_perfect;
      test_case "zero" `Quick test_overall_score_zero;
      test_case "weights" `Quick test_overall_score_weights;
      test_case "capped" `Quick test_overall_score_capped;
    ];
    "reputation JSON", [
      test_case "roundtrip" `Quick test_reputation_json_roundtrip;
      test_case "empty name" `Quick test_reputation_of_json_empty_name;
      test_case "missing name" `Quick test_reputation_of_json_missing_name;
      test_case "defaults" `Quick test_reputation_of_json_defaults;
      test_case "default_reputation" `Quick test_default_reputation;
    ];
  ]
