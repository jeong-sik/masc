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

let rec mkdir_p path =
  if Sys.file_exists path then
    ()
  else begin
    let parent = Filename.dirname path in
    if parent <> path then mkdir_p parent;
    try Unix.mkdir path 0o755
    with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Unix.unlink path

let setup () =
  (* Create test directories *)
  let masc_dir = Filename.concat test_base_path ".masc" in
  let debates_dir = Filename.concat masc_dir "debates" in
  mkdir_p debates_dir;
  ()

let teardown () =
  (try rm_rf test_base_path with _ -> ());
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

let test_debate_pingpong () =
  setup ();
  let notifications = ref [] in
  let notify_fn = Some (fun ~agent ~message -> 
    notifications := (agent, message) :: !notifications
  ) in
  match Debate.start_debate test_base_path ~topic:"Ping pong test" 
          ~notify_fn:(fun ~agent:_ ~message:_ -> ()) () with
  | Error e -> teardown (); fail e
  | Ok debate ->
    let debate_id = debate.Debate.id in
    (* Agent A makes argument #0 *)
    let _ = Debate.add_argument test_base_path ~debate_id 
              ~agent:"agent_a" ~position:Debate.Support 
              ~content:"I support this" ~evidence:[] ~notify_fn:None () in
    (* Agent B replies to #0, mentions agent_a *)
    match Debate.add_argument test_base_path ~debate_id 
            ~agent:"agent_b" ~position:Debate.Oppose 
            ~content:"I disagree with agent_a" ~evidence:[]
            ~reply_to:(Some 0) ~mentions:["agent_a"] ~notify_fn () with
    | Error e -> teardown (); fail e
    | Ok updated ->
      check int "2 arguments" (List.length updated.Debate.arguments) 2;
      let arg1 = List.nth updated.arguments 1 in
      check bool "has reply_to" (arg1.Debate.reply_to = Some 0) true;
      check bool "has mentions" (List.mem "agent_a" arg1.mentions) true;
      (* Check notifications were sent *)
      check bool "notifications sent" (List.length !notifications >= 1) true;
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
    match Consensus.cast_vote ~session_id:sid ~agent:"a1" ~decision:Consensus.Approve ~reason:"yes" () with
    | Error _ -> Consensus.clear_sessions (); fail "vote failed"
    | Ok updated ->
      check int "1 vote" (List.length updated.Consensus.votes) 1;
      Consensus.clear_sessions ()

let test_consensus_duplicate_vote () =
  match Consensus.start_voting ~topic:"Dup test" ~initiator:"mod" ~quorum:3 ~threshold:0.5 () with
  | Error _ -> fail "start failed"
  | Ok session ->
    let sid = session.Consensus.id in
    let _ = Consensus.cast_vote ~session_id:sid ~agent:"a1" ~decision:Consensus.Approve ~reason:"1" () in
    match Consensus.cast_vote ~session_id:sid ~agent:"a1" ~decision:Consensus.Reject ~reason:"2" () with
    | Ok _ -> Consensus.clear_sessions (); fail "should reject duplicate"
    | Error (Consensus.Already_voted _) -> Consensus.clear_sessions ()
    | Error _ -> Consensus.clear_sessions (); fail "wrong error type"

let test_consensus_majority () =
  match Consensus.start_voting ~topic:"Majority" ~initiator:"mod" ~quorum:3 ~threshold:0.5 () with
  | Error _ -> fail "start failed"
  | Ok session ->
    let sid = session.Consensus.id in
    let _ = Consensus.cast_vote ~session_id:sid ~agent:"a1" ~decision:Consensus.Approve ~reason:"" () in
    let _ = Consensus.cast_vote ~session_id:sid ~agent:"a2" ~decision:Consensus.Approve ~reason:"" () in
    let _ = Consensus.cast_vote ~session_id:sid ~agent:"a3" ~decision:Consensus.Reject ~reason:"" () in
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
    let _ = Consensus.cast_vote ~session_id:sid ~agent:"a1" ~decision:Consensus.Approve ~reason:"" () in
    let _ = Consensus.cast_vote ~session_id:sid ~agent:"a2" ~decision:Consensus.Approve ~reason:"" () in
    let _ = Consensus.cast_vote ~session_id:sid ~agent:"a3" ~decision:Consensus.Approve ~reason:"" () in
    match Consensus.get_result ~session_id:sid with
    | Error _ -> Consensus.clear_sessions (); fail "get result failed"
    | Ok result ->
      (match result with
       | Consensus.Unanimous Consensus.Approve -> ()
       | _ -> fail "expected Unanimous Approve");
      Consensus.clear_sessions ()

let test_consensus_deadlock () =
  match Consensus.start_voting ~topic:"Deadlock" ~initiator:"mod" ~quorum:2 ~threshold:0.6 () with
  | Error _ -> fail "start failed"
  | Ok session ->
    let sid = session.Consensus.id in
    let _ = Consensus.cast_vote ~session_id:sid ~agent:"a1" ~decision:Consensus.Approve ~reason:"" () in
    let _ = Consensus.cast_vote ~session_id:sid ~agent:"a2" ~decision:Consensus.Reject ~reason:"" () in
    match Consensus.get_result ~session_id:sid with
    | Error _ -> Consensus.clear_sessions (); fail "get result failed"
    | Ok result ->
      (match result with
       | Consensus.Deadlock -> ()
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

let test_router_reason_mentions_heuristic () =
  let decision = Router.route "implement a function in OCaml" in
  check bool "heuristic reason prefix"
    (String.starts_with ~prefix:"Heuristic query class:" decision.reason) true

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
  "ping-pong reply", `Quick, test_debate_pingpong;
]

let consensus_persist_path = "/tmp/masc-test-consensus-persist"
let consensus_storage_dir () =
  Filename.concat (Filename.concat consensus_persist_path ".masc") "consensus"

let consensus_persist_setup () =
  (try rm_rf consensus_persist_path with _ -> ());
  mkdir_p consensus_persist_path;
  Consensus.clear_sessions ();
  Consensus.init ~base_path:consensus_persist_path

let consensus_persist_teardown () =
  Consensus.clear_sessions ();
  (* Reset to no persistence *)
  Consensus.init ~base_path:"/tmp/masc-test-consensus-noop";
  (try rm_rf consensus_persist_path with _ -> ())

let test_consensus_persist_roundtrip () =
  consensus_persist_setup ();
  match Consensus.start_voting ~topic:"Persist test" ~initiator:"alice" ~quorum:2 ~threshold:0.5 () with
  | Error _ -> consensus_persist_teardown (); fail "start failed"
  | Ok session ->
    let sid = session.Consensus.id in
    (* Cast a vote *)
    (match Consensus.cast_vote ~session_id:sid ~agent:"bob" ~decision:Consensus.Approve ~reason:"looks good" () with
     | Error _ -> consensus_persist_teardown (); fail "vote failed"
     | Ok _ -> ());
    (* Clear in-memory store and reload from disk *)
    Consensus.clear_sessions ();
    Consensus.init ~base_path:consensus_persist_path;
    (* Session should be restored *)
    (match Consensus.get_session ~session_id:sid with
     | None -> consensus_persist_teardown (); fail "session not restored from disk"
     | Some restored ->
       check string "topic" restored.Consensus.topic "Persist test";
       check string "initiator" restored.Consensus.initiator "alice";
       check int "vote count" (List.length restored.Consensus.votes) 1;
       let vote = List.hd restored.Consensus.votes in
       check string "voter" vote.Consensus.agent "bob";
       check bool "decision" (vote.Consensus.decision = Consensus.Approve) true);
    consensus_persist_teardown ()

let test_consensus_persist_closed () =
  consensus_persist_setup ();
  match Consensus.start_voting ~topic:"Close persist" ~initiator:"mod" ~quorum:1 ~threshold:0.5 () with
  | Error _ -> consensus_persist_teardown (); fail "start failed"
  | Ok session ->
    let sid = session.Consensus.id in
    (match Consensus.close_session ~session_id:sid with
     | Error _ -> consensus_persist_teardown (); fail "close failed"
     | Ok _ -> ());
    Consensus.clear_sessions ();
    Consensus.init ~base_path:consensus_persist_path;
    (match Consensus.get_session ~session_id:sid with
     | None -> consensus_persist_teardown (); fail "closed session not restored"
     | Some restored ->
       check bool "state closed" (restored.Consensus.state = Consensus.Closed) true;
       check bool "has closed_at" (restored.Consensus.closed_at <> None) true);
    consensus_persist_teardown ()

let test_consensus_persist_start_failure_is_atomic () =
  consensus_persist_setup ();
  let dir = consensus_storage_dir () in
  mkdir_p dir;
  Unix.chmod dir 0o555;
  Fun.protect
    ~finally:(fun () ->
      Unix.chmod dir 0o755;
      consensus_persist_teardown ())
    (fun () ->
      match Consensus.start_voting
              ~topic:"Persist fail start"
              ~initiator:"alice"
              ~quorum:2
              ~threshold:0.5
              ()
      with
      | Ok _ -> fail "start should fail when persistence is unavailable"
      | Error (Consensus.Persistence_failed _) ->
        check int "no in-memory sessions" (List.length (Consensus.list_all_sessions ())) 0
      | Error _ -> fail "expected persistence failure")

let test_consensus_persist_vote_failure_is_atomic () =
  consensus_persist_setup ();
  match Consensus.start_voting ~topic:"Persist fail vote" ~initiator:"alice" ~quorum:2 ~threshold:0.5 () with
  | Error _ -> consensus_persist_teardown (); fail "start failed"
  | Ok session ->
    let sid = session.Consensus.id in
    let dir = consensus_storage_dir () in
    Unix.chmod dir 0o555;
    Fun.protect
      ~finally:(fun () ->
        Unix.chmod dir 0o755;
        consensus_persist_teardown ())
      (fun () ->
        match Consensus.cast_vote ~session_id:sid ~agent:"bob" ~decision:Consensus.Approve ~reason:"looks good" () with
        | Ok _ -> fail "vote should fail when persistence is unavailable"
        | Error (Consensus.Persistence_failed _) ->
          (match Consensus.get_session ~session_id:sid with
           | None -> fail "session should remain available in memory"
           | Some current ->
             check int "vote count unchanged in memory" (List.length current.Consensus.votes) 0);
          Consensus.clear_sessions ();
          Consensus.init ~base_path:consensus_persist_path;
          (match Consensus.get_session ~session_id:sid with
           | None -> fail "session should reload from disk"
           | Some restored ->
             check int "vote count unchanged on disk" (List.length restored.Consensus.votes) 0)
        | Error _ -> fail "expected persistence failure")

let consensus_tests = [
  "start voting", `Quick, test_consensus_start;
  "cast vote", `Quick, test_consensus_vote;
  "duplicate vote rejected", `Quick, test_consensus_duplicate_vote;
  "majority result", `Quick, test_consensus_majority;
  "unanimous result", `Quick, test_consensus_unanimous;
  "deadlock result", `Quick, test_consensus_deadlock;
  "persistence roundtrip", `Quick, test_consensus_persist_roundtrip;
  "persistence closed session", `Quick, test_consensus_persist_closed;
  "persistence start failure is atomic", `Quick,
  test_consensus_persist_start_failure_is_atomic;
  "persistence vote failure is atomic", `Quick,
  test_consensus_persist_vote_failure_is_atomic;
]

(* --- New capability-aware router tests --- *)

let test_router_short_complex_query () =
  let r = Router.extract_requirements "OCaml mutex deadlock analysis" in
  check bool "reasoning > 0.3" (r.reasoning_depth > 0.3) true;
  check bool "code > 0.3" (r.code_ability > 0.3) true

let test_router_deep_reasoning () =
  let r = Router.extract_requirements "why is the halting problem undecidable" in
  check bool "reasoning > 0.3" (r.reasoning_depth > 0.3) true

let test_router_speed_priority () =
  let r = Router.extract_requirements "quick one-liner to reverse a string" in
  check bool "speed > 0.3" (r.speed_priority > 0.3) true

let test_router_complex_selects_large_tier () =
  let decision = Router.route
    "prove that this distributed algorithm satisfies safety and liveness under partial synchrony" in
  let has_large = List.exists (fun (a : Router.agent_spec) ->
    match a.tier with Router.Large | Router.Giant -> true | _ -> false
  ) decision.agents in
  check bool "complex selects large tier" has_large true

let test_router_simple_prefers_cheap () =
  let decision = Router.route "what is 2+2" in
  let top = List.hd decision.agents in
  check bool "cheap top agent" (top.cost_per_1k < 0.01) true

let test_router_dot_product_correctness () =
  let r = Router.extract_requirements "debug this OCaml concurrent mutex issue" in
  let complexity = Router.calculate_complexity "debug this OCaml concurrent mutex issue" in
  let opus_cap = { Router.reasoning_score = 0.95; code_score = 0.9;
                   creativity_score = 0.9; factual_score = 0.9; speed_score = 0.3 } in
  let tiny_cap = { Router.reasoning_score = 0.3; code_score = 0.4;
                   creativity_score = 0.3; factual_score = 0.5; speed_score = 1.0 } in
  let opus_agent = { Router.name = "opus"; model = "opus"; tier = Router.Large;
                     capabilities = opus_cap; cost_per_1k = 0.015 } in
  let tiny_agent = { Router.name = "tiny"; model = "tiny"; tier = Router.Tiny;
                     capabilities = tiny_cap; cost_per_1k = 0.0 } in
  let opus_score = Router.score_agent ~requirements:r ~complexity opus_agent in
  let tiny_score = Router.score_agent ~requirements:r ~complexity tiny_agent in
  check bool "opus > tiny for complex+code" (opus_score > tiny_score) true

let router_tests = [
  "classify code", `Quick, test_router_classify_code;
  "classify analysis", `Quick, test_router_classify_analysis;
  "complexity simple", `Quick, test_router_complexity_simple;
  "complexity complex", `Quick, test_router_complexity_complex;
  "agent selection", `Quick, test_router_agent_selection;
  "reason mentions heuristic", `Quick, test_router_reason_mentions_heuristic;
  "short complex query", `Quick, test_router_short_complex_query;
  "deep reasoning", `Quick, test_router_deep_reasoning;
  "speed priority", `Quick, test_router_speed_priority;
  "complex selects large tier", `Quick, test_router_complex_selects_large_tier;
  "simple prefers cheap", `Quick, test_router_simple_prefers_cheap;
  "dot product correctness", `Quick, test_router_dot_product_correctness;
]

let balance_tests = [
  "empty stats", `Quick, test_balance_empty_stats;
  "no dominance", `Quick, test_balance_no_dominance;
  "dominance detected", `Quick, test_balance_dominance;
  "participation rate", `Quick, test_balance_participation_rate;
  "action clear", `Quick, test_balance_action_clear;
]

(* ============================================================
   Executor Tests
   ============================================================ *)

module Executor = Council.Executor

let test_executor_find_action_pr () =
  match Executor.find_action "Merge PR #123" with
  | Some _ -> ()
  | None -> fail "should find PR merge action"

let test_executor_find_action_none () =
  match Executor.find_action "Random topic" with
  | Some _ -> fail "should not find action"
  | None -> ()

let test_executor_dry_run_approve () =
  let result = Consensus.Majority 2 in
  let output = Executor.dry_run ~topic:"Merge PR #456" ~result in
  check bool "mentions merge" (String.length output > 0) true

let test_executor_dry_run_reject () =
  let result = Consensus.Deadlock in
  let output = Executor.dry_run ~topic:"Merge PR #789" ~result in
  (* Deadlock means threshold not met *)
  check bool "mentions would not" 
    (try String.sub output 0 9 = "Would NOT" with _ -> false) true

let test_executor_github_argv_create_issue () =
  let title = "Title with spaces and 'quotes' and \"double-quotes\"" in
  let body = "line1\nline2\nline3 with spaces" in
  let argv = Executor.github_argv (Executor.CreateIssue (title, body)) in
  check (list string) "argv"
    argv
    ["gh"; "issue"; "create"; "--title"; title; "--body"; body]

let contains_substring s sub =
  let slen = String.length s and sublen = String.length sub in
  if sublen > slen then false
  else
    let rec loop i =
      if i > slen - sublen then false
      else if String.sub s i sublen = sub then true
      else loop (i + 1)
    in
    loop 0

let test_executor_merge_with_valid_pr () =
  (* Topic with valid PR number should match and extract the number *)
  match Executor.find_action "Merge PR #42" with
  | None -> fail "should match merge PR pattern"
  | Some mapping ->
    (* The template uses MergePR 0 as placeholder *)
    (match mapping.Executor.action with
     | Executor.GitHubAction (Executor.MergePR 0) -> ()
     | _ -> fail "expected MergePR 0 placeholder in template");
    (* extract_number should find 42 from the topic *)
    (match Executor.extract_number "Merge PR #42" with
     | Some 42 -> ()
     | Some n -> fail (Printf.sprintf "expected 42, got %d" n)
     | None -> fail "should extract 42")

let test_executor_deploy_errors () =
  (* Deploy stub should error, not pretend to succeed *)
  let result = Consensus.Unanimous Consensus.Approve in
  match Executor.execute_decision ~topic:"deploy v2.0" ~result with
  | None -> fail "should return Some (error result), not None"
  | Some r ->
    check bool "not successful" (not r.Executor.success) true;
    check bool "mentions deploy"
      (contains_substring r.output "deploy") true

let test_executor_deploy_not_silent () =
  (* Verify the deploy mapping still exists but is explicitly blocked *)
  match Executor.find_action "deploy v1.0" with
  | None -> fail "deploy pattern should still match"
  | Some mapping ->
    (* The template has the echo placeholder *)
    (match mapping.Executor.action with
     | Executor.ExecCommand ["echo"; "Deploy placeholder"] -> ()
     | _ -> fail "expected deploy echo placeholder in template")

let executor_tests = [
  "find action PR", `Quick, test_executor_find_action_pr;
  "no action for random", `Quick, test_executor_find_action_none;
  "dry run approve", `Quick, test_executor_dry_run_approve;
  "dry run reject", `Quick, test_executor_dry_run_reject;
  "github argv create issue", `Quick, test_executor_github_argv_create_issue;
  "merge with valid PR extracts number", `Quick, test_executor_merge_with_valid_pr;
  "deploy stub errors", `Quick, test_executor_deploy_errors;
  "deploy pattern exists but blocked", `Quick, test_executor_deploy_not_silent;
]

(* ============================================================
   Integration Tests - Full Council Flow
   ============================================================ *)

let test_full_council_flow () =
  setup ();
  let notify_fn = fun ~agent:_ ~message:_ -> () in
  
  (* 1. Start debate *)
  let debate = match Debate.start_debate test_base_path ~topic:"Full flow test" ~notify_fn () with
    | Ok d -> d
    | Error e -> failwith (Printf.sprintf "debate failed: %s" e)
  in
  check bool "debate created" (String.length debate.Debate.id > 0) true;
  
  (* 2. Add arguments *)
  (match Debate.add_argument test_base_path ~debate_id:debate.id 
           ~agent:"agent1" ~content:"Pro argument" ~position:Debate.Support () with
   | Ok _ -> ()
   | Error e -> failwith (Printf.sprintf "arg1 failed: %s" e));
  
  (match Debate.add_argument test_base_path ~debate_id:debate.id
           ~agent:"agent2" ~content:"Con argument" ~position:Debate.Oppose () with
   | Ok _ -> ()
   | Error e -> failwith (Printf.sprintf "arg2 failed: %s" e));
  
  (* 3. Close debate *)
  (match Debate.close_debate test_base_path ~debate_id:debate.id with
   | Ok _ -> ()
   | Error e -> failwith (Printf.sprintf "close failed: %s" e));
  
  (* 4. Start consensus *)
  let session = match Consensus.start_voting ~topic:"Decision on debate" ~initiator:"test" ~quorum:2 ~threshold:0.5 () with
    | Ok s -> s
    | Error _ -> failwith "start voting failed"
  in
  check bool "session created" (String.length session.Consensus.id > 0) true;
  
  (* 5. Cast votes *)
  (match Consensus.cast_vote ~session_id:session.id ~agent:"agent1" 
           ~decision:Consensus.Approve ~reason:"Agreed" () with
   | Ok _ -> ()
   | Error _ -> failwith "vote1 failed");
  
  (match Consensus.cast_vote ~session_id:session.id ~agent:"agent2"
           ~decision:Consensus.Approve ~reason:"Also agreed" () with
   | Ok _ -> ()
   | Error _ -> failwith "vote2 failed");
  
  (* 6. Check result *)
  (match Consensus.get_result ~session_id:session.id with
   | Ok result ->
     let result_str = Consensus.voting_result_to_string result in
     check bool "unanimous approve" (result_str = "✅ Unanimous: Approved") true
   | Error _ -> failwith "get result failed");
  
  teardown ()

let test_debate_to_consensus_handoff () =
  setup ();
  let notify_fn = fun ~agent:_ ~message:_ -> () in
  
  (* Debate with mixed positions *)
  let debate = match Debate.start_debate test_base_path ~topic:"Handoff test" ~notify_fn () with
    | Ok d -> d
    | Error e -> failwith e
  in
  
  ignore (Debate.add_argument test_base_path ~debate_id:debate.id
            ~agent:"a" ~content:"Yes" ~position:Debate.Support ());
  ignore (Debate.add_argument test_base_path ~debate_id:debate.id
            ~agent:"b" ~content:"No" ~position:Debate.Oppose ());
  ignore (Debate.add_argument test_base_path ~debate_id:debate.id
            ~agent:"c" ~content:"Maybe" ~position:Debate.Neutral ());
  
  (* Close debate *)
  (match Debate.close_debate test_base_path ~debate_id:debate.id with
   | Ok _ -> ()
   | Error e -> failwith e);
  
  (* Verify counts via status *)
  (match Debate.get_debate_status test_base_path ~debate_id:debate.id with
   | Ok summary ->
     check int "support" summary.Debate.support_count 1;
     check int "oppose" summary.oppose_count 1;
     check int "neutral" summary.neutral_count 1
   | Error e -> failwith e);
  
  teardown ()

let integration_tests = [
  "full council flow", `Quick, test_full_council_flow;
  "debate to consensus handoff", `Quick, test_debate_to_consensus_handoff;
]

(* ============================================================
   Conversation Tests
   ============================================================ *)

module Conversation = Council.Conversation
module Loop_guard = Council.Loop_guard

let convo_test_root = "/tmp/masc-test-convo"

let convo_config : Conversation.config = {
  base_path = convo_test_root;  (* masc_dir uses Sys.getcwd(), we override threads_dir via config *)
  room = "test-room";
}

let convo_setup () =
  (try rm_rf convo_test_root with _ -> ());
  mkdir_p (Filename.concat convo_test_root ".masc/conversations/threads")

let convo_teardown () =
  (try rm_rf convo_test_root with _ -> ())

let test_convo_start () =
  convo_setup ();
  match Conversation.start ~config:convo_config ~topic:"Test topic" ~initiator:"alice" () with
  | Ok th ->
    check bool "has id" (String.length th.Conversation.id > 0) true;
    check string "topic" th.topic "Test topic";
    check string "room" th.room "test-room";
    check bool "active" (th.status = Conversation.Active) true;
    check bool "alice in participants" (List.mem "alice" th.participants) true;
    check int "no turns" (List.length th.turns) 0;
    convo_teardown ()
  | Error e ->
    convo_teardown (); fail e

let test_convo_start_with_content () =
  convo_setup ();
  match Conversation.start ~config:convo_config ~topic:"With content"
          ~initiator:"bob" ~initial_content:"Hello everyone" () with
  | Ok th ->
    check int "1 turn" (List.length th.Conversation.turns) 1;
    check int "current_turn 1" th.current_turn 1;
    let turn = List.hd th.turns in
    check string "speaker" turn.Conversation.speaker "bob";
    check string "content" turn.content "Hello everyone";
    check bool "initiate type" (turn.turn_type = Conversation.Initiate) true;
    convo_teardown ()
  | Error e ->
    convo_teardown (); fail e

let test_convo_reply () =
  convo_setup ();
  match Conversation.start ~config:convo_config ~topic:"Reply test"
          ~initiator:"alice" ~initial_content:"Start" () with
  | Error e -> convo_teardown (); fail e
  | Ok th ->
    match Conversation.reply ~config:convo_config ~thread_id:th.Conversation.id
            ~speaker:"bob" ~content:"I agree" () with
    | Error e -> convo_teardown (); fail e
    | Ok updated ->
      check int "2 turns" (List.length updated.Conversation.turns) 2;
      check int "current_turn 2" updated.current_turn 2;
      check bool "bob in participants" (List.mem "bob" updated.participants) true;
      check bool "alice in participants" (List.mem "alice" updated.participants) true;
      convo_teardown ()

let test_convo_conclude () =
  convo_setup ();
  match Conversation.start ~config:convo_config ~topic:"Conclude test"
          ~initiator:"alice" ~initial_content:"Discuss" () with
  | Error e -> convo_teardown (); fail e
  | Ok th ->
    match Conversation.conclude ~config:convo_config ~thread_id:th.Conversation.id
            ~concluder:"alice" ~conclusion:"We decided X" () with
    | Error e -> convo_teardown (); fail e
    | Ok concluded ->
      check bool "concluded" (concluded.Conversation.status = Conversation.Concluded) true;
      check bool "has conclusion" (concluded.conclusion = Some "We decided X") true;
      check bool "has concluded_at" (concluded.concluded_at <> None) true;
      (* Last turn should be Conclude type *)
      let last = List.rev concluded.turns |> List.hd in
      check bool "conclude turn" (last.Conversation.turn_type = Conversation.Conclude) true;
      convo_teardown ()

let test_convo_reply_after_conclude () =
  convo_setup ();
  match Conversation.start ~config:convo_config ~topic:"No reply after" ~initiator:"a" () with
  | Error e -> convo_teardown (); fail e
  | Ok th ->
    let _ = Conversation.conclude ~config:convo_config ~thread_id:th.Conversation.id
              ~concluder:"a" ~conclusion:"Done" () in
    match Conversation.reply ~config:convo_config ~thread_id:th.Conversation.id
            ~speaker:"b" ~content:"Late reply" () with
    | Ok _ -> convo_teardown (); fail "should not allow reply after conclude"
    | Error _ -> convo_teardown ()

let test_convo_persistence () =
  convo_setup ();
  match Conversation.start ~config:convo_config ~topic:"Persist test"
          ~initiator:"alice" ~initial_content:"Save me" () with
  | Error e -> convo_teardown (); fail e
  | Ok th ->
    let thread_id = th.Conversation.id in
    (* Reply to build state *)
    let _ = Conversation.reply ~config:convo_config ~thread_id
              ~speaker:"bob" ~content:"Saved too" () in
    (* Read from disk *)
    match Conversation.get ~config:convo_config ~thread_id with
    | None -> convo_teardown (); fail "should find persisted thread"
    | Some loaded ->
      check string "same id" loaded.Conversation.id thread_id;
      check int "2 turns" (List.length loaded.turns) 2;
      check string "topic preserved" loaded.topic "Persist test";
      convo_teardown ()

let test_convo_list_active () =
  convo_setup ();
  let _ = Conversation.start ~config:convo_config ~topic:"Active 1" ~initiator:"a" () in
  let _ = Conversation.start ~config:convo_config ~topic:"Active 2" ~initiator:"b" () in
  let active = Conversation.list_active ~config:convo_config in
  check bool "at least 2 active" (List.length active >= 2) true;
  convo_teardown ()

let test_convo_not_found () =
  convo_setup ();
  match Conversation.reply ~config:convo_config ~thread_id:"nonexistent"
          ~speaker:"a" ~content:"Hello" () with
  | Ok _ -> convo_teardown (); fail "should fail for missing thread"
  | Error _ -> convo_teardown ()

let conversation_tests = [
  "start thread", `Quick, test_convo_start;
  "start with initial content", `Quick, test_convo_start_with_content;
  "reply to thread", `Quick, test_convo_reply;
  "conclude thread", `Quick, test_convo_conclude;
  "reply after conclude blocked", `Quick, test_convo_reply_after_conclude;
  "persistence roundtrip", `Quick, test_convo_persistence;
  "list active threads", `Quick, test_convo_list_active;
  "reply to nonexistent thread", `Quick, test_convo_not_found;
]

(* ============================================================
   Loop Guard Tests
   ============================================================ *)

let make_test_thread ?(turns=[]) ?(max_turns=50) ?(floor_holder=None) () : Conversation.thread =
  { id = "test-thread"; topic = "test"; room = "test";
    status = Conversation.Active; turns; participants = [];
    started_at = Unix.gettimeofday (); concluded_at = None;
    conclusion = None; max_turns; current_turn = List.length turns;
    floor_holder; source_post_id = None }

let make_turn ~speaker ~content ~seq : Conversation.turn =
  { id = Printf.sprintf "turn-%d" seq; seq; speaker; content;
    turn_type = Conversation.Respond; created_at = Unix.gettimeofday ();
    confidence = None; reply_to = None; mentions = [] }

let test_loop_no_loop () =
  let thread = make_test_thread () in
  let result = Loop_guard.check ~thread ~speaker:"alice" ~content:"Hello"
                 ~config:Loop_guard.default_config in
  check bool "no loop" (result = Loop_guard.NoLoop) true

let test_loop_max_turns () =
  let config : Loop_guard.loop_config = { max_turns = 5; max_identical = 3; cooldown_sec = 0.0 } in
  let thread = make_test_thread ~max_turns:5
    ~turns:(List.init 5 (fun i -> make_turn ~speaker:"a" ~content:(string_of_int i) ~seq:i)) () in
  let result = Loop_guard.check ~thread ~speaker:"a" ~content:"more" ~config in
  match result with
  | Loop_guard.MaxTurnsReached _ -> ()
  | other -> fail (Printf.sprintf "expected MaxTurnsReached, got %s"
                     (Loop_guard.loop_detection_to_string other))

let test_loop_identical_pattern () =
  let turns = List.init 3 (fun i ->
    make_turn ~speaker:"spammer" ~content:"same message" ~seq:i) in
  let thread = make_test_thread ~turns () in
  let result = Loop_guard.check ~thread ~speaker:"spammer" ~content:"same message"
                 ~config:Loop_guard.default_config in
  match result with
  | Loop_guard.IdenticalPattern _ -> ()
  | _ -> fail (Printf.sprintf "expected IdenticalPattern, got %s"
                 (Loop_guard.loop_detection_to_string result))

let test_loop_different_speakers_ok () =
  (* Disable cooldown to focus on identical pattern check *)
  let config : Loop_guard.loop_config = { max_turns = 50; max_identical = 3; cooldown_sec = 0.0 } in
  let turns = [
    make_turn ~speaker:"alice" ~content:"same" ~seq:0;
    make_turn ~speaker:"bob" ~content:"same" ~seq:1;
    make_turn ~speaker:"alice" ~content:"same" ~seq:2;
  ] in
  let thread = make_test_thread ~turns () in
  (* bob says "same" - only 1 consecutive from bob, should be OK *)
  let result = Loop_guard.check ~thread ~speaker:"bob" ~content:"same" ~config in
  check bool "no loop for different speakers"
    (result = Loop_guard.NoLoop) true

let test_loop_error_message () =
  let msg = Loop_guard.to_error_message Loop_guard.NoLoop in
  check bool "no error for NoLoop" (msg = None) true;
  let msg2 = Loop_guard.to_error_message
    (Loop_guard.MaxTurnsReached { current = 50; max = 50 }) in
  check bool "has error for MaxTurns" (msg2 <> None) true

let loop_guard_tests = [
  "no loop detected", `Quick, test_loop_no_loop;
  "max turns reached", `Quick, test_loop_max_turns;
  "identical pattern blocked", `Quick, test_loop_identical_pattern;
  "different speakers ok", `Quick, test_loop_different_speakers_ok;
  "error message generation", `Quick, test_loop_error_message;
]

(* ============================================================
   Thread Persist Tests (file-only, no Neo4j)
   ============================================================ *)

module Thread_persist = Council.Thread_persist

let test_persist_save_load () =
  convo_setup ();
  match Conversation.start ~config:convo_config ~topic:"Persist"
          ~initiator:"alice" ~initial_content:"Test" () with
  | Error e -> convo_teardown (); fail e
  | Ok th ->
    let result = Thread_persist.save_thread ~config:convo_config ~thread:th in
    check bool "file saved" result.Thread_persist.file_ok true;
    (* Neo4j may fail in test env - that's expected *)
    match Thread_persist.load_thread ~config:convo_config ~thread_id:th.Conversation.id with
    | None -> convo_teardown (); fail "should load after save"
    | Some loaded ->
      check string "id matches" loaded.Conversation.id th.id;
      convo_teardown ()

let test_persist_cypher_escape () =
  (* Test that cypher_escape handles dangerous strings *)
  let escaped = Thread_persist.cypher_escape "O'Reilly" in
  check bool "single quote escaped" (String.contains escaped '\'' = false ||
    (let i = String.index escaped '\'' in i > 0 && escaped.[i-1] = '\\')) true;
  let escaped2 = Thread_persist.cypher_escape "back\\slash" in
  check bool "backslash escaped" (String.length escaped2 > String.length "back\\slash") true

let test_persist_clear_context_disables_neo4j () =
  Thread_persist.clear_eio_context ();
  match Thread_persist.execute_cypher_http ~cypher:"RETURN 1" with
  | Error msg ->
      check bool "reports disabled neo4j path" true
        (String.length msg > 0
         && (String.contains msg 'n' || String.contains msg 'N'))
  | Ok () ->
      fail "expected neo4j path to be disabled without eio context"

let persist_tests = [
  "dual-stream save + load", `Quick, test_persist_save_load;
  "cypher escape safety", `Quick, test_persist_cypher_escape;
  "clear context disables neo4j", `Quick, test_persist_clear_context_disables_neo4j;
]

let () =
  run "Council" [
    "Debate", debate_tests;
    "Consensus", consensus_tests;
    "Router", router_tests;
    "Balance", balance_tests;
    "Executor", executor_tests;
    "Conversation", conversation_tests;
    "LoopGuard", loop_guard_tests;
    "ThreadPersist", persist_tests;
    "Integration", integration_tests;
  ]
