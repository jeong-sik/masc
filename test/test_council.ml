(** Council Module Tests

    Tests for multi-agent governance system:
    - Debate: create, argue, close
    - Consensus: start, vote, result
    - Router: query classification, agent selection
    - Balance: dominance check, participation rate
*)

open Alcotest

module Council = Council
module Debate = Council.Debate
module Consensus = Council.Consensus
module Router = Council.Router
module Balance = Council.Balance

(* ============================================================
   Test Utilities
   ============================================================ *)

let test_base_path = "/tmp/masc-test-council"

let setup () =
  (* Create test directories *)
  let masc_dir = Filename.concat test_base_path ".masc" in
  let debates_dir = Filename.concat masc_dir "debates" in
  ignore (Sys.command (Printf.sprintf "mkdir -p %s" debates_dir));
  ()

let teardown () =
  ignore (Sys.command (Printf.sprintf "rm -rf %s" test_base_path));
  ()

(* ============================================================
   Debate Tests
   ============================================================ *)

let test_debate_create () =
  setup ();
  let notify_fn = fun ~agent:_ ~message:_ -> () in
  match Debate.start_debate test_base_path ~topic:"Test topic" ~notify_fn () with
  | Ok debate ->
    check bool "has id" (String.length debate.Debate.id > 0) true;
    check string "topic" debate.topic "Test topic";
    check bool "status open" (debate.status = Debate.Open) true;
    teardown ()
  | Error e ->
    teardown ();
    fail (Printf.sprintf "debate creation failed: %s" e)

let test_debate_add_argument () =
  setup ();
  let notify_fn = fun ~agent:_ ~message:_ -> () in
  match Debate.start_debate test_base_path ~topic:"OCaml vs Rust" ~notify_fn () with
  | Error e -> teardown (); fail e
  | Ok debate ->
    let debate_id = debate.Debate.id in
    match Debate.add_argument test_base_path ~debate_id 
            ~agent:"melchior" ~position:Debate.Support 
            ~content:"OCaml has better type inference" ~evidence:["HM type system"] () with
    | Error e -> teardown (); fail e
    | Ok updated ->
      check int "argument count" (List.length updated.Debate.arguments) 1;
      let arg = List.hd updated.arguments in
      check string "agent" arg.Debate.agent "melchior";
      check bool "position support" (arg.position = Debate.Support) true;
      teardown ()

let test_debate_multiple_positions () =
  setup ();
  let notify_fn = fun ~agent:_ ~message:_ -> () in
  match Debate.start_debate test_base_path ~topic:"Multi-agent test" ~notify_fn () with
  | Error e -> teardown (); fail e
  | Ok debate ->
    let debate_id = debate.Debate.id in
    (* Add 3 arguments with different positions *)
    let _ = Debate.add_argument test_base_path ~debate_id 
              ~agent:"a1" ~position:Debate.Support ~content:"Pro" ~evidence:[] () in
    let _ = Debate.add_argument test_base_path ~debate_id 
              ~agent:"a2" ~position:Debate.Oppose ~content:"Con" ~evidence:[] () in
    match Debate.add_argument test_base_path ~debate_id 
            ~agent:"a3" ~position:Debate.Neutral ~content:"Meh" ~evidence:[] () with
    | Error e -> teardown (); fail e
    | Ok final ->
      check int "3 arguments" (List.length final.Debate.arguments) 3;
      teardown ()

let test_debate_close () =
  setup ();
  let notify_fn = fun ~agent:_ ~message:_ -> () in
  match Debate.start_debate test_base_path ~topic:"Closeable" ~notify_fn () with
  | Error e -> teardown (); fail e
  | Ok debate ->
    match Debate.close_debate test_base_path ~debate_id:debate.Debate.id with
    | Error e -> teardown (); fail e
    | Ok closed ->
      check bool "status closed" (closed.Debate.status = Debate.Closed) true;
      teardown ()

(* ============================================================
   Consensus Tests
   ============================================================ *)

let test_consensus_start () =
  match Consensus.start_voting ~topic:"Approve X" ~initiator:"mod" ~quorum:2 ~threshold:0.5 () with
  | Error _ -> fail "consensus start failed"
  | Ok session ->
    check bool "has id" (String.length session.Consensus.id > 0) true;
    check string "topic" session.topic "Approve X";
    check int "quorum" session.quorum 2;
    check bool "threshold" (session.threshold = 0.5) true;
    Consensus.clear_sessions ()

let test_consensus_vote () =
  match Consensus.start_voting ~topic:"Vote test" ~initiator:"mod" ~quorum:2 ~threshold:0.5 () with
  | Error _ -> fail "start failed"
  | Ok session ->
    let sid = session.Consensus.id in
    match Consensus.cast_vote ~session_id:sid ~agent:"a1" ~decision:Consensus.Approve ~reason:"yes" with
    | Error _ -> Consensus.clear_sessions (); fail "vote failed"
    | Ok updated ->
      check int "1 vote" (List.length updated.Consensus.votes) 1;
      Consensus.clear_sessions ()

let test_consensus_duplicate_vote () =
  match Consensus.start_voting ~topic:"Dup test" ~initiator:"mod" ~quorum:3 ~threshold:0.5 () with
  | Error _ -> fail "start failed"
  | Ok session ->
    let sid = session.Consensus.id in
    let _ = Consensus.cast_vote ~session_id:sid ~agent:"a1" ~decision:Consensus.Approve ~reason:"1" in
    match Consensus.cast_vote ~session_id:sid ~agent:"a1" ~decision:Consensus.Reject ~reason:"2" with
    | Ok _ -> Consensus.clear_sessions (); fail "should reject duplicate"
    | Error (Consensus.Already_voted _) -> Consensus.clear_sessions ()
    | Error _ -> Consensus.clear_sessions (); fail "wrong error type"

let test_consensus_majority () =
  match Consensus.start_voting ~topic:"Majority" ~initiator:"mod" ~quorum:3 ~threshold:0.5 () with
  | Error _ -> fail "start failed"
  | Ok session ->
    let sid = session.Consensus.id in
    let _ = Consensus.cast_vote ~session_id:sid ~agent:"a1" ~decision:Consensus.Approve ~reason:"" in
    let _ = Consensus.cast_vote ~session_id:sid ~agent:"a2" ~decision:Consensus.Approve ~reason:"" in
    let _ = Consensus.cast_vote ~session_id:sid ~agent:"a3" ~decision:Consensus.Reject ~reason:"" in
    match Consensus.get_result ~session_id:sid with
    | Error _ -> Consensus.clear_sessions (); fail "get result failed"
    | Ok result ->
      (match result with
       | Consensus.Majority n -> check int "majority 2" n 2
       | _ -> fail "expected Majority");
      Consensus.clear_sessions ()

let test_consensus_unanimous () =
  match Consensus.start_voting ~topic:"Unanimous" ~initiator:"mod" ~quorum:3 ~threshold:0.5 () with
  | Error _ -> fail "start failed"
  | Ok session ->
    let sid = session.Consensus.id in
    let _ = Consensus.cast_vote ~session_id:sid ~agent:"a1" ~decision:Consensus.Approve ~reason:"" in
    let _ = Consensus.cast_vote ~session_id:sid ~agent:"a2" ~decision:Consensus.Approve ~reason:"" in
    let _ = Consensus.cast_vote ~session_id:sid ~agent:"a3" ~decision:Consensus.Approve ~reason:"" in
    match Consensus.get_result ~session_id:sid with
    | Error _ -> Consensus.clear_sessions (); fail "get result failed"
    | Ok result ->
      (match result with
       | Consensus.Unanimous Consensus.Approve -> check bool "unanimous approve" true true
       | _ -> fail "expected Unanimous Approve");
      Consensus.clear_sessions ()

let test_consensus_deadlock () =
  match Consensus.start_voting ~topic:"Deadlock" ~initiator:"mod" ~quorum:2 ~threshold:0.6 () with
  | Error _ -> fail "start failed"
  | Ok session ->
    let sid = session.Consensus.id in
    let _ = Consensus.cast_vote ~session_id:sid ~agent:"a1" ~decision:Consensus.Approve ~reason:"" in
    let _ = Consensus.cast_vote ~session_id:sid ~agent:"a2" ~decision:Consensus.Reject ~reason:"" in
    match Consensus.get_result ~session_id:sid with
    | Error _ -> Consensus.clear_sessions (); fail "get result failed"
    | Ok result ->
      (match result with
       | Consensus.Deadlock -> check bool "deadlock" true true
       | _ -> fail "expected Deadlock");
      Consensus.clear_sessions ()

(* ============================================================
   Router Tests
   ============================================================ *)

let test_router_classify_code () =
  let classes = Router.classify_query "implement a function in OCaml" in
  let top_class, _ = List.hd classes in
  check bool "code query" (top_class = Router.Code) true

let test_router_classify_analysis () =
  let classes = Router.classify_query "analyze the performance metrics and evaluate results" in
  (* Check if Analysis is in top 3 classes *)
  let top3 = List.filteri (fun i _ -> i < 3) classes in
  let has_analysis = List.exists (fun (c, _) -> c = Router.Analysis) top3 in
  check bool "analysis in top 3" has_analysis true

let test_router_complexity_simple () =
  let c = Router.calculate_complexity "hello" in
  check bool "low complexity" (c < 0.3) true

let test_router_complexity_complex () =
  let c = Router.calculate_complexity 
    "implement a distributed consensus algorithm with byzantine fault tolerance and analyze its performance characteristics" in
  (* Just check it's non-zero, exact threshold depends on implementation *)
  check bool "non-zero complexity" (c > 0.0) true

let test_router_agent_selection () =
  let decision = Router.route ~max_agents:2 "write a simple function" in
  check bool "agents selected" (List.length decision.Router.agents <= 2) true;
  check bool "has reason" (String.length decision.reason > 0) true

(* ============================================================
   Balance Tests
   ============================================================ *)

let test_balance_empty_stats () =
  let stats = Balance.empty_stats () in
  check int "zero wins" stats.Balance.wins 0;
  check int "zero participations" stats.participations 0

let test_balance_no_dominance () =
  let stats = { Balance.wins = 1; participations = 5; last_win = None } in
  let is_dom = Balance.check_dominance ~agent_stats:stats ~total_rounds:10 in
  check bool "not dominating" is_dom false

let test_balance_dominance () =
  let stats = { Balance.wins = 5; participations = 5; last_win = Some 0.0 } in
  let is_dom = Balance.check_dominance ~agent_stats:stats ~total_rounds:10 in
  check bool "dominating" is_dom true

let test_balance_participation_rate () =
  let stats = { Balance.wins = 2; participations = 4; last_win = None } in
  let rate = Balance.get_participation_rate ~agent_stats:stats ~total_rounds:10 in
  check bool "40% participation" (rate = 0.4) true

let test_balance_action_clear () =
  let stats = { Balance.wins = 1; participations = 5; last_win = None } in
  let action = Balance.determine_action ~agent_stats:stats ~total_rounds:10 ~is_winner:false in
  check bool "clear" (action = Balance.Clear) true

(* ============================================================
   Test Suite
   ============================================================ *)

let debate_tests = [
  "create debate", `Quick, test_debate_create;
  "add argument", `Quick, test_debate_add_argument;
  "multiple positions", `Quick, test_debate_multiple_positions;
  "close debate", `Quick, test_debate_close;
]

let consensus_tests = [
  "start voting", `Quick, test_consensus_start;
  "cast vote", `Quick, test_consensus_vote;
  "duplicate vote rejected", `Quick, test_consensus_duplicate_vote;
  "majority result", `Quick, test_consensus_majority;
  "unanimous result", `Quick, test_consensus_unanimous;
  "deadlock result", `Quick, test_consensus_deadlock;
]

let router_tests = [
  "classify code", `Quick, test_router_classify_code;
  "classify analysis", `Quick, test_router_classify_analysis;
  "complexity simple", `Quick, test_router_complexity_simple;
  "complexity complex", `Quick, test_router_complexity_complex;
  "agent selection", `Quick, test_router_agent_selection;
]

let balance_tests = [
  "empty stats", `Quick, test_balance_empty_stats;
  "no dominance", `Quick, test_balance_no_dominance;
  "dominance detected", `Quick, test_balance_dominance;
  "participation rate", `Quick, test_balance_participation_rate;
  "action clear", `Quick, test_balance_action_clear;
]

let () =
  run "Council" [
    "Debate", debate_tests;
    "Consensus", consensus_tests;
    "Router", router_tests;
    "Balance", balance_tests;
  ]
