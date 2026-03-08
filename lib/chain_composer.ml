(** Chain Composer - The Chaining Designer (Neural Layer)

    This module is the "brain" of the Chain Engine, responsible for:
    1. Chain Design: Infer optimal Chain DSL from task descriptions
    2. Completion Verification: LLM-based judgment of goal achievement
    3. Evaluation Timing: Decide when to evaluate and potentially re-plan

    Architecture (Neuro-Symbolic):
    ┌─────────────────────────────────────────────────────────────┐
    │                 COMPOSER (Neural Layer)                      │
    │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │
    │  │ Chain       │  │ Completion  │  │ Evaluation          │ │
    │  │ Designer    │→ │ Verifier    │→ │ Timing Controller   │ │
    │  │ (LLM)       │  │ (LLM)       │  │ (LLM + Heuristics)  │ │
    │  └─────────────┘  └─────────────┘  └─────────────────────┘ │
    │         ↓                ↓                    ↓             │
    │  ┌──────────────────────────────────────────────────────┐  │
    │  │              CONDUCTOR (Symbolic Layer)               │  │
    │  │              (chain_executor_eio.ml)                  │  │
    │  └──────────────────────────────────────────────────────┘  │
    │         ↓                ↓                    ↓             │
    │  ┌──────────────────────────────────────────────────────┐  │
    │  │              MASC (State Layer)                       │  │
    │  │              (Task state management)                  │  │
    │  └──────────────────────────────────────────────────────┘  │
    └─────────────────────────────────────────────────────────────┘

    The Composer does NOT execute chains - it only designs and verifies.
    Actual execution is delegated to Conductor (chain_executor_eio.ml).
*)

open Chain_types
open Chain_evaluator

(** Task from MASC (simplified representation) *)
type masc_task = {
  task_id: string;
  title: string;
  description: string option;
  priority: int;              (** 1-5, lower is higher priority *)
  status: string;             (** "todo", "in_progress", "done" *)
  assignee: string option;
  metadata: (string * string) list;
}
[@@deriving yojson]

(** Composer's inference about task relationships *)
type task_relation =
  | Sequential of string * string    (** A must complete before B *)
  | Parallel of string list          (** These can run concurrently *)
  | Conditional of {
      condition_task: string;
      then_tasks: string list;
      else_tasks: string list;
    }
  | Quorum of {
      tasks: string list;
      min_success: int;
    }
[@@deriving yojson]

(** Composer's analysis result *)
type composition_analysis = {
  goal: string;                      (** Inferred high-level goal *)
  tasks: masc_task list;
  relations: task_relation list;
  estimated_duration_ms: int;
  critical_path: string list;        (** Tasks that determine total duration *)
  parallelizable_groups: string list list;
}
[@@deriving yojson]

(** Re-planning reason *)
type replan_reason =
  | TaskFailed of string             (** A task failed *)
  | GoalNotAchieved                  (** All tasks done but goal not met *)
  | NewTaskAdded of string           (** New task appeared during execution *)
  | ContextChanged                   (** External context changed *)
  | TimeoutApproaching               (** Running out of time *)
[@@deriving yojson]

(** Composer state for a composition session *)
type composer_state = {
  session_id: string;
  goal: string;
  original_tasks: masc_task list;
  current_chain: chain option;
  analysis: composition_analysis option;
  evaluation_history: evaluation_history;
  replan_count: int;
  max_replans: int;
}
[@@deriving yojson]

(* ============================================================
   Chain Design Context Builders

   These functions build prompts for LLM to design chains.
   The actual LLM call is external (via mcp_client or tools_eio).
   ============================================================ *)

(** Build context for chain design LLM call *)
let build_design_context ~(goal: string) ~(tasks: masc_task list) : string =
  let task_descriptions =
    match tasks with
    | [] ->
        [
          "No predefined tasks were supplied.";
          "Infer the minimal task decomposition needed to achieve the goal.";
          "If the goal naturally requires multiple stages, create explicit sequential or parallel nodes.";
        ]
    | _ ->
        List.mapi (fun i task ->
          Printf.sprintf "%d. [%s] %s (priority: %d)%s"
            (i + 1)
            task.task_id
            task.title
            task.priority
            (match task.description with Some d -> "\n   " ^ d | None -> "")
        ) tasks
  in

  Printf.sprintf {|## Chain Design Request

### Goal
%s

### Available Tasks
%s

### Instructions
Design an optimal execution chain for these tasks. Consider:

1. **Dependencies**: Which tasks must complete before others?
   - Look for data flow (output of A needed by B)
   - Look for ordering constraints (setup before use)

2. **Parallelization**: Which tasks can run concurrently?
   - Independent tasks should be parallel (Fanout)
   - Same-resource tasks might need sequential

3. **Error Handling**: What if a task fails?
   - Critical path tasks need careful handling
   - Non-critical tasks might be skippable

4. **Optimization**: Minimize total execution time
   - Maximize parallelism where safe
   - Consider task priorities

5. **Task Synthesis**: If no predefined tasks are supplied
   - infer the smallest useful set of nodes from the goal itself
   - prefer explicit intermediate nodes over a single catch-all node when the goal implies multiple stages

6. **Mermaid Quality Rules**
   - declare every node explicitly with an id and a label
   - do not return edge-only Mermaid like `a --> b`
   - every terminal/output step must correspond to a declared node
   - prefer concrete executable node ids such as `plan_step`, `draft_step`, `verify_step`
   - for LLM nodes use `LLM:<model> "<prompt>"`, for example `LLM:gemini "Draft the answer"`
   - for tool nodes use `Tool:<name>` or `Tool:<name> "<input>"`
   - when a node depends on an upstream node, explicitly reference that upstream output with `{{upstream_node_id}}`
   - do not create downstream nodes that ignore their incoming edges

### Expected Output Format (Chain DSL)
Return ONLY one fenced code block and nothing else.

Use Mermaid:
```mermaid
graph LR
  task_001["LLM:gemini \"Analyze the goal\""]
  task_002["LLM:gemini \"Draft the result using {{task_001}}\""]
  task_003["Tool:echo \"{{task_002}}\""]
  task_001 --> task_002
  task_002 --> task_003
```

Or JSON:
```json
{
  "type": "pipeline",
  "nodes": [
    {"type": "fanout", "nodes": ["task_001", "task_002"]},
    {"type": "quorum", "required": 2, "nodes": ["task_003", "task_004", "task_005"]}
  ]
}
```
|}
    goal
    (String.concat "\n" task_descriptions)

(** Build context for completion verification LLM call *)
let build_verification_prompt ~(goal: string) ~(metrics: chain_metrics) : string =
  (* Delegate to chain_evaluator's context builder *)
  build_verification_context ~goal ~metrics

(** Build context for re-planning LLM call *)
let build_replan_context
    ~(goal: string)
    ~(original_chain: chain)
    ~(reason: replan_reason)
    ~(metrics: chain_metrics) : string =
  let reason_str = match reason with
    | TaskFailed id -> Printf.sprintf "Task '%s' failed" id
    | GoalNotAchieved -> "All tasks completed but goal not achieved"
    | NewTaskAdded id -> Printf.sprintf "New task '%s' was added" id
    | ContextChanged -> "External context has changed"
    | TimeoutApproaching -> "Timeout is approaching"
  in

  let failed_nodes = List.filter (fun (n: node_metrics) -> n.status = Failed) metrics.node_metrics in
  let succeeded_nodes = List.filter (fun (n: node_metrics) -> n.status = Succeeded) metrics.node_metrics in

  Printf.sprintf {|## Re-Planning Request

### Original Goal
%s

### Reason for Re-Plan
%s

### Execution Status
- Total nodes: %d
- Succeeded: %d
- Failed: %d
- Pending: %d

### Failed Nodes
%s

### Succeeded Nodes (preserve these results)
%s

### Original Chain Structure
%d nodes, %d parallel groups, max depth %d

### Instructions
Create a NEW chain that:
1. Reuses successful results where possible
2. Addresses the failure/issue
3. Still achieves the original goal
4. Considers what we learned from the first attempt

Return a modified chain in the same format as design.
|}
    goal
    reason_str
    metrics.total_nodes
    metrics.nodes_succeeded
    metrics.nodes_failed
    metrics.nodes_pending
    (String.concat "\n" (List.map (fun n ->
      Printf.sprintf "- %s: %s" n.node_id
        (match n.error_message with Some e -> e | None -> "(no error message)")
    ) failed_nodes))
    (String.concat "\n" (List.map (fun n ->
      Printf.sprintf "- %s ✓" n.node_id
    ) succeeded_nodes))
    (List.length original_chain.nodes)
    (Chain_types.count_chain_parallel_groups original_chain)
    original_chain.config.max_depth

(* ============================================================
   Evaluation Timing Control

   The Composer decides WHEN to evaluate, based on:
   - Chain structure (after critical nodes)
   - Execution progress (after each parallel group)
   - Failures (immediately)
   ============================================================ *)

(** Determine evaluation triggers for a chain *)
let determine_eval_triggers ~(_chain: chain) ~(critical_path: string list) : eval_trigger list =
  let triggers = [
    (* Always evaluate on chain completion *)
    OnChainComplete;

    (* Always evaluate on failure *)
    OnFailure;
  ] in

  (* Add triggers for critical path nodes *)
  let critical_triggers = List.map (fun node_id ->
    OnNodeComplete node_id
  ) critical_path in

  triggers @ critical_triggers

(** Check if we should re-plan based on current state *)
let should_replan
    ~(state: composer_state)
    ~(metrics: chain_metrics)
    ~(verification: verification_result option) : replan_reason option =
  (* Don't replan if we've exceeded max replans *)
  if state.replan_count >= state.max_replans then
    None
  else begin
    (* Check for failures *)
    if metrics.nodes_failed > 0 then
      let failed = List.find_opt (fun (n: node_metrics) -> n.status = Failed) metrics.node_metrics in
      match failed with
      | Some n -> Some (TaskFailed n.node_id)
      | None -> None
    (* Check if goal not achieved despite completion *)
    else match verification with
    | Some v when not v.is_complete && metrics.nodes_pending = 0 ->
      Some GoalNotAchieved
    | _ ->
      None
  end

(* ============================================================
   Composer State Management
   ============================================================ *)

(** Create initial composer state *)
let init_state ~session_id ~goal ~tasks ~max_replans =
  {
    session_id;
    goal;
    original_tasks = tasks;
    current_chain = None;
    analysis = None;
    evaluation_history = {
      chain_id = session_id;
      checkpoints = [];
      final_result = None;
    };
    replan_count = 0;
    max_replans;
  }

(** Update state with new chain *)
let set_chain state chain =
  { state with current_chain = Some chain }

(** Update state with analysis *)
let set_analysis state analysis =
  { state with analysis = Some analysis }

(** Record an evaluation checkpoint *)
let add_checkpoint state ~trigger ~metrics ~decision ~reason =
  let checkpoint = {
    timestamp = Unix.gettimeofday ();
    trigger;
    metrics_snapshot = metrics;
    decision;
    decision_reason = reason;
  } in
  { state with
    evaluation_history = {
      state.evaluation_history with
      checkpoints = state.evaluation_history.checkpoints @ [checkpoint];
    }
  }

(** Increment replan counter *)
let increment_replan state =
  { state with replan_count = state.replan_count + 1 }

(** Finalize with result *)
let finalize state metrics =
  { state with
    evaluation_history = {
      state.evaluation_history with
      final_result = Some metrics;
    }
  }

(* ============================================================
   High-Level Composer Interface

   These are the main entry points for the Conductor to use.
   ============================================================ *)

(** Get design context for LLM (Conductor will make the actual call) *)
let get_design_context state =
  build_design_context ~goal:state.goal ~tasks:state.original_tasks

(** Get verification context for LLM *)
let get_verification_context state metrics =
  build_verification_prompt ~goal:state.goal ~metrics

(** Get replan context for LLM *)
let get_replan_context state reason metrics =
  match state.current_chain with
  | Some chain -> Some (build_replan_context ~goal:state.goal ~original_chain:chain ~reason ~metrics)
  | None -> None

(** Check if evaluation should happen now *)
let should_evaluate_now ~_state ~trigger ~metrics =
  should_evaluate ~trigger ~metrics

(** Decide next action based on evaluation *)
type composer_decision =
  | Continue                        (** Keep executing *)
  | Replan of replan_reason         (** Need to re-design chain *)
  | Complete of chain_metrics       (** Goal achieved, done *)
  | Abort of string                 (** Cannot achieve goal, stop *)
[@@deriving yojson]

let decide_next_action ~state ~metrics ~verification : composer_decision =
  match verification with
  | Some v when v.is_complete && v.confidence > 0.8 ->
    Complete metrics
  | _ ->
    match should_replan ~state ~metrics ~verification with
    | Some reason when state.replan_count < state.max_replans ->
      Replan reason
    | Some _ ->
      Abort "Maximum replan attempts exceeded"
    | None when metrics.nodes_failed > 0 && state.replan_count >= state.max_replans ->
      (* Failures exist but max replans exceeded - abort *)
      Abort "Maximum replan attempts exceeded with failures"
    | None when metrics.nodes_pending = 0 ->
      (* All nodes done, no replan needed - complete even with low confidence *)
      Complete metrics
    | None ->
      (* Still have pending work - continue current execution *)
      Continue

(* ============================================================
   Summary Report Generation
   ============================================================ *)

(** Generate composer session summary *)
let generate_summary state =
  let analysis_info = match state.analysis with
    | Some a -> Printf.sprintf "Goal: %s\nCritical Path: %s"
        a.goal (String.concat " → " a.critical_path)
    | None -> "(no analysis)"
  in

  Printf.sprintf {|
╔══════════════════════════════════════════════════════════════╗
║                   COMPOSER SESSION SUMMARY                    ║
╠══════════════════════════════════════════════════════════════╣
║ Session: %-52s ║
║ Replan Count: %d / %d                                         ║
╠══════════════════════════════════════════════════════════════╣
║ ANALYSIS                                                      ║
%s
╠══════════════════════════════════════════════════════════════╣
║ CHECKPOINTS: %d                                               ║
%s
╚══════════════════════════════════════════════════════════════╝
|}
    state.session_id
    state.replan_count
    state.max_replans
    analysis_info
    (List.length state.evaluation_history.checkpoints)
    (String.concat "\n" (List.mapi (fun i cp ->
      Printf.sprintf "║ %d. %s → %s"
        (i + 1)
        (match cp.trigger with
         | OnChainComplete -> "ChainComplete"
         | OnFailure -> "Failure"
         | OnNodeComplete id -> Printf.sprintf "Node:%s" id
         | _ -> "Other")
        (match cp.decision with
         | `Continue -> "Continue"
         | `Replan -> "Replan"
         | `Complete -> "Complete"
         | `Abort -> "Abort")
    ) state.evaluation_history.checkpoints))
