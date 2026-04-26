(** Eval_harness — Scenario-based behavioral evaluation for Keeper agents.

    Defines evaluation scenarios, graders, and metrics for measuring
    keeper agent quality. Inspired by METR Task Standard and
    OpenAI Harness Engineering patterns.

    Architecture:
    - Scenario: goal + setup + expected outcomes + graders
    - Grader: deterministic (exact/contains/regex) or MODEL-based
    - Runner: execute scenario, apply graders, produce EvalResult
    - Metrics: pass@k, mean score, consistency

    @since 2.73.0 *)

(* ================================================================ *)
(* Grader types                                                      *)
(* ================================================================ *)

type match_mode =
  | Exact            (** Exact string match *)
  | Contains         (** Substring match *)
  | Regex of string  (** OCaml Str regex pattern *)
  | NotContains      (** Must NOT contain the string *)

type deterministic_grader = {
  field : string;           (** Which field to check: "result", "tool_name", "error" *)
  expected : string;        (** Expected value or pattern *)
  mode : match_mode;        (** How to compare *)
  weight : float;           (** Score weight 0.0-1.0 *)
  description : string;     (** Human-readable description of what this checks *)
}

type model_grader = {
  prompt_template : string;   (** Template with {result}, {goal} placeholders *)
  rubric : string;            (** Scoring rubric for the MODEL *)
  weight : float;             (** Score weight 0.0-1.0 *)
  description : string;
}

type grader =
  | Deterministic of deterministic_grader
  | ModelBased of model_grader

(* ================================================================ *)
(* Scenario types                                                    *)
(* ================================================================ *)

type tool_expectation = {
  tool_name : string;            (** Expected tool to be called *)
  required : bool;               (** Must this tool be called? *)
  max_calls : int option;        (** Max times this tool should be called *)
  args_contain : string option;  (** Args should contain this substring *)
}

type scenario = {
  id : string;                        (** Unique scenario identifier *)
  name : string;                      (** Human-readable name *)
  description : string;               (** What this scenario tests *)
  category : string;                  (** "safety", "capability", "efficiency" *)
  goal : string;                      (** The goal to give the keeper *)
  setup_messages : string list;       (** Context messages before the goal *)
  expected_outcome : string;          (** What should happen (for reporting) *)
  tool_expectations : tool_expectation list;
  graders : grader list;
  max_turns : int;                    (** Max turns before timeout *)
  max_cost_usd : float;              (** Cost budget for this scenario *)
  tags : string list;                 (** Filtering tags: "regression", "smoke", etc. *)
}

(* ================================================================ *)
(* Evaluation result types                                           *)
(* ================================================================ *)

type grader_result = {
  grader_desc : string;
  score : float;           (** 0.0-1.0 *)
  weight : float;
  passed : bool;           (** score >= 0.5 *)
  detail : string;         (** Why this score was given *)
}

type eval_run = {
  scenario_id : string;
  run_index : int;          (** Which run in pass@k (0-based) *)
  trace_id : string;        (** Trajectory trace_id for this run *)
  scores : grader_result list;
  weighted_score : float;   (** Weighted average of all grader scores *)
  passed : bool;            (** weighted_score >= pass_threshold *)
  tool_calls_made : string list;
  total_turns : int;
  total_cost_usd : float;
  duration_ms : int;
  outcome : Trajectory.trajectory_outcome;
  error : string option;
}

type eval_result = {
  scenario : scenario;
  runs : eval_run list;
  pass_at_k : float;       (** Probability of at least 1 pass in k runs *)
  mean_score : float;       (** Mean weighted score across runs *)
  consistency : float;      (** Std dev of scores (lower = more consistent) *)
  total_cost_usd : float;   (** Sum of all run costs *)
}

type eval_suite_result = {
  suite_name : string;
  started_at : float;
  ended_at : float;
  results : eval_result list;
  overall_pass_rate : float;  (** Fraction of scenarios that passed *)
  total_cost_usd : float;
  total_runs : int;
}

(* ================================================================ *)
(* Deterministic grading                                             *)
(* ================================================================ *)

(** Apply a deterministic grader to a value. Returns score 0.0 or 1.0. *)
let apply_deterministic_grader (g : deterministic_grader) (value : string) : grader_result =
  let matched = match g.mode with
    | Exact -> value = g.expected
    | Contains ->
        let v_lower = String.lowercase_ascii value in
        let e_lower = String.lowercase_ascii g.expected in
        let rec find_at i =
          if i + String.length e_lower > String.length v_lower then false
          else if String.sub v_lower i (String.length e_lower) = e_lower then true
          else find_at (i + 1)
        in
        find_at 0
    | Regex pattern ->
        Safe_ops.protect ~default:false (fun () ->
          let re = Re.Pcre.re pattern |> Re.compile in
          Re.execp re value)
    | NotContains ->
        let v_lower = String.lowercase_ascii value in
        let e_lower = String.lowercase_ascii g.expected in
        let rec find_at i =
          if i + String.length e_lower > String.length v_lower then true
          else if String.sub v_lower i (String.length e_lower) = e_lower then false
          else find_at (i + 1)
        in
        find_at 0
  in
  let score = if matched then 1.0 else 0.0 in
  { grader_desc = g.description;
    score;
    weight = g.weight;
    passed = matched;
    detail = if matched
      then Printf.sprintf "matched: %s" g.description
      else Printf.sprintf "failed: expected %s '%s'" (match g.mode with
        | Exact -> "exact" | Contains -> "contains"
        | Regex _ -> "regex" | NotContains -> "not_contains") g.expected;
  }

(** Check tool expectations against actual tool calls made. *)
let check_tool_expectations
    (expectations : tool_expectation list)
    (actual_calls : string list)
    : grader_result list =
  List.map (fun (exp : tool_expectation) ->
    let call_count = List_util.count_if (fun c -> c = exp.tool_name) actual_calls in
    let required_ok = if exp.required then call_count > 0 else true in
    let max_ok = match exp.max_calls with
      | None -> true
      | Some max -> call_count <= max
    in
    let passed = required_ok && max_ok in
    let detail =
      if not required_ok then
        Printf.sprintf "required tool '%s' was not called" exp.tool_name
      else if not max_ok then
        Printf.sprintf "tool '%s' called %d times (max: %d)"
          exp.tool_name call_count (Option.value ~default:0 exp.max_calls)
      else
        Printf.sprintf "tool '%s' called %d times — OK" exp.tool_name call_count
    in
    { grader_desc = Printf.sprintf "tool_expectation: %s" exp.tool_name;
      score = if passed then 1.0 else 0.0;
      weight = 0.5;  (* tool expectations are secondary to content graders *)
      passed;
      detail;
    }
  ) expectations

(* ================================================================ *)
(* Score computation                                                 *)
(* ================================================================ *)

(** Compute weighted average score from grader results. *)
let weighted_score (results : grader_result list) : float =
  let total_weight = List.fold_left (fun acc r -> acc +. r.weight) 0.0 results in
  if total_weight = 0.0 then 0.0
  else
    let weighted_sum = List.fold_left (fun acc r -> acc +. (r.score *. r.weight)) 0.0 results in
    weighted_sum /. total_weight

(** Compute pass@k: probability that at least one of k runs passes.
    Formula: 1 - C(n-c, k) / C(n, k)
    where n = total runs, c = passing runs, k = sample size.

    Simplified: if all k runs available, pass@k = 1 - (1-p)^k
    where p = c/n (empirical pass rate). *)
let compute_pass_at_k ~(k : int) ~(n : int) ~(c : int) : float =
  if n = 0 || k = 0 then 0.0
  else if c >= n then 1.0
  else
    let p = float_of_int c /. float_of_int n in
    1.0 -. (1.0 -. p) ** float_of_int (min k n)

(** Compute standard deviation of scores (consistency metric). *)
let score_std_dev (scores : float list) : float =
  match scores with
  | [] | [_] -> 0.0
  | _ ->
      let n = float_of_int (List.length scores) in
      let mean = List.fold_left (+.) 0.0 scores /. n in
      let variance = List.fold_left (fun acc s ->
        acc +. (s -. mean) ** 2.0) 0.0 scores /. n in
      sqrt variance

(** Build eval_result from a list of eval_runs for one scenario. *)
let summarize_runs ~(scenario : scenario) ~(k : int) (runs : eval_run list) : eval_result =
  let n = List.length runs in
  let c = List_util.count_if (fun r -> r.passed) runs in
  let scores = List.map (fun r -> r.weighted_score) runs in
  let mean = if n = 0 then 0.0
    else List.fold_left (+.) 0.0 scores /. float_of_int n in
  let total_cost = List.fold_left (fun a (r : eval_run) -> a +. r.total_cost_usd) 0.0 runs in
  { scenario;
    runs;
    pass_at_k = compute_pass_at_k ~k ~n ~c;
    mean_score = mean;
    consistency = score_std_dev scores;
    total_cost_usd = total_cost;
  }

(* ================================================================ *)
(* JSON serialization                                                *)
(* ================================================================ *)

let match_mode_to_string = function
  | Exact -> "exact"
  | Contains -> "contains"
  | Regex p -> Printf.sprintf "regex(%s)" p
  | NotContains -> "not_contains"

let grader_result_to_json (r : grader_result) : Yojson.Safe.t =
  `Assoc [
    ("grader", `String r.grader_desc);
    ("score", `Float r.score);
    ("weight", `Float r.weight);
    ("passed", `Bool r.passed);
    ("detail", `String r.detail);
  ]

let eval_run_to_json (r : eval_run) : Yojson.Safe.t =
  `Assoc [
    ("scenario_id", `String r.scenario_id);
    ("run_index", `Int r.run_index);
    ("trace_id", `String r.trace_id);
    ("weighted_score", `Float r.weighted_score);
    ("passed", `Bool r.passed);
    ("tool_calls", `List (List.map (fun s -> `String s) r.tool_calls_made));
    ("total_turns", `Int r.total_turns);
    ("total_cost_usd", `Float r.total_cost_usd);
    ("duration_ms", `Int r.duration_ms);
    ("outcome", Trajectory.outcome_to_json r.outcome);
    ("error", Json_util.string_opt_to_json r.error);
    ("scores", `List (List.map grader_result_to_json r.scores));
  ]

let eval_result_to_json (r : eval_result) : Yojson.Safe.t =
  `Assoc [
    ("scenario_id", `String r.scenario.id);
    ("scenario_name", `String r.scenario.name);
    ("category", `String r.scenario.category);
    ("pass_at_k", `Float r.pass_at_k);
    ("mean_score", `Float r.mean_score);
    ("consistency", `Float r.consistency);
    ("total_cost_usd", `Float r.total_cost_usd);
    ("num_runs", `Int (List.length r.runs));
    ("runs", `List (List.map eval_run_to_json r.runs));
  ]

let suite_result_to_json (r : eval_suite_result) : Yojson.Safe.t =
  `Assoc [
    ("suite_name", `String r.suite_name);
    ("started_at", `Float r.started_at);
    ("ended_at", `Float r.ended_at);
    ("overall_pass_rate", `Float r.overall_pass_rate);
    ("total_cost_usd", `Float r.total_cost_usd);
    ("total_runs", `Int r.total_runs);
    ("results", `List (List.map eval_result_to_json r.results));
  ]

let scenario_to_json (s : scenario) : Yojson.Safe.t =
  `Assoc [
    ("id", `String s.id);
    ("name", `String s.name);
    ("description", `String s.description);
    ("category", `String s.category);
    ("goal", `String s.goal);
    ("max_turns", `Int s.max_turns);
    ("max_cost_usd", `Float s.max_cost_usd);
    ("tags", `List (List.map (fun s -> `String s) s.tags));
    ("graders", `Int (List.length s.graders));
    ("tool_expectations", `Int (List.length s.tool_expectations));
  ]

(* ================================================================ *)
(* Scenario parsing from JSON                                        *)
(* ================================================================ *)

(** Parse a scenario from JSON (loaded from YAML→JSON or direct JSON). *)
let scenario_of_json (json : Yojson.Safe.t) : (scenario, string) result =
  try
    let open Yojson.Safe.Util in
    let str key = json |> member key |> to_string in
    let str_opt key default =
      match json |> member key with
      | `String s -> s
      | _ -> default
    in
    let int_opt key default =
      match json |> member key with
      | `Int i -> i
      | _ -> default
    in
    let float_opt key default =
      match json |> member key with
      | `Float f -> f
      | `Int i -> float_of_int i
      | _ -> default
    in
    let str_list key =
      match json |> member key with
      | `List items -> List.filter_map (function `String s -> Some s | _ -> None) items
      | _ -> []
    in

    (* Per-grader JSON field helpers (using grader JSON, not scenario JSON) *)
    let g_str_opt g key default =
      match g |> member key with
      | `String s -> s
      | _ -> default
    in
    let g_float_opt g key default =
      match g |> member key with
      | `Float f -> f
      | `Int i -> float_of_int i
      | _ -> default
    in

    (* Parse graders.
       #8605 family: the prior dispatch used a nested string match
       where the inner [_ -> Contains] branch was provably unreachable
       (the outer guard already constrained mode_str to one of four
       literals). Lifting the mode mapping into the outer match
       eliminates the dead silent-default branch and surfaces a future
       grader-mode addition as a build hole at the per-arm level. *)
    let parse_deterministic g mode =
      Deterministic {
        field = g_str_opt g "field" "result";
        expected = (match g |> member "expected" with
          | `String s -> s
          | _ -> g |> member "pattern" |> to_string);
        mode;
        weight = g_float_opt g "weight" 1.0;
        description = g_str_opt g "description" "unnamed grader";
      }
    in
    let graders =
      match json |> member "graders" with
      | `List items ->
          List.filter_map (fun g ->
            match g |> member "type" |> to_string with
            | "exact" -> Some (parse_deterministic g Exact)
            | "contains" -> Some (parse_deterministic g Contains)
            | "not_contains" -> Some (parse_deterministic g NotContains)
            | "regex" ->
                Some (parse_deterministic g
                        (Regex (g |> member "pattern" |> to_string)))
            | "model" ->
                Some (ModelBased {
                  prompt_template = g |> member "prompt" |> to_string;
                  rubric = g_str_opt g "rubric" "";
                  weight = g_float_opt g "weight" 1.0;
                  description = g_str_opt g "description" "MODEL grader";
                })
            | _ -> None
          ) items
      | _ -> []
    in

    (* Parse tool expectations *)
    let tool_expectations =
      match json |> member "tool_expectations" with
      | `List items ->
          List.filter_map (fun te ->
            try Some {
              tool_name = te |> member "tool" |> to_string;
              required = (match te |> member "required" with
                | `Bool b -> b | _ -> false);
              max_calls = (match te |> member "max_calls" with
                | `Int i -> Some i | _ -> None);
              args_contain = (match te |> member "args_contain" with
                | `String s -> Some s | _ -> None);
            }
            with Yojson.Safe.Util.Type_error _ -> None
          ) items
      | _ -> []
    in

    Ok {
      id = str "id";
      name = str_opt "name" "";
      description = str_opt "description" "";
      category = str_opt "category" "general";
      goal = str "goal";
      setup_messages = str_list "setup_messages";
      expected_outcome = str_opt "expected_outcome" "";
      tool_expectations;
      graders;
      max_turns = int_opt "max_turns" 5;
      max_cost_usd = float_opt "max_cost_usd" 0.10;
      tags = str_list "tags";
    }
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    Error (Printf.sprintf "Failed to parse scenario: %s" (Printexc.to_string exn))

(** Load scenarios from a JSON file containing an array of scenario objects. *)
let load_scenarios_from_file (path : string) : (scenario list, string) result =
  if not (Sys.file_exists path) then
    Error (Printf.sprintf "Scenario file not found: %s" path)
  else
    try
      let content = Fs_compat.load_file path in
      let json = Yojson.Safe.from_string content in
      match json with
      | `List items ->
          let results = List.map scenario_of_json items in
          let errors = List.filter_map (function Error e -> Some e | Ok _ -> None) results in
          if errors <> [] then
            Error (Printf.sprintf "Parse errors: %s" (String.concat "; " errors))
          else
            Ok (List.filter_map (function Ok s -> Some s | Error _ -> None) results)
      | `Assoc _ ->
          (* Single scenario *)
          (match scenario_of_json json with
           | Ok s -> Ok [s]
           | Error e -> Error e)
      | _ -> Error "Expected JSON array or object"
    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      Error (Printf.sprintf "Failed to load scenarios: %s" (Printexc.to_string exn))

(* ================================================================ *)
(* Report generation                                                 *)
(* ================================================================ *)

(** Generate a human-readable report from suite results. *)
let report_to_string (r : eval_suite_result) : string =
  let buf = Buffer.create 2048 in
  let add = Buffer.add_string buf in
  add (Printf.sprintf "=== Eval Suite: %s ===\n" r.suite_name);
  add (Printf.sprintf "Runs: %d | Pass Rate: %.1f%% | Cost: $%.4f\n\n"
    r.total_runs (r.overall_pass_rate *. 100.0) r.total_cost_usd);

  List.iter (fun (er : eval_result) ->
    let status = if er.pass_at_k >= 0.5 then "PASS" else "FAIL" in
    add (Printf.sprintf "[%s] %s (%s)\n" status er.scenario.name er.scenario.category);
    add (Printf.sprintf "  pass@k=%.2f  mean=%.2f  consistency=%.3f  cost=$%.4f\n"
      er.pass_at_k er.mean_score er.consistency er.total_cost_usd);
    List.iter (fun (run : eval_run) ->
      let run_status = if run.passed then "ok" else "FAIL" in
      add (Printf.sprintf "  run[%d] %s score=%.2f turns=%d cost=$%.4f %s\n"
        run.run_index run_status run.weighted_score
        run.total_turns run.total_cost_usd
        (Trajectory.outcome_to_string run.outcome));
    ) er.runs;
    add "\n";
  ) r.results;

  Buffer.contents buf

(** Write suite results as JSONL (one line per eval_result). *)
let write_results_jsonl ~(path : string) (r : eval_suite_result) : unit =
  let buf = Buffer.create 4096 in
  (* Header line *)
  Buffer.add_string buf (Yojson.Safe.to_string (suite_result_to_json r));
  Buffer.add_char buf '\n';
  (* Per-result lines *)
  List.iter (fun er ->
    Buffer.add_string buf (Yojson.Safe.to_string (eval_result_to_json er));
    Buffer.add_char buf '\n'
  ) r.results;
  Fs_compat.save_file path (Buffer.contents buf)
