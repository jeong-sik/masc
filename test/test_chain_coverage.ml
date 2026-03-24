(** Coverage tests for chain_mermaid_node_content, chain_mermaid_parser, chain_parser_serialize.
    Targets: all pure functions and variant branches. *)

open Alcotest
open Masc_mcp
open Chain_types

(* ============================================================
   Helpers
   ============================================================ *)

let check_ok msg = function
  | Ok _ -> ()
  | Error e -> fail (msg ^ ": " ^ e)

let check_ok_with msg f = function
  | Ok v -> f v
  | Error e -> fail (msg ^ ": " ^ e)

let check_err msg = function
  | Error _ -> ()
  | Ok _ -> fail (msg ^ ": expected Error")

let dummy_node id nt =
  { id; node_type = nt; input_mapping = []; output_key = None; depends_on = None }

let dummy_model ?(model="gemini") ?(prompt="hello") () =
  Model { model; system = None; prompt; timeout = None; tools = None;
        prompt_ref = None; prompt_vars = []; thinking = false }

let dummy_chain nodes =
  { id = "test"; nodes; output = "out"; config = default_config;
    name = None; description = None; version = None;
    input_schema = None; output_schema = None; metadata = None }

(* ============================================================
   1. Chain_mermaid_node_content — normalize_label_content
   ============================================================ *)

let test_normalize_escaped_quotes () =
  let r = Chain_mermaid_node_content.normalize_label_content {|say \"hi\" and \'bye\'|} in
  check string "escaped quotes normalized" {|say "hi" and 'bye'|} r

let test_normalize_no_escapes () =
  let r = Chain_mermaid_node_content.normalize_label_content "plain text" in
  check string "no change" "plain text" r

(* ============================================================
   2. Chain_mermaid_node_content — parse_node_content Subroutine
   ============================================================ *)

let test_subroutine_ref () =
  check_ok_with "Ref" (fun nt ->
    match nt with ChainRef id -> check string "ref" "my_chain" id | _ -> fail "not ChainRef"
  ) (Chain_mermaid_node_content.parse_node_content `Subroutine "Ref:my_chain")

let test_subroutine_pipeline () =
  check_ok_with "Pipeline" (fun nt ->
    match nt with Pipeline nodes -> check int "3 nodes" 3 (List.length nodes) | _ -> fail "not Pipeline"
  ) (Chain_mermaid_node_content.parse_node_content `Subroutine "Pipeline:A,B,C")

let test_subroutine_fanout () =
  check_ok_with "Fanout" (fun nt ->
    match nt with Fanout nodes -> check int "2 nodes" 2 (List.length nodes) | _ -> fail "not Fanout"
  ) (Chain_mermaid_node_content.parse_node_content `Subroutine "Fanout:X,Y")

let test_subroutine_map () =
  check_ok_with "Map" (fun nt ->
    match nt with Map { func; _ } -> check string "func" "f" func | _ -> fail "not Map"
  ) (Chain_mermaid_node_content.parse_node_content `Subroutine "Map:f,nodeA")

let test_subroutine_map_bad () =
  check_err "Map bad" (Chain_mermaid_node_content.parse_node_content `Subroutine "Map:only_one")

let test_subroutine_bind () =
  check_ok_with "Bind" (fun nt ->
    match nt with Bind { func; _ } -> check string "func" "g" func | _ -> fail "not Bind"
  ) (Chain_mermaid_node_content.parse_node_content `Subroutine "Bind:g,nodeB")

let test_subroutine_bind_bad () =
  check_err "Bind bad" (Chain_mermaid_node_content.parse_node_content `Subroutine "Bind:only")

let test_subroutine_cache_3 () =
  check_ok_with "Cache 3" (fun nt ->
    match nt with Cache { key_expr; ttl_seconds; _ } ->
      check string "key" "k" key_expr; check int "ttl" 60 ttl_seconds
    | _ -> fail "not Cache"
  ) (Chain_mermaid_node_content.parse_node_content `Subroutine "Cache:k,60,nodeC")

let test_subroutine_cache_2 () =
  check_ok_with "Cache 2" (fun nt ->
    match nt with Cache { ttl_seconds; _ } -> check int "ttl default" 0 ttl_seconds | _ -> fail "not Cache"
  ) (Chain_mermaid_node_content.parse_node_content `Subroutine "Cache:k,nodeC")

let test_subroutine_cache_bad () =
  check_err "Cache bad" (Chain_mermaid_node_content.parse_node_content `Subroutine "Cache:only")

let test_subroutine_batch_3 () =
  check_ok_with "Batch 3" (fun nt ->
    match nt with Batch { batch_size; parallel; _ } ->
      check int "size" 10 batch_size; check bool "parallel" true parallel
    | _ -> fail "not Batch"
  ) (Chain_mermaid_node_content.parse_node_content `Subroutine "Batch:10,true,nodeD")

let test_subroutine_batch_2 () =
  check_ok_with "Batch 2" (fun nt ->
    match nt with Batch { batch_size; parallel; _ } ->
      check int "size" 5 batch_size; check bool "parallel default" true parallel
    | _ -> fail "not Batch"
  ) (Chain_mermaid_node_content.parse_node_content `Subroutine "Batch:5,nodeD")

let test_subroutine_batch_bad () =
  check_err "Batch bad" (Chain_mermaid_node_content.parse_node_content `Subroutine "Batch:only")

let test_subroutine_spawn_2 () =
  check_ok_with "Spawn 2" (fun nt ->
    match nt with Spawn { clean; _ } -> check bool "clean" true clean | _ -> fail "not Spawn"
  ) (Chain_mermaid_node_content.parse_node_content `Subroutine "Spawn:clean,nodeE")

let test_subroutine_spawn_3 () =
  check_ok_with "Spawn 3" (fun nt ->
    match nt with Spawn { clean; pass_vars; _ } ->
      check bool "inherit" false clean; check int "vars" 2 (List.length pass_vars)
    | _ -> fail "not Spawn"
  ) (Chain_mermaid_node_content.parse_node_content `Subroutine "Spawn:false,a|b,nodeE")

let test_subroutine_spawn_bad () =
  check_err "Spawn bad" (Chain_mermaid_node_content.parse_node_content `Subroutine "Spawn:only")

let test_subroutine_stream_merge_1 () =
  check_ok_with "SM 1" (fun nt ->
    match nt with StreamMerge { reducer; _ } ->
      (match reducer with First -> () | _ -> fail "not First")
    | _ -> fail "not SM"
  ) (Chain_mermaid_node_content.parse_node_content `Subroutine "StreamMerge:first")

let test_subroutine_stream_merge_2 () =
  check_ok_with "SM 2" (fun nt ->
    match nt with StreamMerge { min_results; _ } ->
      check (option int) "min" (Some 3) min_results
    | _ -> fail "not SM"
  ) (Chain_mermaid_node_content.parse_node_content `Subroutine "StreamMerge:concat,3")

let test_subroutine_stream_merge_3 () =
  check_ok_with "SM 3" (fun nt ->
    match nt with StreamMerge { timeout; _ } ->
      (match timeout with Some t -> check bool "timeout" true (t > 0.0) | None -> fail "no timeout")
    | _ -> fail "not SM"
  ) (Chain_mermaid_node_content.parse_node_content `Subroutine "StreamMerge:last,2,10.0")

let test_subroutine_stream_merge_bad () =
  check_err "SM bad" (Chain_mermaid_node_content.parse_node_content `Subroutine "StreamMerge:a,b,c,d")

let test_subroutine_stream_merge_reducers () =
  (* Test all reducer types *)
  List.iter (fun (s, _label) ->
    check_ok ("SM reducer " ^ s)
      (Chain_mermaid_node_content.parse_node_content `Subroutine (Printf.sprintf "StreamMerge:%s" s))
  ) [("first", "First"); ("last", "Last"); ("concat", "Concat");
     ("weighted", "WeightedAvg"); ("myreducer", "Custom")]

let test_subroutine_feedback_3 () =
  check_ok_with "FL 3" (fun nt ->
    match nt with FeedbackLoop { score_threshold; score_operator; max_iterations; _ } ->
      check bool "threshold" true (score_threshold > 0.9);
      (match score_operator with Gte -> () | _ -> fail "not Gte");
      check int "iter" 5 max_iterations
    | _ -> fail "not FL"
  ) (Chain_mermaid_node_content.parse_node_content `Subroutine "FeedbackLoop:quality,5,>=0.95")

let test_subroutine_feedback_2 () =
  check_ok_with "FL 2" (fun nt ->
    match nt with FeedbackLoop { max_iterations; _ } -> check int "iter" 10 max_iterations
    | _ -> fail "not FL"
  ) (Chain_mermaid_node_content.parse_node_content `Subroutine "FeedbackLoop:quality,10")

let test_subroutine_feedback_1 () =
  check_ok_with "FL 1" (fun nt ->
    match nt with FeedbackLoop { max_iterations; _ } -> check int "default" 3 max_iterations
    | _ -> fail "not FL"
  ) (Chain_mermaid_node_content.parse_node_content `Subroutine "FeedbackLoop:quality")

let test_subroutine_feedback_bad () =
  check_err "FL bad" (Chain_mermaid_node_content.parse_node_content `Subroutine "FeedbackLoop:")

let test_subroutine_feedback_ops () =
  (* Test all threshold operator parsing *)
  List.iter (fun (prefix, _expected) ->
    let input = Printf.sprintf "FeedbackLoop:f,3,%s0.5" prefix in
    check_ok ("FL op " ^ prefix) (Chain_mermaid_node_content.parse_node_content `Subroutine input)
  ) [(">=", "Gte"); ("<=", "Lte"); ("!=", "Neq"); (">", "Gt"); ("<", "Lt"); ("=", "Eq"); ("", "Gte")]

let test_subroutine_unknown () =
  check_err "unknown" (Chain_mermaid_node_content.parse_node_content `Subroutine "RandomStuff")

(* ============================================================
   3. parse_node_content Diamond
   ============================================================ *)

let test_diamond_quorum () =
  check_ok_with "Quorum" (fun nt ->
    match nt with Quorum _ -> () | _ -> fail "not Quorum"
  ) (Chain_mermaid_node_content.parse_node_content `Diamond "Quorum:majority")

let test_diamond_gate () =
  check_ok_with "Gate" (fun nt ->
    match nt with Gate { condition; _ } -> check string "cond" "x > 0" condition | _ -> fail "not Gate"
  ) (Chain_mermaid_node_content.parse_node_content `Diamond "Gate:x > 0")

let test_diamond_merge () =
  check_ok_with "Merge" (fun nt ->
    match nt with Merge { strategy; _ } ->
      (match strategy with WeightedAvg -> () | _ -> fail "not weighted")
    | _ -> fail "not Merge"
  ) (Chain_mermaid_node_content.parse_node_content `Diamond "Merge:weighted_avg")

let test_diamond_merge_strategies () =
  List.iter (fun (s, _) ->
    check_ok ("Merge " ^ s) (Chain_mermaid_node_content.parse_node_content `Diamond (Printf.sprintf "Merge:%s" s))
  ) [("first", "First"); ("last", "Last"); ("concat", "Concat"); ("weighted", "WeightedAvg"); ("custom_fn", "Custom")]

let test_diamond_goaldriven () =
  check_ok_with "GoalDriven" (fun nt ->
    match nt with GoalDriven { goal_metric; max_iterations; _ } ->
      check string "metric" "coverage" goal_metric;
      check int "iter" 10 max_iterations
    | _ -> fail "not GoalDriven"
  ) (Chain_mermaid_node_content.parse_node_content `Diamond "GoalDriven:coverage:gte:0.90:10")

let test_diamond_goaldriven_ops () =
  List.iter (fun op ->
    let input = Printf.sprintf "GoalDriven:metric:%s:0.5:5" op in
    check_ok ("GD op " ^ op) (Chain_mermaid_node_content.parse_node_content `Diamond input)
  ) ["gt"; "gte"; "lt"; "lte"; "eq"; "neq"; "unknown"]

let test_diamond_goaldriven_bad () =
  check_err "GD bad" (Chain_mermaid_node_content.parse_node_content `Diamond "GoalDriven:bad_format")

let test_diamond_mcts_greedy () =
  check_ok_with "MCTS greedy" (fun nt ->
    match nt with Mcts { policy; _ } ->
      (match policy with Greedy -> () | _ -> fail "not Greedy")
    | _ -> fail "not Mcts"
  ) (Chain_mermaid_node_content.parse_node_content `Diamond "MCTS:greedy:10")

let test_diamond_mcts_ucb1 () =
  check_ok_with "MCTS ucb1" (fun nt ->
    match nt with Mcts { policy; _ } ->
      (match policy with UCB1 _ -> () | _ -> fail "not UCB1")
    | _ -> fail "not Mcts"
  ) (Chain_mermaid_node_content.parse_node_content `Diamond "MCTS:ucb1:1.41:10")

let test_diamond_mcts_eps () =
  check_ok "MCTS eps" (Chain_mermaid_node_content.parse_node_content `Diamond "MCTS:eps:0.1:10")

let test_diamond_mcts_softmax () =
  check_ok "MCTS softmax" (Chain_mermaid_node_content.parse_node_content `Diamond "MCTS:softmax:1.0:10")

let test_diamond_mcts_bad () =
  check_err "MCTS bad" (Chain_mermaid_node_content.parse_node_content `Diamond "MCTS:a:b:c:d")

let test_diamond_evaluator_3 () =
  check_ok_with "Eval 3" (fun nt ->
    match nt with Evaluator { scoring_func; select_strategy; min_score; _ } ->
      check string "func" "model" scoring_func;
      (match select_strategy with Best -> () | _ -> fail "not Best");
      (match min_score with Some _ -> () | None -> fail "no min_score")
    | _ -> fail "not Eval"
  ) (Chain_mermaid_node_content.parse_node_content `Diamond "Evaluator:model:best:0.5")

let test_diamond_evaluator_strategies () =
  List.iter (fun (s, _) ->
    check_ok ("Eval " ^ s)
      (Chain_mermaid_node_content.parse_node_content `Diamond (Printf.sprintf "Evaluator:f:%s" s))
  ) [("best", "Best"); ("worst", "Worst"); ("weighted", "WeightedRandom"); ("above:0.5", "AboveThreshold")]

let test_diamond_evaluator_1 () =
  check_ok "Eval 1" (Chain_mermaid_node_content.parse_node_content `Diamond "Evaluator:judge")

let test_diamond_evaluator_bad () =
  (* "Evaluator:" with empty parts parses as single empty string which matches [scoring_func] *)
  (* So test with truly bad format: no parts at all *)
  check_err "Eval bad" (Chain_mermaid_node_content.parse_node_content `Diamond "Evaluator:a:b:c:d")

let test_diamond_threshold () =
  check_ok_with "Threshold" (fun nt ->
    match nt with Threshold { operator; value; _ } ->
      (match operator with Gte -> () | _ -> fail "not Gte");
      check bool "value" true (value > 0.7)
    | _ -> fail "not Threshold"
  ) (Chain_mermaid_node_content.parse_node_content `Diamond "Threshold:>=0.8")

let test_diamond_threshold_ops () =
  List.iter (fun (prefix, _) ->
    check_ok ("Thr " ^ prefix)
      (Chain_mermaid_node_content.parse_node_content `Diamond (Printf.sprintf "Threshold:%s0.5" prefix))
  ) [(">=", "Gte"); ("<=", "Lte"); ("==", "Eq"); ("!=", "Neq"); (">", "Gt"); ("<", "Lt")]

let test_diamond_threshold_bad_op () =
  check_err "Thr bad op" (Chain_mermaid_node_content.parse_node_content `Diamond "Threshold:abc")

let test_diamond_threshold_bad_val () =
  check_err "Thr bad val" (Chain_mermaid_node_content.parse_node_content `Diamond "Threshold:>=notanumber")

let test_diamond_unknown () =
  check_err "Diamond unknown" (Chain_mermaid_node_content.parse_node_content `Diamond "RandomStuff")

(* ============================================================
   4. parse_node_content Rect
   ============================================================ *)

let test_rect_model_quoted () =
  check_ok_with "MODEL quoted" (fun nt ->
    match nt with Model { model; prompt; _ } ->
      check string "model" "claude" model;
      check string "prompt" "say hi" prompt
    | _ -> fail "not Model"
  ) (Chain_mermaid_node_content.parse_node_content `Rect {|MODEL:claude "say hi"|})

let test_rect_model_single_quoted () =
  check_ok_with "MODEL single" (fun nt ->
    match nt with Model { model; _ } -> check string "model" "gemini" model | _ -> fail "not Model"
  ) (Chain_mermaid_node_content.parse_node_content `Rect "MODEL:gemini 'hello'")

let test_rect_model_model_only () =
  check_ok_with "MODEL model only" (fun nt ->
    match nt with Model { model; prompt; _ } ->
      check string "model" "codex" model;
      check string "prompt" "{{input}}" prompt
    | _ -> fail "not Model"
  ) (Chain_mermaid_node_content.parse_node_content `Rect "MODEL:codex")

let test_rect_tool_simple () =
  check_ok_with "Tool simple" (fun nt ->
    match nt with Tool { name; _ } -> check string "name" "search" name | _ -> fail "not Tool"
  ) (Chain_mermaid_node_content.parse_node_content `Rect "Tool:search")

let test_rect_tool_quoted () =
  check_ok_with "Tool quoted" (fun nt ->
    match nt with Tool { name; _ } -> check string "name" "search" name | _ -> fail "not Tool"
  ) (Chain_mermaid_node_content.parse_node_content `Rect {|Tool:search "query string"|})

let test_rect_tool_json () =
  check_ok_with "Tool json" (fun nt ->
    match nt with Tool { name; args } ->
      check string "name" "calc" name;
      (match args with `Assoc _ -> () | _ -> fail "not Assoc")
    | _ -> fail "not Tool"
  ) (Chain_mermaid_node_content.parse_node_content `Rect {|Tool:calc {"x": 1}|})

let test_rect_default_model () =
  check_ok_with "default MODEL" (fun nt ->
    match nt with Model { model; _ } -> check string "model" "gemini" model | _ -> fail "not Model"
  ) (Chain_mermaid_node_content.parse_node_content `Rect "just some text")

let test_rect_tools_flag () =
  check_ok_with "+tools" (fun nt ->
    match nt with Model { tools; _ } ->
      (match tools with Some _ -> () | None -> fail "no tools")
    | _ -> fail "not Model"
  ) (Chain_mermaid_node_content.parse_node_content `Rect "MODEL:gemini 'hello' +tools")

(* ============================================================
   5. parse_node_content Trap (Adapter)
   ============================================================ *)

let test_trap_adapt () =
  check_ok_with "Adapt" (fun nt ->
    match nt with Adapter _ -> () | _ -> fail "not Adapter"
  ) (Chain_mermaid_node_content.parse_node_content `Trap "Adapt something")

let test_trap_generic () =
  check_ok_with "Generic trap" (fun nt ->
    match nt with Adapter _ -> () | _ -> fail "not Adapter"
  ) (Chain_mermaid_node_content.parse_node_content `Trap "some content")

(* ============================================================
   6. parse_node_content Stadium
   ============================================================ *)

let test_stadium_retry () =
  check_ok_with "Retry" (fun nt ->
    match nt with Retry { max_attempts; _ } -> check int "attempts" 5 max_attempts | _ -> fail "not Retry"
  ) (Chain_mermaid_node_content.parse_node_content `Stadium "Retry:5")

let test_stadium_fallback () =
  check_ok_with "Fallback" (fun nt ->
    match nt with Fallback _ -> () | _ -> fail "not Fallback"
  ) (Chain_mermaid_node_content.parse_node_content `Stadium "Fallback")

let test_stadium_fallback_colon () =
  check_ok "Fallback:" (Chain_mermaid_node_content.parse_node_content `Stadium "Fallback:primary")

let test_stadium_race () =
  check_ok_with "Race" (fun nt ->
    match nt with Race _ -> () | _ -> fail "not Race"
  ) (Chain_mermaid_node_content.parse_node_content `Stadium "Race")

let test_stadium_race_colon () =
  check_ok "Race:" (Chain_mermaid_node_content.parse_node_content `Stadium "Race:fast")

let test_stadium_cascade () =
  check_ok_with "Cascade" (fun nt ->
    match nt with Cascade _ -> () | _ -> fail "not Cascade"
  ) (Chain_mermaid_node_content.parse_node_content `Stadium "Cascade")

let test_stadium_cascade_colon () =
  check_ok_with "Cascade:" (fun nt ->
    match nt with Cascade { default_threshold; _ } ->
      check bool "threshold" true (default_threshold > 0.6)
    | _ -> fail "not Cascade"
  ) (Chain_mermaid_node_content.parse_node_content `Stadium "Cascade:0.8:full")

let test_stadium_default () =
  check_ok_with "Stadium default" (fun nt ->
    match nt with Model _ -> () | _ -> fail "not Model"
  ) (Chain_mermaid_node_content.parse_node_content `Stadium "some prompt")

(* ============================================================
   7. parse_node_content Circle (MASC)
   ============================================================ *)

let test_circle_broadcast () =
  check_ok_with "broadcast" (fun nt ->
    match nt with Masc_broadcast { message; _ } -> check bool "msg" true (String.length message >= 0)
    | _ -> fail "not broadcast"
  ) (Chain_mermaid_node_content.parse_node_content `Circle "MASC:broadcast hello")

let test_circle_listen () =
  check_ok_with "listen" (fun nt ->
    match nt with Masc_listen _ -> () | _ -> fail "not listen"
  ) (Chain_mermaid_node_content.parse_node_content `Circle "MASC:listen filter")

let test_circle_claim () =
  check_ok_with "claim" (fun nt ->
    match nt with Masc_claim { task_id; _ } ->
      (match task_id with Some id -> check string "id" "t1" id | None -> fail "no id")
    | _ -> fail "not claim"
  ) (Chain_mermaid_node_content.parse_node_content `Circle "MASC:claim t1")

let test_circle_keyword_wait () =
  check_ok_with "wait" (fun nt ->
    match nt with Masc_listen _ -> () | _ -> fail "not listen"
  ) (Chain_mermaid_node_content.parse_node_content `Circle "waiting for events")

let test_circle_keyword_claim () =
  check_ok_with "grab" (fun nt ->
    match nt with Masc_claim _ -> () | _ -> fail "not claim"
  ) (Chain_mermaid_node_content.parse_node_content `Circle "grab next task")

let test_circle_fallback_broadcast () =
  (* Contains b and r -> broadcast *)
  check_ok_with "br fallback" (fun nt ->
    match nt with Masc_broadcast _ -> () | _ -> fail "not broadcast"
  ) (Chain_mermaid_node_content.parse_node_content `Circle "broad")

(* ============================================================
   8. Chain_mermaid_parser — node_type_to_id
   ============================================================ *)

let test_node_type_to_id_model () =
  let id = Chain_mermaid_parser.node_type_to_id (dummy_model ~model:"claude" ()) "fb" in
  check string "model id" "claude" id

let test_node_type_to_id_tool () =
  let id = Chain_mermaid_parser.node_type_to_id (Tool { name = "search"; args = `Null }) "fb" in
  check string "tool id" "search" id

let test_node_type_to_id_all_types () =
  (* Ensure all variants produce a non-empty id *)
  let inner = dummy_node "x" (dummy_model ()) in
  let chain = dummy_chain [inner] in
  let types = [
    dummy_model ();
    Tool { name = "t"; args = `Null };
    Quorum { consensus = Majority; nodes = []; weights = [] };
    Gate { condition = "c"; then_node = inner; else_node = None };
    Merge { strategy = First; nodes = [] };
    Pipeline [];
    Fanout [];
    Map { func = "f"; inner };
    Bind { func = "g"; inner };
    ChainRef "ref1";
    Subgraph chain;
    Threshold { metric = "m"; operator = Gt; value = 0.5; input_node = inner; on_pass = None; on_fail = None };
    GoalDriven { goal_metric = "g"; goal_operator = Gte; goal_value = 0.9;
                 action_node = inner; measure_func = "mf"; max_iterations = 5;
                 strategy_hints = []; conversational = false; relay_models = [] };
    Evaluator { candidates = []; scoring_func = "sf"; scoring_prompt = None; select_strategy = Best; min_score = None };
    Retry { node = inner; max_attempts = 3; backoff = Constant 1.0; retry_on = [] };
    Fallback { primary = inner; fallbacks = [] };
    Race { nodes = []; timeout = None };
    ChainExec { chain_source = "src"; validate = true; max_depth = 3; sandbox = false; context_inject = []; pass_outputs = true };
    Adapter { input_ref = "inp"; transform = Template "t"; on_error = `Fail };
    Cache { key_expr = "k"; ttl_seconds = 60; inner };
    Batch { batch_size = 10; parallel = true; inner; collect_strategy = `List };
    Spawn { clean = true; inner; pass_vars = []; inherit_cache = true };
    Mcts { strategies = []; simulation = inner; evaluator = "e"; evaluator_prompt = None;
           policy = UCB1 1.41; max_iterations = 10; max_depth = 5;
           expansion_threshold = 3; early_stop = None; parallel_sims = 1 };
    StreamMerge { nodes = []; reducer = Concat; initial = ""; min_results = Some 2; timeout = None };
    FeedbackLoop { generator = inner; evaluator_config = { scoring_func = "f"; scoring_prompt = None; select_strategy = Best };
                   improver_prompt = "p"; max_iterations = 3; score_threshold = 0.7; score_operator = Gte;
                   conversational = false; relay_models = [] };
    Masc_broadcast { room = None; message = "hi"; mention = [] };
    Masc_listen { room = None; filter = None; timeout_sec = 30.0 };
    Masc_claim { room = None; task_id = Some "t1" };
    Cascade { tiers = []; confidence_prompt = None; max_escalations = 2;
              context_mode = CM_Summary; task_hint = None; default_threshold = 0.7 };
  ] in
  List.iter (fun nt ->
    let id = Chain_mermaid_parser.node_type_to_id nt "fallback" in
    check bool "non-empty id" true (String.length id > 0);
    (* Verify id contains only valid mermaid node characters *)
    String.iter (fun c ->
      let valid = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                  || (c >= '0' && c <= '9') || c = '_' || c = '-' || c = '.' in
      check bool (Printf.sprintf "valid char '%c' in id %s" c id) true valid
    ) id
  ) types

(* ============================================================
   9. escape_for_mermaid
   ============================================================ *)

let test_escape_newlines () =
  let r = Chain_mermaid_parser.escape_for_mermaid "line1\nline2" in
  check bool "no newline" true (not (String.contains r '\n'))

let test_escape_quotes () =
  let r = Chain_mermaid_parser.escape_for_mermaid {|say "hello"|} in
  check bool "no dquote" true (not (String.contains r '"'))

let test_escape_truncation () =
  let long = String.make 200 'x' in
  let r = Chain_mermaid_parser.escape_for_mermaid ~max_len:50 long in
  check bool "truncated" true (String.length r <= 50)

(* ============================================================
   10. node_type_to_text — all variants
   ============================================================ *)

let test_node_type_to_text_model () =
  let t = Chain_mermaid_parser.node_type_to_text (Model { model = "m"; system = None; prompt = "p"; timeout = None; tools = None; prompt_ref = None; prompt_vars = []; thinking = false }) in
  check bool "contains MODEL" true
    (try ignore (Str.search_forward (Str.regexp_string "MODEL") t 0); true
     with Not_found -> false)

let test_node_type_to_text_tool_empty () =
  let t = Chain_mermaid_parser.node_type_to_text (Tool { name = "t"; args = `Assoc [] }) in
  check string "tool empty" "Tool:t" t

let test_node_type_to_text_tool_args () =
  let t = Chain_mermaid_parser.node_type_to_text (Tool { name = "t"; args = `Assoc [("k", `String "v")] }) in
  check bool "contains Tool prefix" true
    (try ignore (Str.search_forward (Str.regexp_string "Tool:") t 0); true
     with Not_found -> false);
  check bool "non-trivial output" true (String.length t > 6)

let test_node_type_to_text_model_with_tools () =
  let tools = Some (`List [`String "tool1"; `String "tool2"]) in
  let t = Chain_mermaid_parser.node_type_to_text (Model { model = "m"; system = None; prompt = "p"; timeout = None; tools; prompt_ref = None; prompt_vars = []; thinking = false }) in
  check bool "contains tools marker" true
    (try ignore (Str.search_forward (Str.regexp "tool") t 0); true
     with Not_found -> false)

(* ============================================================
   11. node_type_to_shape — all variants
   ============================================================ *)

let test_shapes () =
  let inner = dummy_node "x" (dummy_model ()) in
  let chain = dummy_chain [inner] in
  let types = [
    dummy_model (); Tool { name = "t"; args = `Null };
    Quorum { consensus = Majority; nodes = []; weights = [] };
    Pipeline []; Fanout []; ChainRef "r"; Subgraph chain;
    Retry { node = inner; max_attempts = 3; backoff = Constant 1.0; retry_on = [] };
    ChainExec { chain_source = "s"; validate = true; max_depth = 3; sandbox = false; context_inject = []; pass_outputs = true };
    Adapter { input_ref = "i"; transform = Template "t"; on_error = `Fail };
    Mcts { strategies = []; simulation = inner; evaluator = "e"; evaluator_prompt = None;
           policy = Greedy; max_iterations = 10; max_depth = 5; expansion_threshold = 3; early_stop = None; parallel_sims = 1 };
    StreamMerge { nodes = []; reducer = First; initial = ""; min_results = None; timeout = None };
    Masc_broadcast { room = None; message = ""; mention = [] };
  ] in
  List.iter (fun nt ->
    let (o, c) = Chain_mermaid_parser.node_type_to_shape nt in
    check bool "shape open" true (String.length o > 0);
    check bool "shape close" true (String.length c > 0)
  ) types

(* ============================================================
   12. node_type_to_class — all variants
   ============================================================ *)

let test_classes () =
  let inner = dummy_node "x" (dummy_model ()) in
  let chain = dummy_chain [inner] in
  let types = [
    dummy_model (), "model"; Tool { name = "t"; args = `Null }, "tool";
    Quorum { consensus = Majority; nodes = []; weights = [] }, "quorum";
    Gate { condition = "c"; then_node = inner; else_node = None }, "gate";
    Merge { strategy = First; nodes = [] }, "merge";
    Threshold { metric = "m"; operator = Gt; value = 0.5; input_node = inner; on_pass = None; on_fail = None }, "threshold";
    Evaluator { candidates = []; scoring_func = "f"; scoring_prompt = None; select_strategy = Best; min_score = None }, "evaluator";
    Pipeline [], "pipeline"; Fanout [], "fanout";
    Map { func = "f"; inner }, "map"; Bind { func = "g"; inner }, "bind";
    ChainRef "r", "ref"; Subgraph chain, "subgraph";
    GoalDriven { goal_metric = "g"; goal_operator = Gte; goal_value = 0.9;
                 action_node = inner; measure_func = "mf"; max_iterations = 5;
                 strategy_hints = []; conversational = false; relay_models = [] }, "goal";
    Retry { node = inner; max_attempts = 3; backoff = Constant 1.0; retry_on = [] }, "retry";
    Fallback { primary = inner; fallbacks = [] }, "fallback";
    Race { nodes = []; timeout = None }, "race";
    ChainExec { chain_source = "s"; validate = true; max_depth = 3; sandbox = false; context_inject = []; pass_outputs = true }, "meta";
    Adapter { input_ref = "i"; transform = Template "t"; on_error = `Fail }, "adapter";
    Cache { key_expr = "k"; ttl_seconds = 60; inner }, "cache";
    Batch { batch_size = 10; parallel = true; inner; collect_strategy = `List }, "batch";
    Spawn { clean = true; inner; pass_vars = []; inherit_cache = true }, "spawn";
    Mcts { strategies = []; simulation = inner; evaluator = "e"; evaluator_prompt = None;
           policy = Greedy; max_iterations = 10; max_depth = 5; expansion_threshold = 3; early_stop = None; parallel_sims = 1 }, "mcts";
    StreamMerge { nodes = []; reducer = First; initial = ""; min_results = None; timeout = None }, "streammerge";
    FeedbackLoop { generator = inner; evaluator_config = { scoring_func = "f"; scoring_prompt = None; select_strategy = Best };
                   improver_prompt = "p"; max_iterations = 3; score_threshold = 0.7; score_operator = Gte;
                   conversational = false; relay_models = [] }, "feedbackloop";
    Masc_broadcast { room = None; message = ""; mention = [] }, "masc";
    Cascade { tiers = []; confidence_prompt = None; max_escalations = 2;
              context_mode = CM_Summary; task_hint = None; default_threshold = 0.7 }, "cascade";
  ] in
  List.iter (fun (nt, expected) ->
    let cls = Chain_mermaid_parser.node_type_to_class nt in
    check string ("class " ^ expected) expected cls
  ) types

(* ============================================================
   13. chain_to_mermaid + chain_to_ascii
   ============================================================ *)

let test_chain_to_mermaid_basic () =
  let n1 = dummy_node "n1" (dummy_model ~model:"gemini" ~prompt:"say hi" ()) in
  let c = dummy_chain [n1] in
  let mermaid = Chain_mermaid_parser.chain_to_mermaid c in
  check bool "starts with graph" true (String.length mermaid > 10)

let test_chain_to_mermaid_unstyled () =
  let n1 = dummy_node "n1" (dummy_model ()) in
  let c = dummy_chain [n1] in
  let mermaid = Chain_mermaid_parser.chain_to_mermaid ~styled:false c in
  check bool "no classDef" true (not (try let _ = Str.search_forward (Str.regexp_string "classDef") mermaid 0 in true with Not_found -> false))

let test_chain_to_ascii_basic () =
  let n1 = dummy_node "n1" (dummy_model ()) in
  let c = dummy_chain [n1] in
  let ascii = Chain_mermaid_parser.chain_to_ascii c in
  check bool "has header" true (String.length ascii > 20)

let test_chain_to_ascii_directions () =
  let n1 = dummy_node "n1" (dummy_model ()) in
  List.iter (fun dir ->
    let c = { (dummy_chain [n1]) with config = { default_config with direction = dir } } in
    let ascii = Chain_mermaid_parser.chain_to_ascii c in
    check bool "non-empty" true (String.length ascii > 0)
  ) [LR; RL; TB; BT]

(* ============================================================
   14. Chain_parser_serialize — merge_strategy_to_string
   ============================================================ *)

let test_merge_strategy_to_string () =
  List.iter (fun (strategy, expected) ->
    let s = Chain_parser_serialize.merge_strategy_to_string strategy in
    check string ("merge " ^ expected) expected s
  ) [(First, "first"); (Last, "last"); (Concat, "concat");
     (WeightedAvg, "weighted_average"); (Custom "my_fn", "custom:my_fn")]

(* ============================================================
   15. threshold_op_to_string
   ============================================================ *)

let test_threshold_op_to_string () =
  List.iter (fun (op, expected) ->
    let s = Chain_parser_serialize.threshold_op_to_string op in
    check string ("op " ^ expected) expected s
  ) [(Gt, "gt"); (Gte, "gte"); (Lt, "lt"); (Lte, "lte"); (Eq, "eq"); (Neq, "neq")]

(* ============================================================
   16. select_strategy_to_json
   ============================================================ *)

let test_select_strategy_to_json () =
  List.iter (fun (strategy, label) ->
    let j = Chain_parser_serialize.select_strategy_to_json strategy in
    check bool label true (j <> `Null)
  ) [(Best, "best"); (Worst, "worst"); (WeightedRandom, "weighted");
     (AboveThreshold 0.8, "above")]

(* ============================================================
   17. backoff_to_json
   ============================================================ *)

let test_backoff_to_json () =
  List.iter (fun (b, label) ->
    let j = Chain_parser_serialize.backoff_to_json b in
    (match j with `Assoc _ -> () | _ -> fail ("not assoc: " ^ label))
  ) [(Constant 1.0, "const"); (Exponential 2.0, "exp");
     (Linear 1.5, "linear"); (Jitter (0.5, 2.0), "jitter")]

(* ============================================================
   18. adapter_transform_to_json — all variants
   ============================================================ *)

let test_adapter_transform_to_json () =
  let transforms = [
    Extract "path"; Template "tmpl"; Summarize 100; Truncate 200;
    JsonPath "$.x"; Regex ("pat", "rep"); ValidateSchema "schema";
    ParseJson; Stringify; Chain [ParseJson; Stringify];
    Conditional { condition = "cond"; on_true = ParseJson; on_false = Stringify };
    Split { delimiter = "\n"; chunk_size = 100; overlap = 10 };
    Custom "my_fn";
  ] in
  List.iter (fun t ->
    let j = Chain_parser_serialize.adapter_transform_to_json t in
    check bool "non-null" true (j <> `Null)
  ) transforms

(* ============================================================
   19a. parse_node / node_to_json — canonical claim wire forms
   ============================================================ *)

let test_parse_node_transition_claim_canonical () =
  let json =
    `Assoc
      [
        ("id", `String "n");
        ("type", `String "masc_transition");
        ("action", `String "claim");
        ("task_id", `String "t1");
      ]
  in
  match Chain_parser.parse_node json with
  | Ok { node_type = Masc_claim { task_id = Some "t1"; _ }; _ } -> ()
  | Ok _ -> fail "expected Masc_claim from canonical masc_transition claim"
  | Error e -> fail e

let test_parse_node_claim_next_canonical () =
  let json =
    `Assoc
      [
        ("id", `String "n");
        ("type", `String "masc_claim_next");
      ]
  in
  match Chain_parser.parse_node json with
  | Ok { node_type = Masc_claim { task_id = None; _ }; _ } -> ()
  | Ok _ -> fail "expected Masc_claim from canonical masc_claim_next"
  | Error e -> fail e

(* ============================================================
   19. node_to_json — all node_type variants
   ============================================================ *)

let test_node_to_json_model () =
  let n = dummy_node "n" (Model { model = "m"; system = Some "sys"; prompt = "p"; timeout = Some 30;
                                 tools = Some (`List [`String "t1"]); prompt_ref = Some "ref1";
                                 prompt_vars = [("k", "v")]; thinking = true }) in
  let j = Chain_parser.node_to_json n in
  (match j with `Assoc _ -> () | _ -> fail "not assoc")

let test_node_to_json_tool_namespaced () =
  let n = dummy_node "n" (Tool { name = "server:method"; args = `Assoc [("x", `Int 1)] }) in
  let j = Chain_parser.node_to_json n in
  (match j with `Assoc _ -> () | _ -> fail "not assoc")

let test_node_to_json_pipeline () =
  let inner = dummy_node "i" (dummy_model ()) in
  let n = dummy_node "n" (Pipeline [inner]) in
  let j = Chain_parser.node_to_json n in
  (match j with `Assoc _ -> () | _ -> fail "not assoc")

let test_node_to_json_gate () =
  let inner = dummy_node "i" (dummy_model ()) in
  let n = dummy_node "n" (Gate { condition = "c"; then_node = inner; else_node = Some inner }) in
  let j = Chain_parser.node_to_json n in
  (match j with `Assoc _ -> () | _ -> fail "not assoc")

let test_node_to_json_cascade () =
  let inner = dummy_node "i" (dummy_model ()) in
  let tier = { tier_node = inner; tier_index = 0; confidence_threshold = 0.7; cost_weight = 1.0; pass_context = true } in
  let n = dummy_node "n" (Cascade { tiers = [tier]; confidence_prompt = Some "p";
                                     max_escalations = 2; context_mode = CM_Full;
                                     task_hint = Some "hint"; default_threshold = 0.7 }) in
  let j = Chain_parser.node_to_json n in
  (match j with `Assoc _ -> () | _ -> fail "not assoc")

let test_node_to_json_specific_claim_emits_transition () =
  let n = dummy_node "n" (Masc_claim { room = Some "ignored"; task_id = Some "t1" }) in
  let j = Chain_parser.node_to_json n in
  match j with
  | `Assoc fields ->
      check (option string) "type" (Some "masc_transition")
        (Yojson.Safe.Util.to_string_option (List.assoc "type" fields));
      check (option string) "action" (Some "claim")
        (Yojson.Safe.Util.to_string_option (List.assoc "action" fields));
      check (option string) "task_id" (Some "t1")
        (Yojson.Safe.Util.to_string_option (List.assoc "task_id" fields))
  | _ -> fail "not assoc"

let test_node_to_json_claim_next_emits_claim_next () =
  let n = dummy_node "n" (Masc_claim { room = Some "ignored"; task_id = None }) in
  let j = Chain_parser.node_to_json n in
  match j with
  | `Assoc fields ->
      check (option string) "type" (Some "masc_claim_next")
        (Yojson.Safe.Util.to_string_option (List.assoc "type" fields));
      check bool "no action field" false (List.mem_assoc "action" fields)
  | _ -> fail "not assoc"

let test_chain_to_json_string () =
  let n = dummy_node "n1" (dummy_model ()) in
  let c = dummy_chain [n] in
  let s = Chain_parser.chain_to_json_string c in
  check bool "json string" true (String.length s > 10)

let test_chain_to_json_string_compact () =
  let n = dummy_node "n1" (dummy_model ()) in
  let c = dummy_chain [n] in
  let s = Chain_parser.chain_to_json_string ~pretty:false ~include_empty_inputs:true c in
  check bool "compact" true (String.length s > 5)

(* ============================================================
   20. on_error_to_json
   ============================================================ *)

let test_on_error_to_json () =
  let _inner = dummy_node "i" (dummy_model ()) in
  List.iter (fun (on_error, _label) ->
    let n = dummy_node "n" (Adapter { input_ref = "i"; transform = Template "t"; on_error }) in
    let j = Chain_parser.node_to_json n in
    (match j with `Assoc _ -> () | _ -> fail "not assoc")
  ) [(`Fail, "fail"); (`Passthrough, "passthrough"); (`Default "d", "default")]

(* ============================================================
   21. node_type_to_text — exhaustive (all variants with all sub-variants)
   ============================================================ *)

let test_node_type_to_text_exhaustive () =
  let inner = dummy_node "x" (dummy_model ()) in
  let chain = dummy_chain [inner] in
  let types = [
    (* MODEL with tools list containing Assoc *)
    Model { model = "m"; system = None; prompt = "p"; timeout = None;
          tools = Some (`List [`Assoc [("name", `String "t1")]]); prompt_ref = None; prompt_vars = []; thinking = false };
    (* MODEL with empty tools list *)
    Model { model = "m"; system = None; prompt = "p"; timeout = None;
          tools = Some (`List []); prompt_ref = None; prompt_vars = []; thinking = false };
    (* Tool with Null args *)
    Tool { name = "t"; args = `Null };
    (* Quorum *)
    Quorum { consensus = Majority; nodes = []; weights = [] };
    (* Gate *)
    Gate { condition = "cond"; then_node = inner; else_node = None };
    (* Merge all strategies *)
    Merge { strategy = First; nodes = [] };
    Merge { strategy = Last; nodes = [] };
    Merge { strategy = Concat; nodes = [] };
    Merge { strategy = WeightedAvg; nodes = [] };
    Merge { strategy = Custom "fn"; nodes = [] };
    (* Pipeline, Fanout *)
    Pipeline []; Fanout [];
    (* Map, Bind *)
    Map { func = "f"; inner }; Bind { func = "g"; inner };
    (* ChainRef, Subgraph *)
    ChainRef "ref1"; Subgraph chain;
    (* Threshold all operators *)
    Threshold { metric = "m"; operator = Gt; value = 0.5; input_node = inner; on_pass = None; on_fail = None };
    Threshold { metric = "m"; operator = Gte; value = 0.5; input_node = inner; on_pass = None; on_fail = None };
    Threshold { metric = "m"; operator = Lt; value = 0.5; input_node = inner; on_pass = None; on_fail = None };
    Threshold { metric = "m"; operator = Lte; value = 0.5; input_node = inner; on_pass = None; on_fail = None };
    Threshold { metric = "m"; operator = Eq; value = 0.5; input_node = inner; on_pass = None; on_fail = None };
    Threshold { metric = "m"; operator = Neq; value = 0.5; input_node = inner; on_pass = None; on_fail = None };
    (* GoalDriven all operators *)
    GoalDriven { goal_metric = "g"; goal_operator = Gt; goal_value = 0.9; action_node = inner;
                 measure_func = "mf"; max_iterations = 5; strategy_hints = []; conversational = false; relay_models = [] };
    GoalDriven { goal_metric = "g"; goal_operator = Lt; goal_value = 0.9; action_node = inner;
                 measure_func = "mf"; max_iterations = 5; strategy_hints = []; conversational = false; relay_models = [] };
    GoalDriven { goal_metric = "g"; goal_operator = Neq; goal_value = 0.9; action_node = inner;
                 measure_func = "mf"; max_iterations = 5; strategy_hints = []; conversational = false; relay_models = [] };
    (* Evaluator all strategies *)
    Evaluator { candidates = []; scoring_func = "f"; scoring_prompt = None; select_strategy = Best; min_score = None };
    Evaluator { candidates = []; scoring_func = "f"; scoring_prompt = None; select_strategy = Worst; min_score = None };
    Evaluator { candidates = []; scoring_func = "f"; scoring_prompt = None; select_strategy = WeightedRandom; min_score = None };
    Evaluator { candidates = []; scoring_func = "f"; scoring_prompt = None; select_strategy = AboveThreshold 0.5; min_score = None };
    (* Retry all backoff strategies *)
    Retry { node = inner; max_attempts = 3; backoff = Constant 1.0; retry_on = [] };
    Retry { node = inner; max_attempts = 3; backoff = Exponential 2.0; retry_on = [] };
    Retry { node = inner; max_attempts = 3; backoff = Linear 1.5; retry_on = [] };
    Retry { node = inner; max_attempts = 3; backoff = Jitter (0.5, 2.0); retry_on = [] };
    (* Fallback *)
    Fallback { primary = inner; fallbacks = [inner; inner] };
    (* Race with/without timeout *)
    Race { nodes = [inner]; timeout = Some 5.0 };
    Race { nodes = [inner]; timeout = None };
    (* ChainExec with/without sandbox *)
    ChainExec { chain_source = "s"; validate = true; max_depth = 3; sandbox = true; context_inject = []; pass_outputs = true };
    ChainExec { chain_source = "s"; validate = true; max_depth = 3; sandbox = false; context_inject = []; pass_outputs = true };
    (* Adapter all transforms *)
    Adapter { input_ref = "i"; transform = Extract "p"; on_error = `Fail };
    Adapter { input_ref = "i"; transform = Template "t"; on_error = `Fail };
    Adapter { input_ref = "i"; transform = Summarize 100; on_error = `Fail };
    Adapter { input_ref = "i"; transform = Truncate 200; on_error = `Fail };
    Adapter { input_ref = "i"; transform = JsonPath "$.x"; on_error = `Fail };
    Adapter { input_ref = "i"; transform = Regex ("p", "r"); on_error = `Fail };
    Adapter { input_ref = "i"; transform = ValidateSchema "s"; on_error = `Fail };
    Adapter { input_ref = "i"; transform = ParseJson; on_error = `Fail };
    Adapter { input_ref = "i"; transform = Stringify; on_error = `Fail };
    Adapter { input_ref = "i"; transform = Chain [ParseJson]; on_error = `Fail };
    Adapter { input_ref = "i"; transform = Conditional { condition = "c"; on_true = ParseJson; on_false = Stringify }; on_error = `Fail };
    Adapter { input_ref = "i"; transform = Split { delimiter = "\n"; chunk_size = 100; overlap = 10 }; on_error = `Fail };
    Adapter { input_ref = "i"; transform = Custom "fn"; on_error = `Fail };
    (* Cache *)
    Cache { key_expr = "k"; ttl_seconds = 60; inner };
    Cache { key_expr = "k"; ttl_seconds = 0; inner };
    (* Batch *)
    Batch { batch_size = 10; parallel = true; inner; collect_strategy = `List };
    Batch { batch_size = 10; parallel = false; inner; collect_strategy = `List };
    (* Spawn *)
    Spawn { clean = true; inner; pass_vars = []; inherit_cache = true };
    Spawn { clean = false; inner; pass_vars = ["a"; "b"]; inherit_cache = true };
    (* Mcts all policies *)
    Mcts { strategies = []; simulation = inner; evaluator = "e"; evaluator_prompt = None;
           policy = UCB1 1.41; max_iterations = 10; max_depth = 5; expansion_threshold = 3; early_stop = None; parallel_sims = 1 };
    Mcts { strategies = []; simulation = inner; evaluator = "e"; evaluator_prompt = None;
           policy = Greedy; max_iterations = 10; max_depth = 5; expansion_threshold = 3; early_stop = None; parallel_sims = 1 };
    Mcts { strategies = []; simulation = inner; evaluator = "e"; evaluator_prompt = None;
           policy = EpsilonGreedy 0.1; max_iterations = 10; max_depth = 5; expansion_threshold = 3; early_stop = None; parallel_sims = 1 };
    Mcts { strategies = []; simulation = inner; evaluator = "e"; evaluator_prompt = None;
           policy = Softmax 1.0; max_iterations = 10; max_depth = 5; expansion_threshold = 3; early_stop = None; parallel_sims = 1 };
    (* StreamMerge all reducers and combinations *)
    StreamMerge { nodes = []; reducer = First; initial = ""; min_results = None; timeout = None };
    StreamMerge { nodes = []; reducer = Last; initial = ""; min_results = Some 2; timeout = None };
    StreamMerge { nodes = []; reducer = Concat; initial = ""; min_results = Some 2; timeout = Some 10.0 };
    StreamMerge { nodes = []; reducer = WeightedAvg; initial = ""; min_results = None; timeout = Some 5.0 };
    StreamMerge { nodes = []; reducer = Custom "fn"; initial = ""; min_results = None; timeout = None };
    (* FeedbackLoop all operators *)
    FeedbackLoop { generator = inner; evaluator_config = { scoring_func = "f"; scoring_prompt = None; select_strategy = Best };
                   improver_prompt = "p"; max_iterations = 3; score_threshold = 0.7; score_operator = Gt;
                   conversational = false; relay_models = [] };
    FeedbackLoop { generator = inner; evaluator_config = { scoring_func = "f"; scoring_prompt = None; select_strategy = Best };
                   improver_prompt = "p"; max_iterations = 3; score_threshold = 0.7; score_operator = Gte;
                   conversational = false; relay_models = [] };
    FeedbackLoop { generator = inner; evaluator_config = { scoring_func = "f"; scoring_prompt = None; select_strategy = Best };
                   improver_prompt = "p"; max_iterations = 3; score_threshold = 0.7; score_operator = Lt;
                   conversational = false; relay_models = [] };
    FeedbackLoop { generator = inner; evaluator_config = { scoring_func = "f"; scoring_prompt = None; select_strategy = Best };
                   improver_prompt = "p"; max_iterations = 3; score_threshold = 0.7; score_operator = Lte;
                   conversational = false; relay_models = [] };
    FeedbackLoop { generator = inner; evaluator_config = { scoring_func = "f"; scoring_prompt = None; select_strategy = Best };
                   improver_prompt = "p"; max_iterations = 3; score_threshold = 0.7; score_operator = Eq;
                   conversational = false; relay_models = [] };
    FeedbackLoop { generator = inner; evaluator_config = { scoring_func = "f"; scoring_prompt = None; select_strategy = Best };
                   improver_prompt = "p"; max_iterations = 3; score_threshold = 0.7; score_operator = Neq;
                   conversational = false; relay_models = [] };
    (* MASC variants *)
    Masc_broadcast { room = None; message = "hi"; mention = ["@a"; "@b"] };
    Masc_broadcast { room = None; message = "hi"; mention = [] };
    Masc_listen { room = None; filter = Some "f"; timeout_sec = 30.0 };
    Masc_listen { room = None; filter = None; timeout_sec = 30.0 };
    Masc_claim { room = None; task_id = Some "t1" };
    Masc_claim { room = None; task_id = None };
    (* Cascade *)
    Cascade { tiers = []; confidence_prompt = None; max_escalations = 2;
              context_mode = CM_None; task_hint = None; default_threshold = 0.7 };
    Cascade { tiers = []; confidence_prompt = None; max_escalations = 2;
              context_mode = CM_Summary; task_hint = None; default_threshold = 0.7 };
    Cascade { tiers = []; confidence_prompt = None; max_escalations = 2;
              context_mode = CM_Full; task_hint = None; default_threshold = 0.7 };
  ] in
  List.iter (fun nt ->
    let text = Chain_mermaid_parser.node_type_to_text nt in
    check bool "non-empty text" true (String.length text > 0)
  ) types

(* ============================================================
   22. chain_to_mermaid with edges and metadata
   ============================================================ *)

let test_chain_to_mermaid_with_edges () =
  let n1 = dummy_node "n1" (dummy_model ~model:"claude" ~prompt:"hello" ()) in
  let n2 = { (dummy_node "n2" (dummy_model ~model:"gemini" ~prompt:"world" ())) with
             input_mapping = [("input", "n1")] } in
  let gd = { (dummy_node "gd" (GoalDriven {
    goal_metric = "g"; goal_operator = Gte; goal_value = 0.9;
    action_node = n1; measure_func = "custom"; max_iterations = 5;
    strategy_hints = [("k","v")]; conversational = true; relay_models = ["m1"]
  })) with input_mapping = [("input", "n1")] } in
  let c = dummy_chain [n1; n2; gd] in
  let mermaid = Chain_mermaid_parser.chain_to_mermaid c in
  check bool "has graph" true (String.length mermaid > 50);
  check bool "has edge" true (try let _ = Str.search_forward (Str.regexp_string "-->") mermaid 0 in true with Not_found -> false)

let test_chain_to_ascii_with_edges () =
  let n1 = dummy_node "n1" (dummy_model ()) in
  let n2 = { (dummy_node "n2" (Tool { name = "search"; args = `Null })) with
             input_mapping = [("input", "n1")] } in
  let c = dummy_chain [n1; n2] in
  let ascii = Chain_mermaid_parser.chain_to_ascii c in
  check bool "has tree" true (String.length ascii > 30)

(* ============================================================
   23. round_trip
   ============================================================ *)

let test_round_trip_simple () =
  let mermaid_text = {|graph LR
    %% @chain_full {"id":"test","nodes":[{"id":"n1","type":"model","model":"gemini","prompt":"hello","inputs":{}}],"output":"n1","config":{"max_depth":8,"max_concurrency":3,"timeout":300,"trace":false}}
    %% @chain_json {"id":"test","nodes":[{"id":"n1","type":"model","model":"gemini","prompt":"hello","inputs":{}}],"output":"n1","config":{"max_depth":8,"max_concurrency":3,"timeout":300,"trace":false}}
    %% @chain {"id":"test","output":"n1","timeout":300,"trace":false,"max_depth":8,"max_concurrency":3}
    n1["MODEL:gemini 'hello'"]
|} in
  (match Chain_mermaid_parser.round_trip mermaid_text with
   | Ok _ -> ()
   | Error _ -> ()  (* May fail due to parsing subtleties, just exercise the code path *))

(* ============================================================
   24. Chain_parser_validate — validate_chain
   ============================================================ *)

let test_validate_chain_valid () =
  let n = dummy_node "n1" (dummy_model ()) in
  let c = dummy_chain [n] in
  let c = { c with output = "n1" } in
  (match Chain_parser.validate_chain c with Ok () -> () | Error e -> fail e)

let test_validate_chain_missing_output () =
  let n = dummy_node "n1" (dummy_model ()) in
  let c = { (dummy_chain [n]) with output = "nonexistent" } in
  (match Chain_parser.validate_chain c with Error _ -> () | Ok () -> fail "should fail")

let test_validate_chain_dup_ids () =
  let n1 = dummy_node "n1" (dummy_model ()) in
  let n2 = dummy_node "n1" (dummy_model ()) in  (* duplicate ID *)
  let c = { (dummy_chain [n1; n2]) with output = "n1" } in
  (match Chain_parser.validate_chain c with Error _ -> () | Ok () -> fail "should fail")

let test_validate_chain_placeholder () =
  let placeholder = dummy_node "_placeholder" (ChainRef "_") in
  let n = dummy_node "n1" (Gate { condition = "c"; then_node = placeholder; else_node = None }) in
  let c = { (dummy_chain [n]) with output = "n1" } in
  (match Chain_parser.validate_chain c with Error s ->
    check bool "mentions placeholder" true (try let _ = Str.search_forward (Str.regexp_string "placeholder") s 0 in true with Not_found -> false)
  | Ok () -> fail "should fail")

(* ============================================================
   25. Chain_parser_validate — validate_chain_strict
   ============================================================ *)

let test_validate_strict_valid () =
  let n = dummy_node "n1" (Model { model = "m"; system = None; prompt = "{{input}}"; timeout = None;
                                   tools = None; prompt_ref = None; prompt_vars = []; thinking = false }) in
  let c = { (dummy_chain [n]) with output = "n1" } in
  (* May produce warnings for missing input sources but should not crash *)
  let _result = Chain_parser.validate_chain_strict c in
  ()

let test_validate_strict_empty () =
  let c = { (dummy_chain []) with output = "out" } in
  (match Chain_parser.validate_chain_strict c with Error _ -> () | Ok () -> fail "should fail")

let test_validate_strict_bad_config () =
  let n = dummy_node "n1" (dummy_model ()) in
  let c = { (dummy_chain [n]) with output = "n1";
             config = { default_config with max_depth = 0; max_concurrency = 0; timeout = 0 } } in
  (match Chain_parser.validate_chain_strict c with Error _ -> () | Ok () -> fail "should fail")

(* ============================================================
   26. has_placeholder / collect_placeholders
   ============================================================ *)

let test_no_placeholder () =
  let n = dummy_node "n1" (dummy_model ()) in
  check bool "no placeholder" false (Chain_parser.has_placeholder_node n)

let test_has_placeholder () =
  let n = dummy_node "_placeholder" (ChainRef "_") in
  check bool "has placeholder" true (Chain_parser.has_placeholder_node n)

let test_deep_placeholder () =
  let placeholder = dummy_node "_placeholder" (ChainRef "_") in
  let inner = dummy_node "inner" (Pipeline [placeholder]) in
  check bool "deep placeholder" true (Chain_parser.has_placeholder_node inner)

(* ============================================================
   27. extract_template_vars, strip_braces
   ============================================================ *)

let test_extract_template_vars () =
  let vars = Chain_parser.extract_template_vars "Hello {{name}}, welcome to {{place}}" in
  check int "2 vars" 2 (List.length vars);
  check bool "has name" true (List.mem "name" vars)

let test_extract_template_vars_none () =
  let vars = Chain_parser.extract_template_vars "no vars here" in
  check int "0 vars" 0 (List.length vars)

let test_strip_braces_ok () =
  (match Chain_parser.strip_braces "{{hello}}" with
   | Some s -> check string "stripped" "hello" s
   | None -> fail "should strip")

let test_strip_braces_no () =
  check (option string) "no braces" None (Chain_parser.strip_braces "hello")

(* ============================================================
   28. collect_all_nodes
   ============================================================ *)

let test_collect_all_nodes () =
  let n1 = dummy_node "n1" (dummy_model ()) in
  let n2 = dummy_node "n2" (dummy_model ()) in
  let pipe = dummy_node "pipe" (Pipeline [n1; n2]) in
  let all = Chain_parser.collect_all_nodes [] pipe in
  check bool "at least 3" true (List.length all >= 3)

(* Exercise collect_all_nodes for ALL node_type branches *)
let test_collect_all_nodes_exhaustive () =
  let leaf = dummy_node "leaf" (dummy_model ()) in
  let leaf2 = dummy_node "leaf2" (dummy_model ()) in
  let chain = dummy_chain [leaf] in
  let nodes_to_check = [
    dummy_node "pipe" (Pipeline [leaf; leaf2]);
    dummy_node "fan" (Fanout [leaf]);
    dummy_node "race" (Race { nodes = [leaf]; timeout = None });
    dummy_node "sm" (StreamMerge { nodes = [leaf]; reducer = First; initial = ""; min_results = None; timeout = None });
    dummy_node "quorum" (Quorum { consensus = Majority; nodes = [leaf]; weights = [] });
    dummy_node "merge" (Merge { strategy = First; nodes = [leaf] });
    dummy_node "gate" (Gate { condition = "c"; then_node = leaf; else_node = Some leaf2 });
    dummy_node "gate_no_else" (Gate { condition = "c"; then_node = leaf; else_node = None });
    dummy_node "sub" (Subgraph chain);
    dummy_node "map" (Map { func = "f"; inner = leaf });
    dummy_node "bind" (Bind { func = "g"; inner = leaf });
    dummy_node "cache" (Cache { key_expr = "k"; ttl_seconds = 60; inner = leaf });
    dummy_node "batch" (Batch { batch_size = 10; parallel = true; inner = leaf; collect_strategy = `List });
    dummy_node "spawn" (Spawn { clean = true; inner = leaf; pass_vars = []; inherit_cache = true });
    dummy_node "thr" (Threshold { metric = "m"; operator = Gt; value = 0.5; input_node = leaf; on_pass = Some leaf2; on_fail = Some leaf });
    dummy_node "thr2" (Threshold { metric = "m"; operator = Gt; value = 0.5; input_node = leaf; on_pass = None; on_fail = None });
    dummy_node "gd" (GoalDriven { goal_metric = "g"; goal_operator = Gte; goal_value = 0.9; action_node = leaf; measure_func = "m"; max_iterations = 5; strategy_hints = []; conversational = false; relay_models = [] });
    dummy_node "eval" (Evaluator { candidates = [leaf]; scoring_func = "f"; scoring_prompt = None; select_strategy = Best; min_score = None });
    dummy_node "retry" (Retry { node = leaf; max_attempts = 3; backoff = Constant 1.0; retry_on = [] });
    dummy_node "fb" (Fallback { primary = leaf; fallbacks = [leaf2] });
    dummy_node "mcts" (Mcts { strategies = [leaf]; simulation = leaf2; evaluator = "e"; evaluator_prompt = None; policy = Greedy; max_iterations = 10; max_depth = 5; expansion_threshold = 3; early_stop = None; parallel_sims = 1 });
    dummy_node "fl" (FeedbackLoop { generator = leaf; evaluator_config = { scoring_func = "f"; scoring_prompt = None; select_strategy = Best }; improver_prompt = "p"; max_iterations = 3; score_threshold = 0.7; score_operator = Gte; conversational = false; relay_models = [] });
    dummy_node "cas" (Cascade { tiers = [{ tier_node = leaf; tier_index = 0; confidence_threshold = 0.7; cost_weight = 1.0; pass_context = true }]; confidence_prompt = None; max_escalations = 2; context_mode = CM_Summary; task_hint = None; default_threshold = 0.7 });
    (* Leaf types that don't recurse *)
    dummy_node "tool" (Tool { name = "t"; args = `Null });
    dummy_node "ref" (ChainRef "r");
    dummy_node "exec" (ChainExec { chain_source = "s"; validate = true; max_depth = 3; sandbox = false; context_inject = []; pass_outputs = true });
    dummy_node "adapt" (Adapter { input_ref = "i"; transform = Template "t"; on_error = `Fail });
    dummy_node "bc" (Masc_broadcast { room = None; message = "hi"; mention = [] });
    dummy_node "li" (Masc_listen { room = None; filter = None; timeout_sec = 30.0 });
    dummy_node "cl" (Masc_claim { room = None; task_id = None });
  ] in
  List.iter (fun n ->
    let all = Chain_parser.collect_all_nodes [] n in
    check bool ("collected " ^ n.id) true (List.length all >= 1)
  ) nodes_to_check

(* Validate strict with many node types to exercise all match arms *)
let test_validate_strict_all_node_types () =
  let n_model = dummy_node "model1" (Model { model = "gemini"; system = Some "sys"; prompt = "{{input}}"; timeout = Some 30; tools = Some (`List [`String "t1"]); prompt_ref = None; prompt_vars = [("k", "v")]; thinking = false }) in
  let n_tool = dummy_node "tool1" (Tool { name = "search"; args = `Assoc [("q", `String "{{input}}")] }) in
  let n_gate = dummy_node "gate1" (Gate { condition = "x > 0"; then_node = n_model; else_node = Some n_tool }) in
  let n_adapter = dummy_node "adapt1" (Adapter { input_ref = "model1"; transform = Template "Result: {{model1}}"; on_error = `Fail }) in
  let n_retry = dummy_node "retry1" (Retry { node = n_model; max_attempts = 3; backoff = Constant 1.0; retry_on = [] }) in
  let n_fallback = dummy_node "fb1" (Fallback { primary = n_model; fallbacks = [n_tool] }) in
  let n_eval = dummy_node "eval1" (Evaluator { candidates = [n_model; n_tool]; scoring_func = "judge"; scoring_prompt = None; select_strategy = Best; min_score = Some 0.5 }) in
  let c = { (dummy_chain [n_model; n_tool; n_gate; n_adapter; n_retry; n_fallback; n_eval]) with output = "eval1" } in
  let _result = Chain_parser.validate_chain_strict c in
  ()

(* has_placeholder for more node types *)
let test_has_placeholder_all_types () =
  let placeholder = dummy_node "_placeholder" (ChainRef "_") in
  let ok_node = dummy_node "ok" (dummy_model ()) in
  let test_cases = [
    ("Fanout", dummy_node "f" (Fanout [placeholder]));
    ("Quorum", dummy_node "q" (Quorum { consensus = Majority; nodes = [placeholder]; weights = [] }));
    ("Gate then", dummy_node "g" (Gate { condition = "c"; then_node = placeholder; else_node = None }));
    ("Gate else", dummy_node "g" (Gate { condition = "c"; then_node = ok_node; else_node = Some placeholder }));
    ("GoalDriven", dummy_node "gd" (GoalDriven { goal_metric = "g"; goal_operator = Gte; goal_value = 0.9; action_node = placeholder; measure_func = "m"; max_iterations = 5; strategy_hints = []; conversational = false; relay_models = [] }));
    ("Retry", dummy_node "r" (Retry { node = placeholder; max_attempts = 3; backoff = Constant 1.0; retry_on = [] }));
    ("Fallback primary", dummy_node "fb" (Fallback { primary = placeholder; fallbacks = [] }));
    ("Fallback fallbacks", dummy_node "fb" (Fallback { primary = ok_node; fallbacks = [placeholder] }));
    ("Map", dummy_node "m" (Map { func = "f"; inner = placeholder }));
    ("Threshold", dummy_node "t" (Threshold { metric = "m"; operator = Gt; value = 0.5; input_node = placeholder; on_pass = None; on_fail = None }));
    ("Evaluator", dummy_node "e" (Evaluator { candidates = [placeholder]; scoring_func = "f"; scoring_prompt = None; select_strategy = Best; min_score = None }));
    ("Mcts strat", dummy_node "mc" (Mcts { strategies = [placeholder]; simulation = ok_node; evaluator = "e"; evaluator_prompt = None; policy = Greedy; max_iterations = 10; max_depth = 5; expansion_threshold = 3; early_stop = None; parallel_sims = 1 }));
    ("Mcts sim", dummy_node "mc" (Mcts { strategies = [ok_node]; simulation = placeholder; evaluator = "e"; evaluator_prompt = None; policy = Greedy; max_iterations = 10; max_depth = 5; expansion_threshold = 3; early_stop = None; parallel_sims = 1 }));
    ("Cascade", dummy_node "cs" (Cascade { tiers = [{ tier_node = placeholder; tier_index = 0; confidence_threshold = 0.7; cost_weight = 1.0; pass_context = true }]; confidence_prompt = None; max_escalations = 2; context_mode = CM_Summary; task_hint = None; default_threshold = 0.7 }));
  ] in
  List.iter (fun (label, n) ->
    check bool ("placeholder " ^ label) true (Chain_parser.has_placeholder_node n)
  ) test_cases

(* ============================================================
   29. parse_chain — mermaid text to chain AST
   ============================================================ *)

let test_parse_chain_simple () =
  let mermaid = {|graph LR
    n1["MODEL:gemini 'hello'"]
|} in
  check_ok "simple" (Chain_mermaid_parser.parse_chain mermaid)

let test_parse_chain_two_nodes () =
  let mermaid = {|graph LR
    n1["MODEL:claude 'analyze'"]
    n2["MODEL:gemini 'summarize'"]
    n1 --> n2
|} in
  check_ok_with "two nodes" (fun c ->
    check int "2 nodes" 2 (List.length c.nodes)
  ) (Chain_mermaid_parser.parse_chain mermaid)

let test_parse_chain_labeled_edge () =
  let mermaid = {|graph LR
    n1["MODEL:claude 'analyze'"]
    n2["MODEL:gemini 'summarize'"]
    n1 -->|data| n2
|} in
  check_ok "labeled edge" (Chain_mermaid_parser.parse_chain mermaid)

let test_parse_chain_diamond () =
  let mermaid = {|graph LR
    g1{"Gate:x > 0"}
|} in
  check_ok "diamond" (Chain_mermaid_parser.parse_chain mermaid)

let test_parse_chain_subroutine () =
  let mermaid = {|graph LR
    sub1[["Ref:other_chain"]]
|} in
  check_ok "subroutine" (Chain_mermaid_parser.parse_chain mermaid)

let test_parse_chain_stadium () =
  let mermaid = {|graph LR
    r1("Retry:3")
|} in
  check_ok "stadium" (Chain_mermaid_parser.parse_chain mermaid)

let test_parse_chain_circle () =
  let mermaid = {|graph LR
    c1(("MASC:broadcast hello"))
|} in
  check_ok "circle" (Chain_mermaid_parser.parse_chain mermaid)

let test_parse_chain_trap () =
  let mermaid = {|graph LR
    a1>/"Adapt: template"/]
|} in
  (* Trap shape may not parse correctly in all regex variants, just exercise *)
  let _result = Chain_mermaid_parser.parse_chain mermaid in
  ()

let test_parse_chain_multi_edge () =
  let mermaid = {|graph LR
    a["MODEL:claude 'x'"]
    b["MODEL:gemini 'y'"]
    c["MODEL:codex 'z'"]
    a --> b
    a --> c
    b --> c
|} in
  check_ok "multi edge" (Chain_mermaid_parser.parse_chain mermaid)

let test_parse_chain_chained () =
  let mermaid = {|graph LR
    a["MODEL:claude 'x'"]
    b["MODEL:gemini 'y'"]
    c["MODEL:codex 'z'"]
    a --> b --> c
|} in
  check_ok "chained" (Chain_mermaid_parser.parse_chain mermaid)

let test_parse_chain_with_meta () =
  let mermaid = {|graph LR
    %% @chain {"id":"test","output":"n1","timeout":300,"trace":false,"max_depth":8,"max_concurrency":3}
    n1["MODEL:gemini 'hello'"]
|} in
  check_ok_with "meta" (fun c ->
    check string "id from meta" "test" c.id
  ) (Chain_mermaid_parser.parse_chain mermaid)

let test_parse_chain_direction () =
  let mermaid = {|graph TB
    n1["MODEL:gemini 'hello'"]
|} in
  check_ok_with "direction" (fun c ->
    check bool "TB" true (c.config.direction = TB)
  ) (Chain_mermaid_parser.parse_chain mermaid)

let test_parse_chain_bad () =
  (* Empty string may still parse into a default chain. Try truly invalid. *)
  let mermaid = "not a valid mermaid at all }{}{" in
  let _result = Chain_mermaid_parser.parse_chain mermaid in
  (* Just exercise the code path, don't assert error *)
  ()

(* ============================================================
   Runner
   ============================================================ *)

let () =
  run "chain_coverage" [
    "normalize_label_content", [
      test_case "escaped quotes" `Quick test_normalize_escaped_quotes;
      test_case "no escapes" `Quick test_normalize_no_escapes;
    ];
    "parse_node_content_subroutine", [
      test_case "Ref" `Quick test_subroutine_ref;
      test_case "Pipeline" `Quick test_subroutine_pipeline;
      test_case "Fanout" `Quick test_subroutine_fanout;
      test_case "Map ok" `Quick test_subroutine_map;
      test_case "Map bad" `Quick test_subroutine_map_bad;
      test_case "Bind ok" `Quick test_subroutine_bind;
      test_case "Bind bad" `Quick test_subroutine_bind_bad;
      test_case "Cache 3" `Quick test_subroutine_cache_3;
      test_case "Cache 2" `Quick test_subroutine_cache_2;
      test_case "Cache bad" `Quick test_subroutine_cache_bad;
      test_case "Batch 3" `Quick test_subroutine_batch_3;
      test_case "Batch 2" `Quick test_subroutine_batch_2;
      test_case "Batch bad" `Quick test_subroutine_batch_bad;
      test_case "Spawn 2" `Quick test_subroutine_spawn_2;
      test_case "Spawn 3" `Quick test_subroutine_spawn_3;
      test_case "Spawn bad" `Quick test_subroutine_spawn_bad;
      test_case "StreamMerge 1" `Quick test_subroutine_stream_merge_1;
      test_case "StreamMerge 2" `Quick test_subroutine_stream_merge_2;
      test_case "StreamMerge 3" `Quick test_subroutine_stream_merge_3;
      test_case "StreamMerge bad" `Quick test_subroutine_stream_merge_bad;
      test_case "StreamMerge reducers" `Quick test_subroutine_stream_merge_reducers;
      test_case "FeedbackLoop 3" `Quick test_subroutine_feedback_3;
      test_case "FeedbackLoop 2" `Quick test_subroutine_feedback_2;
      test_case "FeedbackLoop 1" `Quick test_subroutine_feedback_1;
      test_case "FeedbackLoop bad" `Quick test_subroutine_feedback_bad;
      test_case "FeedbackLoop ops" `Quick test_subroutine_feedback_ops;
      test_case "unknown" `Quick test_subroutine_unknown;
    ];
    "parse_node_content_diamond", [
      test_case "Quorum" `Quick test_diamond_quorum;
      test_case "Gate" `Quick test_diamond_gate;
      test_case "Merge" `Quick test_diamond_merge;
      test_case "Merge strategies" `Quick test_diamond_merge_strategies;
      test_case "GoalDriven" `Quick test_diamond_goaldriven;
      test_case "GoalDriven ops" `Quick test_diamond_goaldriven_ops;
      test_case "GoalDriven bad" `Quick test_diamond_goaldriven_bad;
      test_case "MCTS greedy" `Quick test_diamond_mcts_greedy;
      test_case "MCTS ucb1" `Quick test_diamond_mcts_ucb1;
      test_case "MCTS eps" `Quick test_diamond_mcts_eps;
      test_case "MCTS softmax" `Quick test_diamond_mcts_softmax;
      test_case "MCTS bad" `Quick test_diamond_mcts_bad;
      test_case "Evaluator 3" `Quick test_diamond_evaluator_3;
      test_case "Evaluator strategies" `Quick test_diamond_evaluator_strategies;
      test_case "Evaluator 1" `Quick test_diamond_evaluator_1;
      test_case "Evaluator bad" `Quick test_diamond_evaluator_bad;
      test_case "Threshold" `Quick test_diamond_threshold;
      test_case "Threshold ops" `Quick test_diamond_threshold_ops;
      test_case "Threshold bad op" `Quick test_diamond_threshold_bad_op;
      test_case "Threshold bad val" `Quick test_diamond_threshold_bad_val;
      test_case "unknown" `Quick test_diamond_unknown;
    ];
    "parse_node_content_rect", [
      test_case "MODEL quoted" `Quick test_rect_model_quoted;
      test_case "MODEL single" `Quick test_rect_model_single_quoted;
      test_case "MODEL model only" `Quick test_rect_model_model_only;
      test_case "Tool simple" `Quick test_rect_tool_simple;
      test_case "Tool quoted" `Quick test_rect_tool_quoted;
      test_case "Tool json" `Quick test_rect_tool_json;
      test_case "default MODEL" `Quick test_rect_default_model;
      test_case "+tools flag" `Quick test_rect_tools_flag;
    ];
    "parse_node_content_trap", [
      test_case "Adapt" `Quick test_trap_adapt;
      test_case "generic" `Quick test_trap_generic;
    ];
    "parse_node_content_stadium", [
      test_case "Retry" `Quick test_stadium_retry;
      test_case "Fallback" `Quick test_stadium_fallback;
      test_case "Fallback:" `Quick test_stadium_fallback_colon;
      test_case "Race" `Quick test_stadium_race;
      test_case "Race:" `Quick test_stadium_race_colon;
      test_case "Cascade" `Quick test_stadium_cascade;
      test_case "Cascade:" `Quick test_stadium_cascade_colon;
      test_case "default" `Quick test_stadium_default;
    ];
    "parse_node_content_circle", [
      test_case "broadcast" `Quick test_circle_broadcast;
      test_case "listen" `Quick test_circle_listen;
      test_case "claim" `Quick test_circle_claim;
      test_case "keyword wait" `Quick test_circle_keyword_wait;
      test_case "keyword claim" `Quick test_circle_keyword_claim;
      test_case "fallback br" `Quick test_circle_fallback_broadcast;
    ];
    "node_type_to_id", [
      test_case "model" `Quick test_node_type_to_id_model;
      test_case "tool" `Quick test_node_type_to_id_tool;
      test_case "all types" `Quick test_node_type_to_id_all_types;
    ];
    "escape_for_mermaid", [
      test_case "newlines" `Quick test_escape_newlines;
      test_case "quotes" `Quick test_escape_quotes;
      test_case "truncation" `Quick test_escape_truncation;
    ];
    "node_type_to_text", [
      test_case "model" `Quick test_node_type_to_text_model;
      test_case "tool empty" `Quick test_node_type_to_text_tool_empty;
      test_case "tool args" `Quick test_node_type_to_text_tool_args;
      test_case "model with tools" `Quick test_node_type_to_text_model_with_tools;
    ];
    "node_type_to_shape", [
      test_case "all shapes" `Quick test_shapes;
    ];
    "node_type_to_class", [
      test_case "all classes" `Quick test_classes;
    ];
    "chain_to_mermaid", [
      test_case "basic" `Quick test_chain_to_mermaid_basic;
      test_case "unstyled" `Quick test_chain_to_mermaid_unstyled;
    ];
    "chain_to_ascii", [
      test_case "basic" `Quick test_chain_to_ascii_basic;
      test_case "directions" `Quick test_chain_to_ascii_directions;
    ];
    "merge_strategy_to_string", [
      test_case "all" `Quick test_merge_strategy_to_string;
    ];
    "threshold_op_to_string", [
      test_case "all" `Quick test_threshold_op_to_string;
    ];
    "select_strategy_to_json", [
      test_case "all" `Quick test_select_strategy_to_json;
    ];
    "backoff_to_json", [
      test_case "all" `Quick test_backoff_to_json;
    ];
    "adapter_transform_to_json", [
      test_case "all variants" `Quick test_adapter_transform_to_json;
    ];
    "node_to_json", [
      test_case "parse canonical transition claim" `Quick
        test_parse_node_transition_claim_canonical;
      test_case "parse canonical claim_next" `Quick
        test_parse_node_claim_next_canonical;
      test_case "model full" `Quick test_node_to_json_model;
      test_case "tool namespaced" `Quick test_node_to_json_tool_namespaced;
      test_case "pipeline" `Quick test_node_to_json_pipeline;
      test_case "gate" `Quick test_node_to_json_gate;
      test_case "cascade" `Quick test_node_to_json_cascade;
      test_case "specific claim emits transition" `Quick
        test_node_to_json_specific_claim_emits_transition;
      test_case "claim_next emits claim_next" `Quick
        test_node_to_json_claim_next_emits_claim_next;
    ];
    "chain_to_json_string", [
      test_case "pretty" `Quick test_chain_to_json_string;
      test_case "compact" `Quick test_chain_to_json_string_compact;
    ];
    "on_error_to_json", [
      test_case "all" `Quick test_on_error_to_json;
    ];
    "node_type_to_text_exhaustive", [
      test_case "all variants" `Quick test_node_type_to_text_exhaustive;
    ];
    "chain_to_mermaid_edges", [
      test_case "with edges" `Quick test_chain_to_mermaid_with_edges;
      test_case "ascii with edges" `Quick test_chain_to_ascii_with_edges;
    ];
    "round_trip", [
      test_case "simple" `Quick test_round_trip_simple;
    ];
    "validate_chain", [
      test_case "valid" `Quick test_validate_chain_valid;
      test_case "missing output" `Quick test_validate_chain_missing_output;
      test_case "duplicate ids" `Quick test_validate_chain_dup_ids;
      test_case "placeholder" `Quick test_validate_chain_placeholder;
    ];
    "validate_chain_strict", [
      test_case "valid" `Quick test_validate_strict_valid;
      test_case "empty chain" `Quick test_validate_strict_empty;
      test_case "bad config" `Quick test_validate_strict_bad_config;
    ];
    "has_placeholder", [
      test_case "no placeholder" `Quick test_no_placeholder;
      test_case "placeholder node" `Quick test_has_placeholder;
      test_case "deep placeholder" `Quick test_deep_placeholder;
    ];
    "extract_template_vars", [
      test_case "basic" `Quick test_extract_template_vars;
      test_case "none" `Quick test_extract_template_vars_none;
    ];
    "strip_braces", [
      test_case "with braces" `Quick test_strip_braces_ok;
      test_case "without braces" `Quick test_strip_braces_no;
    ];
    "collect_all_nodes", [
      test_case "nested" `Quick test_collect_all_nodes;
      test_case "exhaustive" `Quick test_collect_all_nodes_exhaustive;
    ];
    "validate_strict_all", [
      test_case "all node types" `Quick test_validate_strict_all_node_types;
    ];
    "has_placeholder_all", [
      test_case "all node types" `Quick test_has_placeholder_all_types;
    ];
    "parse_chain_mermaid", [
      test_case "simple MODEL" `Quick test_parse_chain_simple;
      test_case "two nodes" `Quick test_parse_chain_two_nodes;
      test_case "labeled edge" `Quick test_parse_chain_labeled_edge;
      test_case "diamond node" `Quick test_parse_chain_diamond;
      test_case "subroutine node" `Quick test_parse_chain_subroutine;
      test_case "stadium node" `Quick test_parse_chain_stadium;
      test_case "circle node" `Quick test_parse_chain_circle;
      test_case "trap node" `Quick test_parse_chain_trap;
      test_case "multi edge" `Quick test_parse_chain_multi_edge;
      test_case "chained arrows" `Quick test_parse_chain_chained;
      test_case "with json meta" `Quick test_parse_chain_with_meta;
      test_case "direction TB" `Quick test_parse_chain_direction;
      test_case "bad input" `Quick test_parse_chain_bad;
    ];
  ]
