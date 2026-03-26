(** Chain Executor - Search nodes (MCTS, evaluator) *)

include Chain_executor_leaf
open Chain_types

let execute_mcts ctx ~sw ~clock ~(exec_fn : exec_fn) ~(execute_node : execute_node_fn) ~tool_exec (parent : node)
    ~strategies ~simulation ~evaluator ~evaluator_prompt ~policy
    ~max_iterations ~max_depth ~expansion_threshold ~early_stop ~parallel_sims
    : (string, string) result =
  record_start ctx parent.id;
  let start = Time_compat.now () in

  (* Get exploration constant from policy *)
  let exploration_c = match policy with
    | UCB1 c -> c
    | Greedy -> 0.0
    | EpsilonGreedy _ -> 1.414
    | Softmax _ -> 1.414
  in

  (* Create root node with initial strategies as children *)
  let root = {
    strategy_idx = -1;
    visits = 0;
    total_score = 0.0;
    children = [];
    parent = None;
    depth = 0;
    last_output = ref "";
  } in

  (* Initialize children for each strategy *)
  root.children <- List.mapi (fun i _ -> {
    strategy_idx = i;
    visits = 0;
    total_score = 0.0;
    children = [];
    parent = Some root;
    depth = 1;
    last_output = ref "";
  }) strategies;

  (* Selection phase: traverse tree using UCB1/policy to find node to expand.
     Returns (Ok node) on success, (Error msg) if tree is in an invalid state. *)
  let rec select (node : mcts_tree_node) : (mcts_tree_node, string) result =
    if node.children = [] || node.depth >= max_depth then Ok node
    else
      let parent_visits = max 1 node.visits in
      let selected = match policy with
        | UCB1 _ | EpsilonGreedy _ ->
            (* UCB1 or epsilon-greedy uses UCB1 for selection *)
            let with_scores = List.map (fun child ->
              (child, ucb1_value ~c:exploration_c parent_visits child)
            ) node.children in
            let sorted = List.sort (fun (_, s1) (_, s2) -> Float.compare s2 s1) with_scores in
            (match sorted with
             | (best, _) :: _ -> Ok best
             | [] -> Error "MCTS select: leaf node has no children to expand (UCB1)")
        | Greedy ->
            (* Pure exploitation: pick highest average score *)
            let with_avg = List.map (fun child ->
              let avg = if child.visits = 0 then 0.0 else child.total_score /. float_of_int child.visits in
              (child, avg)
            ) node.children in
            let sorted = List.sort (fun (_, s1) (_, s2) -> Float.compare s2 s1) with_avg in
            (match sorted with
             | (best, _) :: _ -> Ok best
             | [] -> Error "MCTS select: leaf node has no children to expand (Greedy)")
        | Softmax temp ->
            (* Softmax selection with temperature *)
            let scores = List.map (fun child ->
              if child.visits = 0 then 0.0 else child.total_score /. float_of_int child.visits
            ) node.children in
            let max_score = List.fold_left max Float.neg_infinity scores in
            let exp_scores = List.map (fun s -> exp ((s -. max_score) /. temp)) scores in
            let sum = List.fold_left (+.) 0.0 exp_scores in
            let probs = List.map (fun e -> e /. sum) exp_scores in
            (* Sample from distribution - using fiber-safe RNG *)
            let r = Random.State.float executor_rng 1.0 in
            let rec sample acc = function
              | [] ->
                  (match list_hd_opt node.children with
                   | Some c -> Ok c
                   | None -> Error "MCTS select: empty candidate group (Softmax sampling exhausted)")
              | (child, prob) :: rest ->
                  let acc' = acc +. prob in
                  if r < acc' then Ok child else sample acc' rest
            in
            sample 0.0 (List.combine node.children probs)
      in
      match selected with
      | Error _ as e -> e
      | Ok s -> select s
  in

  (* Expansion phase: add new child nodes if visits exceed threshold *)
  let expand (node : mcts_tree_node) : (mcts_tree_node, string) result =
    if node.visits >= expansion_threshold && node.depth < max_depth && node.children = [] then begin
      (* Create children by re-using all strategies (exploring different paths) *)
      node.children <- List.mapi (fun i _ -> {
        strategy_idx = i;
        visits = 0;
        total_score = 0.0;
        children = [];
        parent = Some node;
        depth = node.depth + 1;
        last_output = ref "";
      }) strategies;
      (* Return first unvisited child *)
      match node.children with
      | first :: _ -> Ok first
      | [] -> Error "MCTS expand: empty candidate group (no strategies to expand)"
    end
    else Ok node
  in

  (* Simulation phase: execute strategy and simulation in clean context *)
  let simulate (node : mcts_tree_node) : float =
    match list_nth_opt strategies node.strategy_idx with
    | None ->
        (* Invalid strategy index — treat as failed strategy *)
        Log.Chain.error "MCTS: invalid strategy index %d (strategies=%d)"
          node.strategy_idx (List.length strategies);
        0.0
    | Some strategy_node ->
    (* Execute strategy in current context first *)
    let strategy_result = execute_node ctx ~sw ~clock ~exec_fn ~tool_exec strategy_node in
    match strategy_result with
    | Error _ -> 0.0  (* Failed strategy gets 0 score *)
    | Ok strategy_output ->
        node.last_output := strategy_output;
        (* Store strategy output for simulation *)
        Hashtbl.replace ctx.outputs strategy_node.Chain_types.id strategy_output;
        (* Execute simulation in spawned clean context *)
        let sim_result = Chain_executor_resilience.execute_spawn ctx ~sw ~clock ~exec_fn ~execute_node ~tool_exec simulation
          ~clean:true ~pass_vars:[strategy_node.Chain_types.id] ~inherit_cache:false simulation in
        match sim_result with
        | Error _ -> 0.0
        | Ok sim_output ->
            (* Score the simulation output *)
            let score = match evaluator with
            | "model_judge" ->
                let prompt = match evaluator_prompt with
                  | Some p -> Printf.sprintf "%s\n\nOutput to evaluate:\n%s" p sim_output
                  | None -> Printf.sprintf "Rate this output from 0.0 to 1.0:\n%s" sim_output
                in
                (match judge_call ~prompt () with
                 | Ok s ->
                     let raw = Safe_parse.float ~context:"model_judge" ~default:0.5 (String.trim s) in
                     Float.min 1.0 (Float.max 0.0 raw)
                 | Error _ -> 0.5)
            | "exec_test" ->
                (* Parse test results: look for pass rate or coverage *)
                let pass_rate_re = Re.Pcre.re {|(\d+)/(\d+)|} |> Re.compile in
                let coverage_re = Re.Pcre.re {|coverage[: ]+([0-9.]+)|} |> Re.compile in
                (match Re.exec_opt pass_rate_re sim_output with
                 | Some group ->
                     (try
                       let passed = float_of_string (Re.Group.get group 1) in
                       let total = float_of_string (Re.Group.get group 2) in
                       passed /. total
                      with Failure _ -> 0.5)
                 | None ->
                     match Re.exec_opt coverage_re sim_output with
                     | Some group ->
                         (try float_of_string (Re.Group.get group 1)
                          with Failure _ -> 0.5)
                     | None -> 0.5)
            | "anti_fake" ->
                (* Hybrid heuristic + MODEL scoring for code quality *)
                let heuristic_score =
                  let penalties = [
                    ("assert true", -0.3); ("let _ =", -0.2); ("(* TODO", -0.15);
                    ("skip", -0.1); ("ignore", -0.1);
                  ] in
                  let bonuses = [
                    ("assert_equal", 0.1); ("expect", 0.1); ("roundtrip", 0.15);
                    ("property", 0.1); ("quickcheck", 0.1);
                  ] in
                  let base = 0.5 in
                  let pen = List.fold_left (fun acc (pat, pen) ->
                    if string_contains ~substring:pat sim_output then acc +. pen else acc
                  ) 0.0 penalties in
                  let bon = List.fold_left (fun acc (pat, bon) ->
                    if string_contains ~substring:pat sim_output then acc +. bon else acc
                  ) 0.0 bonuses in
                  Float.min 1.0 (Float.max 0.0 (base +. pen +. bon))
                in
                (* MODEL judge for semantic analysis *)
                let model_score =
                  let prompt = Printf.sprintf
                    "Rate this code/test quality from 0.0 to 1.0. Check for: fake tests, missing assertions, incomplete coverage.\n\n%s"
                    sim_output
                  in
                  match judge_call ~prompt () with
                  | Ok s -> Safe_parse.float ~context:"anti_fake:model" ~default:0.5 (String.trim s)
                  | Error _ -> 0.5
                in
                (heuristic_score +. model_score) /. 2.0
            | _ ->
                (* Default: try to parse as float or return 0.5 *)
                Safe_parse.float ~context:"score:default" ~default:0.5 (String.trim sim_output)
            in
            score
  in

  (* Backpropagation phase: update scores up the tree *)
  let rec backpropagate (node : mcts_tree_node) (score : float) : unit =
    node.visits <- node.visits + 1;
    node.total_score <- node.total_score +. score;
    match node.parent with
    | Some p -> backpropagate p score
    | None -> ()
  in

  (* Main MCTS loop *)
  let best_output = ref "" in
  let best_score = ref Float.neg_infinity in
  let tree_mutex = Eio.Mutex.create () in  (* Protect tree modifications *)

  let rec mcts_iteration iteration =
    if iteration >= max_iterations then ()
    else begin
      (* Run parallel simulations via Eio.Stream.
         Not all sims succeed (select/expand may fail), so drain with
         take_nonblocking after Fiber.all completes. *)
      let sim_stream = Eio.Stream.create parallel_sims in

      Eio.Fiber.all (List.init parallel_sims (fun _ ->
        fun () ->
          match select root with
          | Error msg ->
              Log.Chain.warn "MCTS select failed: %s" msg
          | Ok selected ->
          (* Protect expand with tree_mutex to prevent race on node.children *)
          let expand_result = Eio.Mutex.use_rw tree_mutex ~protect:true (fun () ->
            expand selected) in
          match expand_result with
          | Error msg ->
              Log.Chain.warn "MCTS expand failed: %s" msg
          | Ok expanded ->
          let score = simulate expanded in
          Eio.Stream.add sim_stream (expanded, score)
      ));

      (* Drain results and track best *)
      let sim_results = ref [] in
      let continue = ref true in
      while !continue do
        match Eio.Stream.take_nonblocking sim_stream with
        | Some (expanded, score) ->
            sim_results := (expanded, score) :: !sim_results;
            if score > !best_score then begin
              best_score := score;
              best_output := !(expanded.last_output)
            end
        | None -> continue := false
      done;

      (* Backpropagate all results *)
      List.iter (fun (node, score) ->
        backpropagate node score
      ) !sim_results;

      (* Check early stopping *)
      match early_stop with
      | Some threshold when !best_score >= threshold ->
          ()  (* Early stop: found good enough solution *)
      | _ ->
          mcts_iteration (iteration + parallel_sims)
    end
  in

  mcts_iteration 0;

  (* Find best strategy based on final statistics *)
  let best_child =
    let sorted = List.sort (fun c1 c2 ->
      let avg1 = if c1.visits = 0 then 0.0 else c1.total_score /. float_of_int c1.visits in
      let avg2 = if c2.visits = 0 then 0.0 else c2.total_score /. float_of_int c2.visits in
      Float.compare avg2 avg1
    ) root.children in
    match sorted with best :: _ -> Some best | [] -> None
  in

  let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in

  match best_child with
  | None ->
      record_complete ctx parent.id ~duration_ms ~success:false;
      Error "MCTS: No strategies found"
  | Some best ->
      let result_json = Yojson.Safe.to_string (`Assoc [
        ("strategy_idx", `Int best.strategy_idx);
        ("visits", `Int best.visits);
        ("avg_score", `Float (best.total_score /. float_of_int (max 1 best.visits)));
        ("total_iterations", `Int root.visits);
        ("best_output", `String !best_output);
      ]) in
      store_node_output ctx parent result_json;
      record_complete ctx parent.id ~duration_ms ~success:true;
      Ok result_json

(** Execute cache node - check cache first, execute inner if miss *)


let execute_evaluator ctx ~sw ~clock ~(exec_fn : exec_fn) ~(execute_node : execute_node_fn) ~tool_exec (parent : node)
    ~candidates ~scoring_func ~scoring_prompt ~select_strategy ~min_score : (string, string) result =
  record_start ctx parent.id;
  let start = Time_compat.now () in

  (* Execute all candidates in parallel via Eio.Stream *)
  let n = List.length candidates in
  let stream = Eio.Stream.create n in

  Eio.Fiber.all (List.map (fun (candidate : node) ->
    fun () ->
      let result = execute_node ctx ~sw ~clock ~exec_fn ~tool_exec candidate in
      Eio.Stream.add stream (candidate.id, result)
  ) candidates);

  let results = List.init n (fun _ -> Eio.Stream.take stream) in

  (* Helper: MODEL-based scoring via OAS chain_judge cascade *)
  let model_score output =
    let prompt = match scoring_prompt with
      | Some p -> Printf.sprintf "%s\n\nCandidate output:\n%s\n\nRespond with ONLY a number between 0.0 and 1.0" p output
      | None -> Printf.sprintf "Score this output from 0.0 to 1.0 for quality and correctness:\n\n%s\n\nRespond with ONLY a number between 0.0 and 1.0" output
    in
    let result = judge_call ~prompt () in
    match result with
    | Ok score_str ->
        (* Extract float from response *)
        let cleaned = String.trim score_str in
        (try
          let score = float_of_string cleaned in
          min 1.0 (max 0.0 score)  (* Clamp to [0, 1] *)
        with Failure _ ->
          (* Try to find a number in the response *)
          let regex = Re.Pcre.re {|[0-9]+\.[0-9]+|} |> Re.compile in
          match Re.exec_opt regex cleaned with
          | Some group ->
              (try min 1.0 (max 0.0 (float_of_string (Re.Group.get group 0)))
               with Failure _ -> 0.5)
          | None -> 0.5)  (* Fallback *)
    | Error _ -> 0.5  (* Fallback on error *)
  in

  (* Score each successful result *)
  let scored = List.filter_map (fun (id, r) ->
    match r with
    | Error _ -> None
    | Ok output ->
        (* Score based on scoring_func *)
        let score = match scoring_func with
          | "regex_match" ->
              (* Simple: longer output = higher score (placeholder) *)
              float_of_int (String.length output) /. 1000.0
          | "json_schema" ->
              (* Check if valid JSON, bonus for more complete structure *)
              (try
                let json = Yojson.Safe.from_string output in
                let depth = ref 0 in
                let rec count_depth = function
                  | `Assoc fields ->
                      incr depth;
                      List.iter (fun (_, v) -> count_depth v) fields
                  | `List items ->
                      incr depth;
                      List.iter count_depth items
                  | _ -> ()
                in
                count_depth json;
                min 1.0 (0.5 +. (float_of_int !depth *. 0.1))
               with Yojson.Json_error _ -> 0.0)
          | "model_judge" ->
              (* Use MODEL to score the output *)
              model_score output
          | "anti_fake" ->
              (* Anti-fake test detection: Hybrid (heuristic + MODEL judge) *)
              let output_lower = String.lowercase_ascii output in
              (* Helper: check if haystack contains needle *)
              let contains_str needle haystack =
                let nl = String.length needle and hl = String.length haystack in
                if nl > hl then false
                else
                  let rec check i =
                    if i > hl - nl then false
                    else if String.sub haystack i nl = needle then true
                    else check (i + 1)
                  in check 0
              in
              (* Phase 1: Fast heuristic checks (0.0-0.5 range) *)
              let heuristic_score = ref 0.5 in
              (* Penalty patterns (fake tests) *)
              if contains_str "assert true" output_lower then
                heuristic_score := !heuristic_score -. 0.15;
              if contains_str "let _ =" output then
                heuristic_score := !heuristic_score -. 0.1;
              if contains_str "(* todo" output_lower then
                heuristic_score := !heuristic_score -. 0.05;
              (* Bonus patterns (real tests) *)
              let count_substr needle haystack =
                let nl = String.length needle and hl = String.length haystack in
                if nl > hl || nl = 0 then 0
                else
                  let rec aux i acc =
                    if i > hl - nl then acc
                    else if String.sub haystack i nl = needle then aux (i + 1) (acc + 1)
                    else aux (i + 1) acc
                  in aux 0 0
              in
              let real_asserts = count_substr "assert (" output in
              let alcotest_checks = count_substr "Alcotest.check" output in
              heuristic_score := !heuristic_score +. (float_of_int (real_asserts + alcotest_checks) *. 0.02);
              if contains_str "decode" output_lower && contains_str "encode" output_lower then
                heuristic_score := !heuristic_score +. 0.1;
              let h_score = max 0.0 (min 0.5 !heuristic_score) in

              (* Phase 2: MODEL judge for semantic analysis (0.0-0.5 range) *)
              (* Few-shot examples for better accuracy *)
              let model_prompt = Printf.sprintf {|Analyze this test code for fake test patterns.

## Few-Shot Examples:

FAKE (score: 0.2):
```
let test () = let _ = encode () in assert true
```
Reason: Ignores return value, empty assertion

FAKE (score: 0.3):
```
def test(): result = process(); assert True
```
Reason: Doesn't verify result

REAL (score: 0.85):
```
let test () = let encoded = encode x in let decoded = decode encoded in assert (decoded = x)
```
Reason: Roundtrip verification, real assertion

REAL (score: 0.8):
```
it('works', () => { expect(decode(encode(x))).toEqual(x); });
```
Reason: Roundtrip with proper expectation

## Score Scale:
- 0.0-0.3 = Fake test (assert true, ignores results)
- 0.4-0.6 = Partial test (some assertions, missing cases)
- 0.7-1.0 = Real test (meaningful assertions, tests behavior)

## Code to Analyze:
```
%s
```

Reply with ONLY a number between 0.0 and 1.0:|}
                (String.sub output 0 (min 1500 (String.length output)))
              in
              let model_score =
                match judge_call ~prompt:model_prompt () with
                | Ok score_str ->
                    (try float_of_string (String.trim score_str) *. 0.5
                     with Failure _ -> 0.25)
                | Error _ -> 0.25  (* Default if MODEL fails *)
              in
              (* Final: heuristic (50%) + MODEL (50%) *)
              h_score +. model_score
          | "custom" | _ ->
              (* For custom, try to parse score from output metadata *)
              (try
                let json = Yojson.Safe.from_string output in
                let open Yojson.Safe.Util in
                json |> member "score" |> to_float
               with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> 0.5)
        in
        Some (id, output, score)
  ) results in

  let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in

  if scored = [] then begin
    record_complete ctx parent.id ~duration_ms ~success:false;
    Error "No candidates succeeded"
  end else begin
    (* Filter by min_score if specified *)
    let filtered = match min_score with
      | None -> scored
      | Some threshold -> List.filter (fun (_, _, s) -> s >= threshold) scored
    in
    if filtered = [] then begin
      record_complete ctx parent.id ~duration_ms ~success:false;
      Error (Printf.sprintf "No candidates met minimum score %.2f" (Option.value min_score ~default:0.0))
    end else begin
      (* Select based on strategy *)
      let selected = match select_strategy with
        | Best ->
            List.fold_left (fun best (id, out, sc) ->
              match best with
              | None -> Some (id, out, sc)
              | Some (_, _, best_sc) -> if sc > best_sc then Some (id, out, sc) else best
            ) None filtered
        | Worst ->
            List.fold_left (fun worst (id, out, sc) ->
              match worst with
              | None -> Some (id, out, sc)
              | Some (_, _, worst_sc) -> if sc < worst_sc then Some (id, out, sc) else worst
            ) None filtered
        | AboveThreshold t ->
            List.find_opt (fun (_, _, sc) -> sc >= t) filtered
        | WeightedRandom ->
            (* Simplified: just pick first (proper impl would use weighted random) *)
            (* Safe: filtered is non-empty due to guard at line 1397 *)
            match filtered with
            | first :: _ -> Some first
            | [] -> None  (* Unreachable but type-safe *)
      in
      match selected with
      | None ->
          record_complete ctx parent.id ~duration_ms ~success:false;
          Error "Selection strategy returned no result"
      | Some (_, output, _) ->
          record_complete ctx parent.id ~duration_ms ~success:true;
          store_node_output ctx parent output;
          Ok output
    end
  end

(** Execute FeedbackLoop node - iterative quality improvement with evaluator feedback *)


