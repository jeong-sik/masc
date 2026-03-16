(** Chain Mermaid Node Content — parse_node_content for all node shapes *)

open Chain_types
include Chain_mermaid_parse

(** Mermaid labels coming from LLM JSON responses often escape inner quotes.
    Normalize those escapes before parsing the semantic node payload. *)
let normalize_label_content (content : string) : string =
  content
  |> Str.global_replace (Str.regexp {|\\\"|}) "\""
  |> Str.global_replace (Str.regexp {|\\'|}) "'"

(** Parse node content into Chain node_type *)
let parse_node_content (shape : [ `Rect | `Diamond | `Subroutine | `Trap | `Stadium | `Circle ]) (content : string)
    : (node_type, string) result =
  let content = content |> normalize_label_content |> trim in
  match shape with
  | `Subroutine ->
      (* [[Ref:chain_id]] or [[Pipeline:A,B,C]] or [[Fanout:A,B,C]] or [[Map:func,node]] or [[Bind:func,node]] *)
      if String.length content > 4 && String.sub content 0 4 = "Ref:" then
        let ref_id = trim (String.sub content 4 (String.length content - 4)) in
        Ok (ChainRef ref_id)
      else if String.length content > 9 && String.sub content 0 9 = "Pipeline:" then
        (* [[Pipeline:A,B,C]] - sequential execution *)
        let node_ids = String.sub content 9 (String.length content - 9)
          |> String.split_on_char ','
          |> List.map trim
          |> List.filter (fun s -> s <> "")
        in
        let placeholder_nodes = List.map (fun node_id ->
          { id = node_id ^ "_ref"; node_type = ChainRef node_id; input_mapping = []; output_key = None; depends_on = None }
        ) node_ids in
        Ok (Pipeline placeholder_nodes)
      else if String.length content > 7 && String.sub content 0 7 = "Fanout:" then
        (* [[Fanout:A,B,C]] - parallel execution *)
        let node_ids = String.sub content 7 (String.length content - 7)
          |> String.split_on_char ','
          |> List.map trim
          |> List.filter (fun s -> s <> "")
        in
        let placeholder_nodes = List.map (fun node_id ->
          { id = node_id ^ "_ref"; node_type = ChainRef node_id; input_mapping = []; output_key = None; depends_on = None }
        ) node_ids in
        Ok (Fanout placeholder_nodes)
      else if String.length content > 4 && String.sub content 0 4 = "Map:" then
        (* [[Map:func,node]] - transform output *)
        let parts = String.sub content 4 (String.length content - 4)
          |> String.split_on_char ','
          |> List.map trim
        in
        (match parts with
        | [func; node_id] ->
            Ok (Map { func; inner = { id = node_id ^ "_ref"; node_type = ChainRef node_id; input_mapping = []; output_key = None; depends_on = None } })
        | _ ->
            Error (Printf.sprintf "Map requires func,node format, got: %s" content))
      else if String.length content > 5 && String.sub content 0 5 = "Bind:" then
        (* [[Bind:func,node]] - dynamic routing *)
        let parts = String.sub content 5 (String.length content - 5)
          |> String.split_on_char ','
          |> List.map trim
        in
        (match parts with
        | [func; node_id] ->
            Ok (Bind { func; inner = { id = node_id ^ "_ref"; node_type = ChainRef node_id; input_mapping = []; output_key = None; depends_on = None } })
        | _ ->
            Error (Printf.sprintf "Bind requires func,node format, got: %s" content))
      else if String.length content > 6 && String.sub content 0 6 = "Cache:" then
        (* [[Cache:key_expr,ttl,node_id]] - cache results with TTL *)
        let parts = String.sub content 6 (String.length content - 6)
          |> String.split_on_char ','
          |> List.map trim
        in
        (match parts with
        | [key_expr; ttl_str; node_id] ->
            let ttl_seconds = Safe_parse.int ~context:"Cache:ttl" ~default:0 ttl_str in
            Ok (Cache { key_expr; ttl_seconds; inner = { id = node_id ^ "_ref"; node_type = ChainRef node_id; input_mapping = []; output_key = None; depends_on = None } })
        | [key_expr; node_id] ->
            (* Default TTL = 0 (infinite) *)
            Ok (Cache { key_expr; ttl_seconds = 0; inner = { id = node_id ^ "_ref"; node_type = ChainRef node_id; input_mapping = []; output_key = None; depends_on = None } })
        | _ ->
            Error (Printf.sprintf "Cache requires key,ttl,node or key,node format, got: %s" content))
      else if String.length content > 6 && String.sub content 0 6 = "Batch:" then
        (* [[Batch:size,parallel,node_id]] - batch processing *)
        let parts = String.sub content 6 (String.length content - 6)
          |> String.split_on_char ','
          |> List.map trim
        in
        (match parts with
        | [size_str; parallel_str; node_id] ->
            let batch_size = Safe_parse.int ~context:"Batch:size" ~default:10 size_str in
            let parallel = parallel_str = "true" || parallel_str = "parallel" in
            Ok (Batch { batch_size; parallel; inner = { id = node_id ^ "_ref"; node_type = ChainRef node_id; input_mapping = []; output_key = None; depends_on = None }; collect_strategy = `List })
        | [size_str; node_id] ->
            let batch_size = Safe_parse.int ~context:"Batch:size" ~default:10 size_str in
            Ok (Batch { batch_size; parallel = true; inner = { id = node_id ^ "_ref"; node_type = ChainRef node_id; input_mapping = []; output_key = None; depends_on = None }; collect_strategy = `List })
        | _ ->
            Error (Printf.sprintf "Batch requires size,parallel,node or size,node format, got: %s" content))
      else if String.length content > 6 && String.sub content 0 6 = "Spawn:" then
        (* [[Spawn:clean,node_id]] or [[Spawn:clean,pass_var1|pass_var2,node_id]] - clean context spawn *)
        let parts = String.sub content 6 (String.length content - 6)
          |> String.split_on_char ','
          |> List.map trim
        in
        (match parts with
        | [clean_str; node_id] ->
            let clean = clean_str = "true" || clean_str = "clean" in
            Ok (Spawn { clean; inner = { id = node_id ^ "_ref"; node_type = ChainRef node_id; input_mapping = []; output_key = None; depends_on = None }; pass_vars = []; inherit_cache = true })
        | [clean_str; pass_vars_str; node_id] ->
            let clean = clean_str = "true" || clean_str = "clean" in
            let pass_vars = String.split_on_char '|' pass_vars_str |> List.map trim in
            Ok (Spawn { clean; inner = { id = node_id ^ "_ref"; node_type = ChainRef node_id; input_mapping = []; output_key = None; depends_on = None }; pass_vars; inherit_cache = true })
        | _ ->
            Error (Printf.sprintf "Spawn requires clean,node or clean,pass_vars,node format, got: %s" content))
      else if String.length content > 12 && String.sub content 0 12 = "StreamMerge:" then
        (* [[StreamMerge:reducer,min_results,timeout]] - progressive result processing *)
        let parts = String.sub content 12 (String.length content - 12)
          |> String.split_on_char ','
          |> List.map trim
        in
        let parse_reducer s = match String.lowercase_ascii s with
          | "first" -> First | "last" -> Last | "concat" -> Concat
          | "weighted" | "weighted_avg" -> WeightedAvg
          | custom -> Custom custom
        in
        (match parts with
        | [reducer_str] ->
            Ok (StreamMerge {
              nodes = [];  (* filled from edges in post-process *)
              reducer = parse_reducer reducer_str;
              initial = "";
              min_results = None;
              timeout = None;
            })
        | [reducer_str; min_str] ->
            let min_results = Safe_parse.int_opt min_str in
            Ok (StreamMerge {
              nodes = [];
              reducer = parse_reducer reducer_str;
              initial = "";
              min_results;
              timeout = None;
            })
        | [reducer_str; min_str; timeout_str] ->
            let min_results = Safe_parse.int_opt min_str in
            let timeout = Safe_parse.float_opt timeout_str in
            Ok (StreamMerge {
              nodes = [];
              reducer = parse_reducer reducer_str;
              initial = "";
              min_results;
              timeout;
            })
        | _ ->
            Error (Printf.sprintf "StreamMerge format: reducer or reducer,min or reducer,min,timeout, got: %s" content))
      else if String.length content > 13 && String.sub content 0 13 = "FeedbackLoop:" then
        (* [[FeedbackLoop:scoring_func,max_iter,>=0.95]] - iterative quality improvement with explicit operator *)
        let parts = String.sub content 13 (String.length content - 13)
          |> String.split_on_char ','
          |> List.map trim
        in
        (* Generator placeholder - will be replaced during post-processing from incoming edges *)
        let gen_placeholder = { id = "feedback_gen"; node_type = ChainRef "feedback_gen"; input_mapping = []; output_key = None; depends_on = None } in
        (* Parse threshold with operator: ">=0.95", "<0.3", "0.7" (default >=) *)
        let parse_threshold_value str =
          let s = trim str in
          let parse_f sub = Safe_parse.float ~context:"FeedbackLoop:threshold" ~default:0.7 sub in
          if String.length s >= 2 && s.[0] = '>' && s.[1] = '=' then
            (Gte, parse_f (String.sub s 2 (String.length s - 2)))
          else if String.length s >= 2 && s.[0] = '<' && s.[1] = '=' then
            (Lte, parse_f (String.sub s 2 (String.length s - 2)))
          else if String.length s >= 2 && s.[0] = '!' && s.[1] = '=' then
            (Neq, parse_f (String.sub s 2 (String.length s - 2)))
          else if String.length s >= 1 && s.[0] = '>' then
            (Gt, parse_f (String.sub s 1 (String.length s - 1)))
          else if String.length s >= 1 && s.[0] = '<' then
            (Lt, parse_f (String.sub s 1 (String.length s - 1)))
          else if String.length s >= 1 && s.[0] = '=' then
            (Eq, parse_f (String.sub s 1 (String.length s - 1)))
          else
            (Gte, parse_f s)  (* default: >=value *)
        in
        (match parts with
        | [scoring_func; max_iter_str; threshold_str] ->
            let max_iterations = Safe_parse.int ~context:"FeedbackLoop:max_iter" ~default:3 max_iter_str in
            let (score_operator, score_threshold) = parse_threshold_value threshold_str in
            Ok (FeedbackLoop {
              generator = gen_placeholder;
              evaluator_config = {
                scoring_func;
                scoring_prompt = None;
                select_strategy = Best;
              };
              improver_prompt = "Improve the output based on this feedback: {{feedback}}\n\nPrevious output: {{previous_output}}";
              max_iterations;
              score_threshold;
              score_operator;
              conversational = false;
              relay_models = [];
            })
        | [scoring_func; max_iter_str] ->
            let max_iterations = Safe_parse.int ~context:"FeedbackLoop:max_iter" ~default:3 max_iter_str in
            Ok (FeedbackLoop {
              generator = gen_placeholder;
              evaluator_config = {
                scoring_func;
                scoring_prompt = None;
                select_strategy = Best;
              };
              improver_prompt = "Improve the output based on this feedback: {{feedback}}\n\nPrevious output: {{previous_output}}";
              max_iterations;
              score_threshold = 0.7;
              score_operator = Gte;
              conversational = false;
              relay_models = [];
            })
        | [scoring_func] ->
            Ok (FeedbackLoop {
              generator = gen_placeholder;
              evaluator_config = {
                scoring_func;
                scoring_prompt = None;
                select_strategy = Best;
              };
              improver_prompt = "Improve the output based on this feedback: {{feedback}}\n\nPrevious output: {{previous_output}}";
              max_iterations = 3;
              score_threshold = 0.7;
              score_operator = Gte;
              conversational = false;
              relay_models = [];
            })
        | _ ->
            Error (Printf.sprintf "FeedbackLoop format: func or func,max or func,max,>=0.95, got: %s" content))
      else
        Error (Printf.sprintf "Subroutine node must be Ref/Pipeline/Fanout/Map/Bind/Cache/Batch/Spawn/StreamMerge/FeedbackLoop, got: %s" content)

  | `Diamond ->
      (* P1.3: {Quorum:N}, {Quorum:majority}, {Quorum:unanimous}, {Quorum:weighted:T} or {Gate:condition} *)
      if String.length content > 7 && String.sub content 0 7 = "Quorum:" then
        let mode_str = trim (String.sub content 7 (String.length content - 7)) in
        let consensus = Chain_types.consensus_mode_of_string mode_str in
        (* Quorum nodes need their inputs filled in later from edges *)
        Ok (Quorum { consensus; nodes = []; weights = [] })
      else if String.length content > 5 && String.sub content 0 5 = "Gate:" then
        let condition = trim (String.sub content 5 (String.length content - 5)) in
        (* Gate needs then/else filled in from edges *)
        Ok (Gate { condition; then_node = { id = "_placeholder"; node_type = ChainRef "_"; input_mapping = []; output_key = None; depends_on = None }; else_node = None })
      else if String.length content > 6 && String.sub content 0 6 = "Merge:" then
        (* {Merge:strategy} - e.g., {Merge:weighted_average} *)
        let strategy_str = trim (String.sub content 6 (String.length content - 6)) in
        let strategy = match strategy_str with
          | "weighted_avg" | "weighted" -> WeightedAvg
          | "first" -> First
          | "last" -> Last
          | "concat" -> Concat
          | s -> Custom s  (* custom strategy name *)
        in
        (* Merge nodes need their inputs filled in later from edges *)
        Ok (Merge { strategy; nodes = [] })
      else if String.length content > 11 && String.sub content 0 11 = "GoalDriven:" then
        (* {GoalDriven:metric:op:value:max_iter} - e.g., {GoalDriven:coverage:gte:0.90:10} *)
        let rest = String.sub content 11 (String.length content - 11) in
        (* Format: metric:op:value:max_iter *)
        let goaldriven_re = Str.regexp {|^\([a-z_]+\):\([a-z]+\):\([0-9.]+\):\([0-9]+\)$|} in
        if Str.string_match goaldriven_re rest 0 then
          let metric = Str.matched_group 1 rest in
          let op_str = Str.matched_group 2 rest in
          let value = float_of_string (Str.matched_group 3 rest) in
          let max_iter = int_of_string (Str.matched_group 4 rest) in
          let operator = match op_str with
            | "gt" -> Gt | "gte" -> Gte | "lt" -> Lt | "lte" -> Lte | "eq" -> Eq | "neq" -> Neq
            | _ -> Gte  (* default *)
          in
          (* action_node is placeholder, filled from edges later *)
          Ok (GoalDriven {
            goal_metric = metric;
            goal_operator = operator;
            goal_value = value;
            action_node = { id = "_placeholder"; node_type = ChainRef "_"; input_mapping = []; output_key = None; depends_on = None };
            measure_func = "default";
            max_iterations = max_iter;
            strategy_hints = [];
            conversational = false;
            relay_models = [];
          })
        else
          Error (Printf.sprintf "Invalid GoalDriven format (expected metric:op:value:max_iter): %s" content)
      else if String.length content > 5 && String.sub content 0 5 = "MCTS:" then
        (* {MCTS:policy:iterations} - e.g., {MCTS:ucb1:1.41:10} or {MCTS:greedy:10} *)
        let rest = String.sub content 5 (String.length content - 5) in
        let parts = String.split_on_char ':' rest |> List.map trim in
        (match parts with
        | [policy_type; iter_str] when policy_type = "greedy" ->
            let max_iterations = Safe_parse.int ~context:"MCTS:iter" ~default:10 iter_str in
            (* Default simulation node - uses LLM to simulate outcomes *)
            let default_sim = { id = "_mcts_sim"; node_type = Llm { model = "gemini"; system = None; prompt = "Simulate and evaluate: {{input}}"; timeout = None; tools = None; prompt_ref = None; prompt_vars = []; thinking = false }; input_mapping = []; output_key = None; depends_on = None } in
            Ok (Mcts {
              strategies = [];  (* filled from edges in post-process *)
              simulation = default_sim;
              evaluator = "llm_judge";
              evaluator_prompt = None;
              policy = Greedy;
              max_iterations;
              max_depth = 5;
              expansion_threshold = 3;
              early_stop = None;
              parallel_sims = 1;
            })
        | [policy_type; param_str; iter_str] ->
            let max_iterations = Safe_parse.int ~context:"MCTS:iter" ~default:10 iter_str in
            let policy = match policy_type with
              | "ucb1" -> UCB1 (Safe_parse.float ~context:"MCTS:ucb1_param" ~default:1.41 param_str)
              | "eps" | "epsilon" -> EpsilonGreedy (Safe_parse.float ~context:"MCTS:epsilon" ~default:0.1 param_str)
              | "softmax" -> Softmax (Safe_parse.float ~context:"MCTS:softmax_temp" ~default:1.0 param_str)
              | _ -> UCB1 1.41  (* default *)
            in
            (* Default simulation node - uses LLM to simulate outcomes *)
            let default_sim = { id = "_mcts_sim"; node_type = Llm { model = "gemini"; system = None; prompt = "Simulate and evaluate: {{input}}"; timeout = None; tools = None; prompt_ref = None; prompt_vars = []; thinking = false }; input_mapping = []; output_key = None; depends_on = None } in
            Ok (Mcts {
              strategies = [];  (* filled from edges in post-process *)
              simulation = default_sim;
              evaluator = "llm_judge";
              evaluator_prompt = None;
              policy;
              max_iterations;
              max_depth = 5;
              expansion_threshold = 3;
              early_stop = None;
              parallel_sims = 1;
            })
        | _ ->
            Error (Printf.sprintf "Invalid MCTS format (expected policy:iterations or policy:param:iterations): %s" content))
      else if String.length content >= 10 && String.sub content 0 10 = "Evaluator:" then
        (* {Evaluator:scoring_func:select_strategy:min_score} - e.g., {Evaluator:llm_judge:best:0.7} *)
        let rest = String.sub content 10 (String.length content - 10) in
        let parts = String.split_on_char ':' rest |> List.map trim in
        (match parts with
        | [scoring_func; strategy_str; min_score_str] ->
            let select_strategy = match String.lowercase_ascii strategy_str with
              | "best" -> Best
              | "worst" -> Worst
              | "weighted" -> WeightedRandom
              | s when String.length s > 6 && String.sub s 0 6 = "above:" ->
                  let threshold = Safe_parse.float ~context:"Evaluator:above" ~default:0.5
                    (String.sub s 6 (String.length s - 6)) in
                  AboveThreshold threshold
              | _ -> Best
            in
            let min_score = Safe_parse.float_opt min_score_str in
            (* Candidates filled from edges in post-process *)
            Ok (Evaluator { candidates = []; scoring_func; scoring_prompt = None; select_strategy; min_score })
        | [scoring_func; strategy_str] ->
            let select_strategy = match String.lowercase_ascii strategy_str with
              | "best" -> Best
              | "worst" -> Worst
              | "weighted" -> WeightedRandom
              | s when String.length s > 6 && String.sub s 0 6 = "above:" ->
                  let threshold = Safe_parse.float ~context:"Evaluator:above" ~default:0.5
                    (String.sub s 6 (String.length s - 6)) in
                  AboveThreshold threshold
              | _ -> Best
            in
            Ok (Evaluator { candidates = []; scoring_func; scoring_prompt = None; select_strategy; min_score = None })
        | [scoring_func] ->
            Ok (Evaluator { candidates = []; scoring_func; scoring_prompt = None; select_strategy = Best; min_score = None })
        | _ ->
            Error (Printf.sprintf "Invalid Evaluator format (expected func or func:strategy or func:strategy:min_score): %s" content))
      else if String.length content > 10 && String.sub content 0 10 = "Threshold:" then
        (* {Threshold:>=0.8} or {Threshold:>0.5} or {Threshold:==1.0} etc. *)
        let rest = String.sub content 10 (String.length content - 10) in
        let parse_op_value s =
          if String.length s >= 2 && String.sub s 0 2 = ">=" then
            Some (Gte, String.sub s 2 (String.length s - 2))
          else if String.length s >= 2 && String.sub s 0 2 = "<=" then
            Some (Lte, String.sub s 2 (String.length s - 2))
          else if String.length s >= 2 && String.sub s 0 2 = "==" then
            Some (Eq, String.sub s 2 (String.length s - 2))
          else if String.length s >= 2 && String.sub s 0 2 = "!=" then
            Some (Neq, String.sub s 2 (String.length s - 2))
          else if String.length s >= 1 && String.sub s 0 1 = ">" then
            Some (Gt, String.sub s 1 (String.length s - 1))
          else if String.length s >= 1 && String.sub s 0 1 = "<" then
            Some (Lt, String.sub s 1 (String.length s - 1))
          else None
        in
        (match parse_op_value rest with
        | Some (operator, value_str) ->
            (try
              let value = float_of_string (trim value_str) in
              let placeholder_ref = { id = "_placeholder"; node_type = ChainRef "_"; input_mapping = []; output_key = None; depends_on = None } in
              Ok (Threshold { metric = "score"; operator; value; input_node = placeholder_ref; on_pass = None; on_fail = None })
            with Failure _ ->
              Error (Printf.sprintf "Invalid Threshold value: %s" value_str))
        | None ->
            Error (Printf.sprintf "Invalid Threshold operator (expected >=, >, <=, <, ==, !=): %s" content))
      else
        Error (Printf.sprintf "Diamond node must be Quorum:N, Gate:condition, Merge:strategy, GoalDriven:..., MCTS:..., Evaluator:..., or Threshold:op+value, got: %s" content)

  | `Rect ->
      (* [LLM:model "prompt"] or [LLM:model "prompt" +tools] or [Tool:name] *)
      (* First extract +tools flag from end of content *)
      let (content_clean, has_tools) = extract_tools_flag content in
      let tools = make_tools_value has_tools in
      if String.length content_clean > 4 && String.sub content_clean 0 4 = "LLM:" then
        let rest = String.sub content_clean 4 (String.length content_clean - 4) in
        (* Parse: model "prompt" or model 'prompt' or just model *)
        if Str.string_match quote_re rest 0 then
          let model = Str.matched_group 1 rest in
          let prompt = Str.matched_group 2 rest in
          Ok (Llm { model = trim model; system = None; prompt = trim prompt; timeout = None; tools; prompt_ref = None; prompt_vars = []; thinking = false })
        else if Str.string_match single_quote_re rest 0 then
          let model = Str.matched_group 1 rest in
          let prompt = Str.matched_group 2 rest in
          Ok (Llm { model = trim model; system = None; prompt = trim prompt; timeout = None; tools; prompt_ref = None; prompt_vars = []; thinking = false })
        else if Str.string_match simple_model_re rest 0 then
          let model = Str.matched_group 1 rest in
          Ok (Llm { model = trim model; system = None; prompt = "{{input}}"; timeout = None; tools; prompt_ref = None; prompt_vars = []; thinking = false })
        else
          Error (Printf.sprintf "Invalid LLM format: %s" content)
      else if String.length content_clean > 5 && String.sub content_clean 0 5 = "Tool:" then
        let rest = String.sub content_clean 5 (String.length content_clean - 5) in
        (* Try Base64 encoded args first: "name %{base64}" *)
        let base64_re = Str.regexp {|^\([^ ]+\) *%{\([^}]+\)}$|} in
        if Str.string_match base64_re rest 0 then
          let name = trim (Str.matched_group 1 rest) in
          let encoded = Str.matched_group 2 rest in
          (try
             let decoded = Base64.decode_exn encoded in
             let args = Yojson.Safe.from_string decoded in
             Ok (Tool { name; args })
           with Invalid_argument _ | Yojson.Json_error _ ->
             (* Fallback: if Base64 decode or JSON parse fails, store as-is *)
             Ok (Tool { name; args = `Assoc [("input", `String encoded)] }))
        (* Parse: name "args" or name 'args' or name {...json...} or just name *)
        else if Str.string_match quote_re rest 0 then
          let name = trim (Str.matched_group 1 rest) in
          let args_str = trim (Str.matched_group 2 rest) in
          (* Create args with "input" key holding the args string *)
          Ok (Tool { name; args = `Assoc [("input", `String args_str)] })
        else if Str.string_match single_quote_re rest 0 then
          let name = trim (Str.matched_group 1 rest) in
          let args_str = trim (Str.matched_group 2 rest) in
          Ok (Tool { name; args = `Assoc [("input", `String args_str)] })
        else
          (* Try to find name followed by JSON: "name {...}" *)
          let json_start = String.index_opt rest '{' in
          (match json_start with
           | Some idx when idx > 0 ->
               let name = trim (String.sub rest 0 idx) in
               let json_str = String.sub rest idx (String.length rest - idx) in
               (* Un-escape Mermaid quotes: \" -> " *)
               let json_unescaped = Str.global_replace (Str.regexp {|\\"|}) {|"|} json_str in
               (try
                  let args = Yojson.Safe.from_string json_unescaped in
                  Ok (Tool { name; args })
                with Yojson.Json_error _ ->
                  (* If JSON parse fails, store as input *)
                  Ok (Tool { name; args = `Assoc [("input", `String json_unescaped)] }))
           | _ ->
               (* No JSON, try simple name *)
               if Str.string_match simple_model_re rest 0 then
                 let name = trim (Str.matched_group 1 rest) in
                 Ok (Tool { name; args = `Assoc [] })
               else
                 Error (Printf.sprintf "Invalid Tool format: %s" content))
      else
        (* Default: treat as LLM with content as prompt, model = gemini *)
        Ok (Llm { model = "gemini"; system = None; prompt = content_clean; timeout = None; tools; prompt_ref = None; prompt_vars = []; thinking = false })

  | `Trap ->
      (* Trapezoid: Adapter nodes, content format: "Adapt[input → template]" or similar *)
      (* Parse the content to extract input_ref and transform type *)
      if String.length content > 5 && String.sub content 0 5 = "Adapt" then
        (* Default adapter with template transform *)
        Ok (Adapter { input_ref = "input"; transform = Template content; on_error = `Fail })
      else
        (* Generic adapter using the content as template *)
        Ok (Adapter { input_ref = "input"; transform = Template content; on_error = `Fail })

  | `Stadium ->
      (* Stadium (rounded) nodes: Retry, Fallback, Race - same logic as infer_type_from_id *)
      if String.length content >= 6 && String.sub content 0 6 = "Retry:" then
        let max_attempts = Safe_parse.int ~context:"Retry:N" ~default:3
          (String.sub content 6 (String.length content - 6)) in
        let placeholder_node = { id = "_retry_inner"; node_type = ChainRef "_retry_inner"; input_mapping = []; output_key = None; depends_on = None } in
        Ok (Retry { max_attempts; backoff = Constant 1.0; retry_on = []; node = placeholder_node })
      else if content = "Fallback" || (String.length content >= 9 && String.sub content 0 9 = "Fallback:") then
        let placeholder_primary = { id = "_fallback_primary"; node_type = ChainRef "_fallback_primary"; input_mapping = []; output_key = None; depends_on = None } in
        Ok (Fallback { primary = placeholder_primary; fallbacks = [] })
      else if content = "Race" || (String.length content >= 5 && String.sub content 0 5 = "Race:") then
        Ok (Race { nodes = []; timeout = None })
      else if String.length content >= 8 && String.sub content 0 8 = "Cascade:" then
        let rest = String.sub content 8 (String.length content - 8) in
        let parts = String.split_on_char ':' rest in
        let threshold = (match parts with
          | t :: _ -> (try float_of_string t with Failure _ -> 0.7)
          | [] -> 0.7) in
        let ctx_mode = (match parts with
          | _ :: cm :: _ -> Chain_types.context_mode_of_string cm
          | _ -> Chain_types.CM_Summary) in
        Ok (Cascade { tiers = []; confidence_prompt = None; max_escalations = 2; context_mode = ctx_mode; task_hint = None; default_threshold = threshold })
      else if content = "Cascade" then
        Ok (Cascade { tiers = []; confidence_prompt = None; max_escalations = 2; context_mode = Chain_types.CM_Summary; task_hint = None; default_threshold = 0.7 })
      else
        Ok (Llm { model = "gemini"; system = None; prompt = content; timeout = None; tools = None; prompt_ref = None; prompt_vars = []; thinking = false })

  | `Circle ->
      (* Circle nodes: MASC coordination - same logic as infer_type_from_id *)
      let content_lower = String.lowercase_ascii content in
      let stripped =
        if String.length content > 2 then
          try
            let masc_idx = Str.search_forward (Str.regexp_string "MASC:") content 0 in
            String.sub content masc_idx (String.length content - masc_idx)
          with Not_found -> content
        else content
      in
      if String.length stripped >= 14 && String.sub (String.lowercase_ascii stripped) 0 14 = "masc:broadcast" then
        let message = if String.length stripped > 15 then String.sub stripped 15 (String.length stripped - 15) else "" in
        Ok (Masc_broadcast { room = None; message; mention = [] })
      else if String.length stripped >= 11 && String.sub (String.lowercase_ascii stripped) 0 11 = "masc:listen" then
        let filter = if String.length stripped > 12 then Some (String.sub stripped 12 (String.length stripped - 12)) else None in
        Ok (Masc_listen { room = None; filter; timeout_sec = 30.0 })
      else if String.length stripped >= 10 && String.sub (String.lowercase_ascii stripped) 0 10 = "masc:claim" then
        let task_id = if String.length stripped > 11 then Some (String.sub stripped 11 (String.length stripped - 11)) else None in
        Ok (Masc_claim { room = None; task_id })
      else
        (* keyword-based heuristic before character fallback *)
        let has_word w =
          let wl = String.length w and cl = String.length content_lower in
          if wl > cl then false
          else let found = ref false in
            for i = 0 to cl - wl do
              if not !found && String.sub content_lower i wl = w then found := true
            done; !found
        in
        if has_word "wait" || has_word "listen" then
          Ok (Masc_listen { room = None; filter = None; timeout_sec = 30.0 })
        else if has_word "claim" || has_word "grab" then
          Ok (Masc_claim { room = None; task_id = None })
        (* character-based fallback *)
        else if String.contains content_lower 'b' && String.contains content_lower 'r' then
          Ok (Masc_broadcast { room = None; message = content; mention = [] })
        else if String.contains content_lower 'l' && String.contains content_lower 'i' then
          Ok (Masc_listen { room = None; filter = None; timeout_sec = 30.0 })
        else if String.contains content_lower 'c' && String.contains content_lower 'l' then
          Ok (Masc_claim { room = None; task_id = None })
        else
          Ok (Masc_broadcast { room = None; message = content; mention = [] })

