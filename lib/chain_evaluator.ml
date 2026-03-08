(** Chain Evaluator - Self-evaluation and completion verification for Chaining Designer

    This module provides:
    - Metrics collection for chain execution
    - Completion verification (is the goal really achieved?)
    - Evaluation timing control (when to trigger evaluation)

    The Chaining Designer (Composer) uses this module to:
    1. Track execution metrics
    2. Verify completion with LLM-based judgment
    3. Decide when to evaluate and potentially re-plan

    Architecture:
    ┌─────────────────────────────────────────────────────────┐
    │                    Composer (Designer)                   │
    │  ┌─────────────────────────────────────────────────┐   │
    │  │              chain_evaluator.ml                  │   │
    │  │  ┌──────────┐  ┌──────────┐  ┌──────────────┐  │   │
    │  │  │ Metrics  │→ │ Verify   │→ │ Timing       │  │   │
    │  │  │ Collect  │  │ Complete │  │ Control      │  │   │
    │  │  └──────────┘  └──────────┘  └──────────────┘  │   │
    │  └─────────────────────────────────────────────────┘   │
    └─────────────────────────────────────────────────────────┘
*)

(** Node execution status *)
type node_status =
  | Pending      (** Not started *)
  | Running      (** In progress *)
  | Succeeded    (** Completed successfully *)
  | Failed       (** Failed with error *)
  | Skipped      (** Skipped (gate condition false) *)
  | Retrying     (** Retrying after failure *)
[@@deriving yojson]

(** Individual node metrics *)
type node_metrics = {
  node_id: string;
  node_type: string;                 (** "llm", "tool", "pipeline", etc. *)
  status: node_status;
  started_at: float option;          (** Unix timestamp *)
  completed_at: float option;
  duration_ms: int;
  estimated_duration_ms: int option; (** Composer's estimation *)
  retry_count: int;
  error_message: string option;
  output_preview: string option;     (** First 200 chars of output *)
}
[@@deriving yojson]

(** Evaluation trigger condition *)
type eval_trigger =
  | OnNodeComplete of string         (** Evaluate when specific node completes *)
  | OnGroupComplete of string list   (** Evaluate when all nodes in group complete *)
  | OnChainComplete                  (** Evaluate when entire chain completes *)
  | OnFailure                        (** Evaluate immediately on any failure *)
  | OnTimeout                        (** Evaluate on timeout *)
  | Periodic of int                  (** Evaluate every N seconds *)
[@@deriving yojson]

(** Completion verification result *)
type verification_result = {
  is_complete: bool;                 (** Did the chain achieve its goal? *)
  confidence: float;                 (** 0.0 - 1.0 confidence score *)
  reason: string;                    (** Explanation from LLM *)
  missing_criteria: string list;     (** What's still missing? *)
  suggested_next_steps: string list; (** If incomplete, what to do? *)
}
[@@deriving yojson]

(** Chain-level metrics *)
type chain_metrics = {
  chain_id: string;
  goal: string;                      (** Original goal description *)
  started_at: float;
  completed_at: float option;
  total_duration_ms: int;

  (* Node statistics *)
  total_nodes: int;
  nodes_succeeded: int;
  nodes_failed: int;
  nodes_skipped: int;
  nodes_pending: int;

  (* Structural metrics *)
  parallel_groups: int;
  max_depth: int;

  (* Performance metrics *)
  success_rate: float;               (** nodes_succeeded / total_executed *)
  parallelization_efficiency: float; (** actual_time / sequential_estimate *)
  estimation_accuracy: float;        (** how close to estimated duration *)

  (* Detailed node metrics *)
  node_metrics: node_metrics list;

  (* Verification result (filled by Composer) *)
  verification: verification_result option;
}
[@@deriving yojson]

(** Evaluation checkpoint - snapshot at a point in time *)
type checkpoint = {
  timestamp: float;
  trigger: eval_trigger;
  metrics_snapshot: chain_metrics;
  decision: [ `Continue | `Replan | `Abort | `Complete ];
  decision_reason: string;
}
[@@deriving yojson]

(** Full evaluation history for a chain *)
type evaluation_history = {
  chain_id: string;
  checkpoints: checkpoint list;
  final_result: chain_metrics option;
}
[@@deriving yojson]

(* ============================================================
   Metrics Collection Functions
   ============================================================ *)

let empty_node_metrics ~node_id ~node_type = {
  node_id;
  node_type;
  status = Pending;
  started_at = None;
  completed_at = None;
  duration_ms = 0;
  estimated_duration_ms = None;
  retry_count = 0;
  error_message = None;
  output_preview = None;
}

let empty_chain_metrics ~chain_id ~goal = {
  chain_id;
  goal;
  started_at = Unix.gettimeofday ();
  completed_at = None;
  total_duration_ms = 0;
  total_nodes = 0;
  nodes_succeeded = 0;
  nodes_failed = 0;
  nodes_skipped = 0;
  nodes_pending = 0;
  parallel_groups = 0;
  max_depth = 0;
  success_rate = 0.0;
  parallelization_efficiency = 0.0;
  estimation_accuracy = 0.0;
  node_metrics = [];
  verification = None;
}

(** Update node metrics on start *)
let mark_node_started (metrics: node_metrics) : node_metrics =
  { metrics with
    status = Running;
    started_at = Some (Unix.gettimeofday ());
  }

(** Update node metrics on completion *)
let mark_node_completed (metrics: node_metrics) ~output_preview : node_metrics =
  let now = Unix.gettimeofday () in
  let duration = match metrics.started_at with
    | Some start -> int_of_float ((now -. start) *. 1000.0)
    | None -> 0
  in
  { metrics with
    status = Succeeded;
    completed_at = Some now;
    duration_ms = duration;
    output_preview = Some (String.sub output_preview 0 (min 200 (String.length output_preview)));
  }

(** Update node metrics on failure *)
let mark_node_failed (metrics: node_metrics) ~error_message : node_metrics =
  let now = Unix.gettimeofday () in
  let duration = match metrics.started_at with
    | Some start -> int_of_float ((now -. start) *. 1000.0)
    | None -> 0
  in
  { metrics with
    status = Failed;
    completed_at = Some now;
    duration_ms = duration;
    error_message = Some error_message;
  }

(** Calculate chain-level statistics from node metrics *)
let calculate_chain_stats (metrics: chain_metrics) : chain_metrics =
  let nodes = metrics.node_metrics in
  let total = List.length nodes in
  let succeeded = List.length (List.filter (fun n -> n.status = Succeeded) nodes) in
  let failed = List.length (List.filter (fun n -> n.status = Failed) nodes) in
  let skipped = List.length (List.filter (fun n -> n.status = Skipped) nodes) in
  let pending = List.length (List.filter (fun n -> n.status = Pending || n.status = Running) nodes) in

  let executed = succeeded + failed in
  let success_rate = if executed > 0 then float_of_int succeeded /. float_of_int executed else 0.0 in

  (* Calculate estimation accuracy *)
  let estimation_accuracy =
    let with_estimates = List.filter (fun n ->
      n.estimated_duration_ms <> None && n.duration_ms > 0
    ) nodes in
    if List.length with_estimates = 0 then 1.0
    else
      let total_accuracy = List.fold_left (fun acc n ->
        match n.estimated_duration_ms with
        | Some est when est > 0 ->
          let actual = float_of_int n.duration_ms in
          let estimated = float_of_int est in
          acc +. (min actual estimated /. max actual estimated)
        | _ -> acc
      ) 0.0 with_estimates in
      total_accuracy /. float_of_int (List.length with_estimates)
  in

  { metrics with
    total_nodes = total;
    nodes_succeeded = succeeded;
    nodes_failed = failed;
    nodes_skipped = skipped;
    nodes_pending = pending;
    success_rate;
    estimation_accuracy;
  }

(* ============================================================
   Evaluation Timing Control
   ============================================================ *)

(** Check if evaluation should be triggered based on current state *)
let should_evaluate ~(trigger: eval_trigger) ~(metrics: chain_metrics) : bool =
  match trigger with
  | OnNodeComplete node_id ->
    List.exists (fun n ->
      n.node_id = node_id &&
      (n.status = Succeeded || n.status = Failed)
    ) metrics.node_metrics

  | OnGroupComplete node_ids ->
    List.for_all (fun node_id ->
      List.exists (fun n ->
        n.node_id = node_id &&
        (n.status = Succeeded || n.status = Failed || n.status = Skipped)
      ) metrics.node_metrics
    ) node_ids

  | OnChainComplete ->
    metrics.nodes_pending = 0

  | OnFailure ->
    metrics.nodes_failed > 0

  | OnTimeout ->
    (* Check if any node has exceeded timeout - simplified check *)
    List.exists (fun n ->
      n.status = Running &&
      match n.started_at with
      | Some start -> Unix.gettimeofday () -. start > 300.0  (* 5 min default *)
      | None -> false
    ) metrics.node_metrics

  | Periodic interval ->
    let elapsed = Unix.gettimeofday () -. metrics.started_at in
    int_of_float elapsed mod interval = 0

(* ============================================================
   Completion Verification Context Builder

   This builds context for LLM to verify if the goal is achieved.
   The actual LLM call is done by Composer using this context.
   ============================================================ *)

(** Build verification context for Composer's LLM call *)
let build_verification_context ~(goal: string) ~(metrics: chain_metrics) : string =
  let node_summaries = List.map (fun n ->
    Printf.sprintf "- %s (%s): %s%s"
      n.node_id
      n.node_type
      (match n.status with
       | Pending -> "⏳ pending"
       | Running -> "🔄 running"
       | Succeeded -> "✅ succeeded"
       | Failed -> "❌ failed"
       | Skipped -> "⏭️ skipped"
       | Retrying -> "🔁 retrying")
      (match n.output_preview with
       | Some preview -> Printf.sprintf " → \"%s...\"" preview
       | None -> "")
  ) metrics.node_metrics in

  Printf.sprintf {|## Goal Verification Context

### Original Goal
%s

### Execution Summary
- Total nodes: %d
- Succeeded: %d
- Failed: %d
- Skipped: %d
- Success rate: %.1f%%
- Total duration: %dms

### Node Results
%s

### Question for Verification
Based on the above execution results, has the original goal been achieved?
Consider:
1. Did all critical steps complete successfully?
2. Are there any failures that prevent goal completion?
3. Is the output quality sufficient for the goal?

Respond with:
- is_complete: true/false
- confidence: 0.0-1.0
- reason: explanation
- missing_criteria: [] (if incomplete)
- suggested_next_steps: [] (if incomplete)|}
    goal
    metrics.total_nodes
    metrics.nodes_succeeded
    metrics.nodes_failed
    metrics.nodes_skipped
    (metrics.success_rate *. 100.0)
    metrics.total_duration_ms
    (String.concat "\n" node_summaries)

(** Parse LLM verification response into structured result *)
let parse_verification_response (response: string) : verification_result =
  let starts_with ~prefix s =
    let prefix_len = String.length prefix in
    String.length s >= prefix_len && String.sub s 0 prefix_len = prefix
  in
  let try_parse_json_block s =
    let json_pattern = Str.regexp "```json\n\\([^`]+\\)```" in
    try
      let _ = Str.search_forward json_pattern s 0 in
      Some (Str.matched_group 1 s)
    with Not_found ->
      (* Fallback: extract first JSON object-like block *)
      match (String.index_opt s '{', String.rindex_opt s '}') with
      | (Some l, Some r) when r > l -> Some (String.sub s l (r - l + 1))
      | _ -> None
  in
  let parse_string_list json key =
    let open Yojson.Safe.Util in
    match json |> member key with
    | `List items ->
        List.filter_map (fun v ->
          try Some (to_string v) with _ -> None
        ) items
    | `String s -> [s]
    | _ -> []
  in
  let strip_markdown s =
    let buf = Buffer.create (String.length s) in
    String.iter (fun c ->
      if c <> '*' && c <> '`' then Buffer.add_char buf c
    ) s;
    Buffer.contents buf
  in
  let drop_leading_non_key s =
    let len = String.length s in
    let rec find i =
      if i >= len then len
      else
        let c = s.[i] in
        if (c >= 'a' && c <= 'z') || c = '_' then i else find (i + 1)
    in
    let i = find 0 in
    if i >= len then s else String.sub s i (len - i)
  in
  let parse_bool_from_line line =
    let trimmed =
      line
      |> String.trim
      |> String.lowercase_ascii
      |> strip_markdown
      |> String.trim
    in
    match String.index_opt trimmed ':' with
    | None -> false
    | Some idx ->
        let value = String.sub trimmed (idx + 1) (String.length trimmed - idx - 1) |> String.trim in
        let value =
          value
          |> String.trim
          |> String.lowercase_ascii
          |> String.trim
        in
        let value = String.trim value in
        let value = if String.length value > 0 && value.[String.length value - 1] = ',' then
          String.sub value 0 (String.length value - 1) else value in
        let value =
          if String.length value >= 2 && value.[0] = '"' && value.[String.length value - 1] = '"' then
            String.sub value 1 (String.length value - 2)
          else value
        in
        value = "true" || value = "yes"
  in
  (* 1) JSON-first parsing (if present) *)
  let parsed_json =
    match try_parse_json_block response with
    | None -> None
    | Some json_str ->
        (try Some (Yojson.Safe.from_string json_str)
         with Yojson.Json_error _ -> None)
  in
  (match parsed_json with
  | Some json ->
      let open Yojson.Safe.Util in
      let is_complete =
        match json |> member "is_complete" with
        | `Bool b -> b
        | `String s -> (String.lowercase_ascii (String.trim s) = "true")
        | _ -> false
      in
      let confidence =
        match json |> member "confidence" with
        | `Float f -> f
        | `Int i -> float_of_int i
        | `String s -> (try float_of_string s with _ -> if is_complete then 0.9 else 0.3)
        | _ -> if is_complete then 0.9 else 0.3
      in
      let reason =
        match json |> member "reason" with
        | `String s -> s
        | _ -> response
      in
      let missing_criteria = parse_string_list json "missing_criteria" in
      let suggested_next_steps = parse_string_list json "suggested_next_steps" in
      { is_complete; confidence; reason; missing_criteria; suggested_next_steps }
  | None ->
  let keys = [
    "is_complete";
    "complete";
    "completed";
    "goal_achieved";
    "goal achieved";
    "achieved";
    "result";
  ] in
  let is_complete =
    match List.find_opt (fun l ->
      let t =
        l
        |> String.trim
        |> String.lowercase_ascii
        |> strip_markdown
        |> String.trim
        |> drop_leading_non_key
      in
      List.exists (fun key -> starts_with ~prefix:key t) keys
    ) (String.split_on_char '\n' response) with
    | Some line -> parse_bool_from_line line
    | None -> false
  in
  {
    is_complete;
    confidence = if is_complete then 0.9 else 0.3;
    reason = response;
    missing_criteria = [];
    suggested_next_steps = [];
  })

(* ============================================================
   Evaluation Report Generation
   ============================================================ *)

(** Generate human-readable evaluation report *)
let generate_report ~(history: evaluation_history) : string =
  let final = match history.final_result with
    | Some m -> m
    | None -> empty_chain_metrics ~chain_id:history.chain_id ~goal:"(unknown)"
  in

  let checkpoint_lines = List.mapi (fun i cp ->
    Printf.sprintf "  %d. [%s] %s → %s"
      (i + 1)
      (match cp.trigger with
       | OnNodeComplete id -> Printf.sprintf "Node:%s" id
       | OnGroupComplete ids -> Printf.sprintf "Group:%d nodes" (List.length ids)
       | OnChainComplete -> "ChainComplete"
       | OnFailure -> "Failure"
       | OnTimeout -> "Timeout"
       | Periodic n -> Printf.sprintf "Periodic:%ds" n)
      (match cp.decision with
       | `Continue -> "▶️ Continue"
       | `Replan -> "🔄 Replan"
       | `Abort -> "🛑 Abort"
       | `Complete -> "✅ Complete")
      cp.decision_reason
  ) history.checkpoints in

  Printf.sprintf {|
╔══════════════════════════════════════════════════════════════╗
║                   CHAIN EVALUATION REPORT                     ║
╠══════════════════════════════════════════════════════════════╣
║ Chain ID: %-50s ║
║ Goal: %-54s ║
╠══════════════════════════════════════════════════════════════╣
║ EXECUTION SUMMARY                                             ║
║ ─────────────────────────────────────────────────────────────║
║ Duration: %6dms    Success Rate: %5.1f%%                      ║
║ Nodes: %3d total | %3d ✅ | %3d ❌ | %3d ⏭️                   ║
║ Estimation Accuracy: %5.1f%%                                  ║
╠══════════════════════════════════════════════════════════════╣
║ EVALUATION CHECKPOINTS (%d total)                             ║
║ ─────────────────────────────────────────────────────────────║
%s
╠══════════════════════════════════════════════════════════════╣
║ VERIFICATION RESULT                                           ║
║ ─────────────────────────────────────────────────────────────║
%s
╚══════════════════════════════════════════════════════════════╝
|}
    final.chain_id
    (String.sub final.goal 0 (min 54 (String.length final.goal)))
    final.total_duration_ms
    (final.success_rate *. 100.0)
    final.total_nodes
    final.nodes_succeeded
    final.nodes_failed
    final.nodes_skipped
    (final.estimation_accuracy *. 100.0)
    (List.length history.checkpoints)
    (String.concat "\n" checkpoint_lines)
    (match final.verification with
     | Some v -> Printf.sprintf "║ Complete: %s  Confidence: %.0f%%\n║ %s"
         (if v.is_complete then "YES ✅" else "NO ❌")
         (v.confidence *. 100.0)
         v.reason
     | None -> "║ (Not yet verified)")
