(** Autonomy Trace Analyzer — quantify whether agent behavior is
    autonomous, scripted, or random.

    Pure computation over {!Raw_trace.run_summary} values.
    No LLM calls, no IO. *)

(* ── Types ─────────────────────────────────────────────────── *)

type worker_metric =
  { diversity : float
  ; unique_tool_count : int
  ; total_calls : int
  ; turn_count : int
  ; tool_set : string list
  }
[@@deriving yojson, show]

type divergence =
  { jaccard_distance : float
  ; shared_tools : string list
  ; exclusive_a : string list
  ; exclusive_b : string list
  }
[@@deriving yojson, show]

type classification =
  | Autonomous
  | Scripted
  | Random
  | Insufficient_data
[@@deriving yojson, show]

type verdict =
  { classification : classification
  ; confidence : float
  ; evidence : string list
  ; metrics : worker_metric list
  ; mean_diversity : float
  ; mean_divergence : float
  ; pairwise_divergences : divergence list
  }
[@@deriving yojson, show]

type thresholds =
  { diversity_autonomous : float
  ; diversity_scripted : float
  ; divergence_autonomous : float
  ; divergence_scripted : float
  ; min_unique_tools : int
  ; random_divergence : float
    (** divergence above this with low diversity → Random (default 0.8) *)
  }

let default_thresholds =
  { diversity_autonomous = 0.3
  ; diversity_scripted = 0.15
  ; divergence_autonomous = 0.15
  ; divergence_scripted = 0.05
  ; min_unique_tools = 3
  ; random_divergence = 0.8
  }
;;

(* ── Helpers ───────────────────────────────────────────────── *)

module SSet = Set.Make (String)

let set_of_list xs = List.fold_left (fun acc x -> SSet.add x acc) SSet.empty xs
let sorted_elements s = SSet.elements s |> List.sort String.compare

let mean xs =
  match xs with
  | [] -> 0.0
  | _ ->
    let sum = List.fold_left ( +. ) 0.0 xs in
    sum /. Float.of_int (List.length xs)
;;

(* ── Core functions ────────────────────────────────────────── *)

let metric_of_summary (s : Raw_trace.run_summary) : worker_metric =
  let tool_set = s.tool_names in
  let unique_tool_count = List.length tool_set in
  let total_calls = s.tool_execution_started_count in
  let diversity =
    if total_calls = 0
    then 0.0
    else Float.of_int unique_tool_count /. Float.of_int total_calls
  in
  let turn_count = s.assistant_block_count in
  { diversity; unique_tool_count; total_calls; turn_count; tool_set }
;;

let divergence_of_pair (a : worker_metric) (b : worker_metric) : divergence =
  let set_a = set_of_list a.tool_set in
  let set_b = set_of_list b.tool_set in
  let intersection = SSet.inter set_a set_b in
  let union = SSet.union set_a set_b in
  let jaccard_distance =
    let union_size = SSet.cardinal union in
    if union_size = 0
    then 0.0
    else (
      let inter_size = SSet.cardinal intersection in
      1.0 -. (Float.of_int inter_size /. Float.of_int union_size))
  in
  let shared_tools = sorted_elements intersection in
  let exclusive_a = sorted_elements (SSet.diff set_a set_b) in
  let exclusive_b = sorted_elements (SSet.diff set_b set_a) in
  { jaccard_distance; shared_tools; exclusive_a; exclusive_b }
;;

let all_pairs (xs : 'a list) : ('a * 'a) list =
  let rec go acc = function
    | [] -> List.rev acc
    | x :: rest ->
      let pairs = List.map (fun y -> x, y) rest in
      go (List.rev_append pairs acc) rest
  in
  go [] xs
;;

let classify
      ~(t : thresholds)
      ~mean_div
      ~mean_divg
      ~min_unique
      ~(metrics : worker_metric list)
      ~(n : int)
  : classification * float * string list
  =
  if n < 1
  then Insufficient_data, 0.0, [ "no summaries provided" ]
  else (
    let evidence = ref [] in
    let add e = evidence := e :: !evidence in
    add (Printf.sprintf "workers=%d" n);
    add (Printf.sprintf "mean_diversity=%.3f" mean_div);
    if n >= 2 then add (Printf.sprintf "mean_divergence=%.3f" mean_divg);
    add (Printf.sprintf "min_unique_tools=%d" min_unique);
    (* Scoring *)
    let diversity_ok = mean_div >= t.diversity_autonomous in
    let diversity_low = mean_div < t.diversity_scripted in
    let divergence_ok = n < 2 || mean_divg >= t.divergence_autonomous in
    let divergence_low = n >= 2 && mean_divg < t.divergence_scripted in
    let tools_ok = min_unique >= t.min_unique_tools in
    (* Single-worker case: can only assess diversity *)
    if n = 1
    then (
      add "single_worker: divergence not measurable";
      if diversity_ok && tools_ok
      then (
        add "PASS: diversity and tool count meet thresholds";
        Autonomous, 0.6, List.rev !evidence)
      else if diversity_low
      then (
        add "FAIL: diversity below scripted threshold";
        Scripted, 0.7, List.rev !evidence)
      else (
        add "INCONCLUSIVE: single worker, moderate diversity";
        Insufficient_data, 0.4, List.rev !evidence))
    else (
      (* Multi-worker case *)
      let score = ref 0.0 in
      if diversity_ok
      then (
        score := !score +. 0.3;
        add "PASS: diversity >= threshold")
      else if diversity_low
      then add "FAIL: diversity < scripted threshold"
      else add "WARN: diversity between thresholds";
      if divergence_ok
      then (
        score := !score +. 0.4;
        add "PASS: divergence >= threshold")
      else if divergence_low
      then add "FAIL: divergence < scripted threshold"
      else add "WARN: divergence between thresholds";
      if tools_ok
      then (
        score := !score +. 0.3;
        add "PASS: unique tools >= minimum")
      else add "FAIL: unique tools < minimum";
      (* Check for random: high divergence but low diversity *)
      let has_low_diversity =
        List.exists
          (fun (m : worker_metric) -> m.diversity < t.diversity_scripted)
          metrics
      in
      let has_high_divergence = mean_divg > t.random_divergence in
      if has_high_divergence && has_low_diversity
      then (
        add "RANDOM: high divergence but low diversity suggests random tool use";
        Random, 0.6, List.rev !evidence)
      else if !score >= 0.7
      then (
        add (Printf.sprintf "VERDICT: autonomous (score=%.1f)" !score);
        Autonomous, !score, List.rev !evidence)
      else if divergence_low || diversity_low
      then (
        add (Printf.sprintf "VERDICT: scripted (score=%.1f)" !score);
        Scripted, Float.max 0.5 (1.0 -. !score), List.rev !evidence)
      else (
        add (Printf.sprintf "VERDICT: insufficient evidence (score=%.1f)" !score);
        Insufficient_data, 0.4, List.rev !evidence)))
;;

let analyze ?(thresholds = default_thresholds) (summaries : Raw_trace.run_summary list)
  : verdict
  =
  let metrics = List.map metric_of_summary summaries in
  let n = List.length metrics in
  let mean_diversity = mean (List.map (fun (m : worker_metric) -> m.diversity) metrics) in
  let pairs = all_pairs metrics in
  let pairwise_divergences = List.map (fun (a, b) -> divergence_of_pair a b) pairs in
  let mean_divergence =
    mean (List.map (fun (d : divergence) -> d.jaccard_distance) pairwise_divergences)
  in
  let min_unique =
    match metrics with
    | [] -> 0
    | _ ->
      List.fold_left
        (fun acc (m : worker_metric) -> min acc m.unique_tool_count)
        Int.max_int
        metrics
  in
  let classification, confidence, evidence =
    classify
      ~t:thresholds
      ~mean_div:mean_diversity
      ~mean_divg:mean_divergence
      ~min_unique
      ~metrics
      ~n
  in
  { classification
  ; confidence
  ; evidence
  ; metrics
  ; mean_diversity
  ; mean_divergence
  ; pairwise_divergences
  }
;;

let verdict_to_json (v : verdict) : Yojson.Safe.t = verdict_to_yojson v
