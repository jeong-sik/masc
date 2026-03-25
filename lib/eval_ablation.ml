(** Eval_ablation — Component ablation testing infrastructure.

    Answers the question: "Is this harness component load-bearing?"

    Architecture:
    - Component: named feature with classification (model-compensating vs coordination)
    - Ablation result: baseline vs ablated suite comparison
    - Statistical significance: two-proportion z-test on pass@k
    - Lift: quantified impact of each component

    Classification criterion: "Would a team of perfect human engineers
    still need this component?"
    - Yes -> Coordination (keep: heartbeat, task claiming, room management)
    - No  -> Model-compensating scaffolding (ablation candidate)

    @since #3074 — Harness Design ablation testing *)

(* ================================================================ *)
(* Component classification                                          *)
(* ================================================================ *)

type component_class =
  | Model_compensating  (** Scaffolding that compensates for model limitations.
                            Should become unnecessary as models improve. *)
  | Coordination        (** Distributed systems infrastructure.
                            Needed regardless of model capability. *)

type component = {
  name : string;                 (** Unique identifier *)
  description : string;
  classification : component_class;
  disable_fn : string;           (** How to disable: env var or flag name *)
}

let component_class_to_string = function
  | Model_compensating -> "model_compensating"
  | Coordination -> "coordination"

(** Built-in component registry.
    Coordination components are listed for documentation but excluded
    from ablation by default. *)
let registry : component list = [
  (* Model-compensating scaffolding — ablation candidates *)
  { name = "anti_rationalization";
    description = "Multi-gate completion review (length, excuse, contract, LLM)";
    classification = Model_compensating;
    disable_fn = "MASC_DISABLE_ANTI_RAT" };
  { name = "context_compaction";
    description = "Importance-scored message compaction";
    classification = Model_compensating;
    disable_fn = "MASC_DISABLE_COMPACTION" };
  { name = "eval_calibration";
    description = "Verdict logging and few-shot calibration loop";
    classification = Model_compensating;
    disable_fn = "MASC_DISABLE_CALIBRATION" };
  { name = "dna_validation";
    description = "Mitosis DNA quality scoring before spawn";
    classification = Model_compensating;
    disable_fn = "MASC_DISABLE_DNA_VALIDATION" };
  { name = "model_aware_thresholds";
    description = "Per-model-family context ratio adjustments";
    classification = Model_compensating;
    disable_fn = "MASC_DISABLE_MODEL_THRESHOLDS" };

  (* Coordination infrastructure — not ablation targets *)
  { name = "heartbeat";
    description = "Periodic liveness signal for keeper agents";
    classification = Coordination;
    disable_fn = "MASC_DISABLE_HEARTBEAT" };
  { name = "task_claiming";
    description = "Distributed task claim with conflict detection";
    classification = Coordination;
    disable_fn = "MASC_DISABLE_TASK_CLAIMING" };
  { name = "room_management";
    description = "Room lifecycle and agent presence tracking";
    classification = Coordination;
    disable_fn = "MASC_DISABLE_ROOM_MGMT" };
  { name = "broadcast";
    description = "Cross-agent message broadcasting";
    classification = Coordination;
    disable_fn = "MASC_DISABLE_BROADCAST" };
]

let ablatable_components () : component list =
  List.filter (fun c -> c.classification = Model_compensating) registry

let find_component (name : string) : component option =
  List.find_opt (fun c -> c.name = name) registry

(* ================================================================ *)
(* Statistical comparison                                            *)
(* ================================================================ *)

(** Two-proportion z-test.
    Tests whether two proportions p1 = x1/n1 and p2 = x2/n2 differ
    significantly.
    Returns (z_statistic, p_value_two_tailed). *)
let two_proportion_z_test ~(x1 : int) ~(n1 : int) ~(x2 : int) ~(n2 : int)
  : float * float =
  if n1 = 0 || n2 = 0 then (0.0, 1.0)
  else
    let p1 = float_of_int x1 /. float_of_int n1 in
    let p2 = float_of_int x2 /. float_of_int n2 in
    let p_pool =
      float_of_int (x1 + x2) /. float_of_int (n1 + n2) in
    let se =
      sqrt (p_pool *. (1.0 -. p_pool) *.
            (1.0 /. float_of_int n1 +. 1.0 /. float_of_int n2)) in
    if se < 1e-10 then (0.0, 1.0)
    else
      let z = (p1 -. p2) /. se in
      (* Approximate two-tailed p-value using normal CDF.
         Uses Abramowitz & Stegun approximation 26.2.17. *)
      let abs_z = Float.abs z in
      let t = 1.0 /. (1.0 +. 0.2316419 *. abs_z) in
      let d = 0.3989422804014327 (* 1/sqrt(2*pi) *) in
      let p_tail =
        d *. exp (-0.5 *. abs_z *. abs_z)
        *. (t *. (0.319381530
                   +. t *. (-0.356563782
                            +. t *. (1.781477937
                                     +. t *. (-1.821255978
                                              +. t *. 1.330274429))))) in
      (z, 2.0 *. p_tail)

(* ================================================================ *)
(* Ablation result types                                             *)
(* ================================================================ *)

type scenario_comparison = {
  scenario_id : string;
  scenario_name : string;
  baseline_pass_at_k : float;
  ablated_pass_at_k : float;
  baseline_mean_score : float;
  ablated_mean_score : float;
  lift : float;                  (** (baseline - ablated) / baseline. >0 means component helps *)
  z_stat : float;
  p_value : float;
  significant : bool;            (** p_value < alpha *)
}

type ablation_result = {
  component : component;
  alpha : float;                 (** Significance level (default 0.05) *)
  comparisons : scenario_comparison list;
  overall_lift : float;          (** Mean lift across all scenarios *)
  significant_count : int;       (** Number of scenarios with p < alpha *)
  verdict : string;              (** "load_bearing" | "redundant" | "inconclusive" *)
}

(* ================================================================ *)
(* Comparison logic                                                  *)
(* ================================================================ *)

(** Compare two eval_suite_results scenario by scenario.
    [baseline] = component enabled (normal), [ablated] = component disabled. *)
let compare_suites
    ~(component : component)
    ?(alpha = 0.05)
    ~(baseline : Eval_harness.eval_suite_result)
    ~(ablated : Eval_harness.eval_suite_result)
    () : ablation_result =
  (* Build map of ablated results by scenario_id *)
  let ablated_map = Hashtbl.create 16 in
  List.iter (fun (r : Eval_harness.eval_result) ->
    Hashtbl.replace ablated_map r.scenario.id r
  ) ablated.results;
  (* Compare each baseline scenario *)
  let comparisons = List.filter_map (fun (br : Eval_harness.eval_result) ->
    match Hashtbl.find_opt ablated_map br.scenario.id with
    | None -> None
    | Some ar ->
      let b_passes = List.length (List.filter (fun (r : Eval_harness.eval_run) -> r.passed) br.runs) in
      let b_total = List.length br.runs in
      let a_passes = List.length (List.filter (fun (r : Eval_harness.eval_run) -> r.passed) ar.runs) in
      let a_total = List.length ar.runs in
      let z_stat, p_value =
        two_proportion_z_test ~x1:b_passes ~n1:b_total ~x2:a_passes ~n2:a_total in
      let lift =
        if br.pass_at_k < 1e-10 then 0.0
        else (br.pass_at_k -. ar.pass_at_k) /. br.pass_at_k in
      Some {
        scenario_id = br.scenario.id;
        scenario_name = br.scenario.name;
        baseline_pass_at_k = br.pass_at_k;
        ablated_pass_at_k = ar.pass_at_k;
        baseline_mean_score = br.mean_score;
        ablated_mean_score = ar.mean_score;
        lift;
        z_stat;
        p_value;
        significant = p_value < alpha;
      }
  ) baseline.results in
  let significant_count =
    List.length (List.filter (fun c -> c.significant) comparisons) in
  let overall_lift =
    if comparisons = [] then 0.0
    else
      let sum = List.fold_left (fun acc c -> acc +. c.lift) 0.0 comparisons in
      sum /. float_of_int (List.length comparisons) in
  let verdict =
    if comparisons = [] then "inconclusive"
    else if significant_count > 0 && overall_lift > 0.05 then "load_bearing"
    else if significant_count = 0 && Float.abs overall_lift < 0.02 then "redundant"
    else "inconclusive"
  in
  { component; alpha; comparisons; overall_lift; significant_count; verdict }

(* ================================================================ *)
(* JSON serialization                                                *)
(* ================================================================ *)

let scenario_comparison_to_json (c : scenario_comparison) : Yojson.Safe.t =
  `Assoc [
    ("scenario_id", `String c.scenario_id);
    ("scenario_name", `String c.scenario_name);
    ("baseline_pass_at_k", `Float c.baseline_pass_at_k);
    ("ablated_pass_at_k", `Float c.ablated_pass_at_k);
    ("baseline_mean_score", `Float c.baseline_mean_score);
    ("ablated_mean_score", `Float c.ablated_mean_score);
    ("lift", `Float c.lift);
    ("z_stat", `Float c.z_stat);
    ("p_value", `Float c.p_value);
    ("significant", `Bool c.significant);
  ]

let ablation_result_to_json (r : ablation_result) : Yojson.Safe.t =
  `Assoc [
    ("component", `String r.component.name);
    ("classification", `String (component_class_to_string r.component.classification));
    ("alpha", `Float r.alpha);
    ("overall_lift", `Float r.overall_lift);
    ("significant_count", `Int r.significant_count);
    ("verdict", `String r.verdict);
    ("comparisons", `List (List.map scenario_comparison_to_json r.comparisons));
  ]

(* ================================================================ *)
(* Report generation                                                 *)
(* ================================================================ *)

let report_to_string (r : ablation_result) : string =
  let buf = Buffer.create 1024 in
  let add = Buffer.add_string buf in
  add (Printf.sprintf "=== Ablation: %s (%s) ===\n"
    r.component.name (component_class_to_string r.component.classification));
  add (Printf.sprintf "Verdict: %s | Lift: %.1f%% | Significant: %d/%d scenarios\n\n"
    r.verdict (r.overall_lift *. 100.0)
    r.significant_count (List.length r.comparisons));
  List.iter (fun (c : scenario_comparison) ->
    let sig_marker = if c.significant then "*" else " " in
    add (Printf.sprintf "%s %-30s  pass@k: %.2f -> %.2f  lift: %+.1f%%  z=%.2f  p=%.4f\n"
      sig_marker c.scenario_name
      c.baseline_pass_at_k c.ablated_pass_at_k
      (c.lift *. 100.0) c.z_stat c.p_value)
  ) r.comparisons;
  Buffer.contents buf

(** Run ablation analysis for all model-compensating components.
    Takes a function that executes a suite with optional disabled component. *)
let run_all_ablations
    ?(alpha = 0.05)
    ~(run_suite : ?disable:string -> unit -> Eval_harness.eval_suite_result)
    () : ablation_result list =
  let baseline = run_suite () in
  List.map (fun component ->
    let ablated = run_suite ~disable:component.disable_fn () in
    compare_suites ~component ~alpha ~baseline ~ablated ()
  ) (ablatable_components ())
