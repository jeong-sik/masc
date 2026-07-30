module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Tool_task_schemas — JSON schema definitions for task tools.

    Pure data module containing MCP tool schemas for all task operations.

    @since God file decomposition — extracted from tool_task.ml *)

let masc_add_task_name =
  Tool_name.Task_name.to_string Tool_name.Task_name.Add_task

let handoff_context_description =
  "Typed handoff payload. 'summary' is REQUIRED (non-empty) for exit-class \
     actions (submit_for_verification / done / release / cancel). On \
     action='submit_for_verification', every 'evidence_refs' entry must use \
     'artifact:<producer-root-relative-path>' for a bounded file snapshot or \
     'note:<text>' for narrative/commit/trace/URL evidence. Bare relative paths \
     and absolute host paths are persisted as typed invalid references. The \
     list itself is optional. Example: {\"summary\": \"tests green, local proof saved\", \
     \"evidence_refs\": [\"artifact:artifacts/proof.json\"]}."

let schemas : Masc_domain.tool_schema list = [
  {
    name = masc_add_task_name;
    description = Printf.sprintf
      "Add a new task to the backlog for agents to claim. \
Tasks default to an advisory verification contract with completion/evidence requirements. \
Only tasks with contract.strict=true must be submitted for an out-of-band completion-authority verdict; advisory/default tasks may complete directly. \
submit_for_verification creates an asynchronous review state that no agent or Keeper can claim. An authenticated human operator or typed auto judge reads the submitted evidence and commits the verdict. \
To re-run completed work, create a new task with predecessor_task_id instead of touching the done one. \
Priority 1=urgent, 5=low (default 3). \
Returns task-XXX ID for tracking. \
Example: %s({title: 'Fix login bug', priority: 1, description: 'Users cannot login with SSO'})"
      masc_add_task_name;
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("title", `Assoc [
          ("type", `String "string");
          ("description", `String "Task title");
        ]);
        ("priority", `Assoc [
          ("type", `String "integer");
          ("description", `String "Priority 1-5 (1=highest)");
          ("default", `Int 3);
        ]);
        ("description", `Assoc [
          ("type", `String "string");
          ("description", `String "Task description");
        ]);
        ("goal_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional structured goal link for rollups. If omitted, the task is created unscoped (goalless); pass goal_id explicitly to link it to a goal.");
        ]);
        ("predecessor_task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional re-run provenance link (RFC-0323): the terminal (done/cancelled) task this one re-runs. Rejected if the id is unknown or the predecessor is not terminal. To re-run completed work, create a new task with this link instead of re-claiming the old one.");
        ]);
        ("contract", `Assoc [
          ("type", `String "object");
          ("description", `String "Optional persisted task contract for strict deterministic completion gating.");
          ("properties", `Assoc [
            ("strict", `Assoc [ ("type", `String "boolean") ]);
            ("completion_contract", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
            ("required_evidence", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
            ("inspect_gate_evidence", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
            ("verify_gate_evidence", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
            ("links", `Assoc [
              ("type", `String "object");
              ("properties", `Assoc [
                ("operation_id", `Assoc [ ("type", `String "string") ]);
                ("session_id", `Assoc [ ("type", `String "string") ]);
              ]);
            ]);
          ]);
        ]);
      ]);
      ("required", `List [`String "title"]);
    ];
  };
  {
    name = "masc_batch_add_tasks";
    description = Printf.sprintf
      "Add multiple tasks in one call (more efficient than repeated %s). \
Use when: loading sprint backlog, importing from JIRA, creating related tasks. \
Tasks default to the same advisory verification contract/evidence requirements as %s. \
Each task gets unique ID (task-XXX). Atomic: all succeed or all fail. \
Example: masc_batch_add_tasks({tasks: [{title: 'Task A', priority: 2}, {title: 'Task B', goal_id: 'g-124'}]})"
      masc_add_task_name
      masc_add_task_name;
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("tasks", `Assoc [
          ("type", `String "array");
          ("maxItems", `Int 20);
          ("items", `Assoc [
            ("type", `String "object");
            ("properties", `Assoc [
              ("title", `Assoc [
                ("type", `String "string");
                ("description", `String "Task title");
              ]);
              ("priority", `Assoc [
                ("type", `String "integer");
                ("description", `String "Priority 1-5 (1=highest)");
                ("default", `Int 3);
              ]);
              ("description", `Assoc [
                ("type", `String "string");
                ("description", `String "Task description");
              ]);
              ("goal_id", `Assoc [
                ("type", `String "string");
                ("description", `String "Optional structured goal link for rollups. If omitted, the task is created unscoped (goalless); pass goal_id explicitly to link it to a goal.");
              ]);
              ("contract", `Assoc [
                ("type", `String "object");
                ("properties", `Assoc [
                  ("strict", `Assoc [ ("type", `String "boolean") ]);
                  ("completion_contract", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
                  ("required_evidence", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
                  ("inspect_gate_evidence", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
                  ("verify_gate_evidence", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
                ]);
              ]);
            ]);
            ("required", `List [`String "title"]);
          ]);
          ("description", `String "List of tasks to add");
        ]);
      ]);
      ("required", `List [`String "tasks"]);
    ];
  };
  {
    name = "masc_task_history";
    description = "Fetch recent task transition history from event logs. Useful for audits or debugging transitions.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID to filter (e.g., 'task-001')");
        ]);
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description", `String "Max events to return (default: 50)");
          ("default", `Int 50);
        ]);
      ]);
      ("required", `List [`String "task_id"]);
    ];
  };
  {
    name = "masc_tasks";
    description = "List tasks in backlog with their status and assignee. \
Defaults to active tasks (todo/claimed/in_progress/awaiting_verification). \
Use include_done/include_cancelled or status to filter. \
awaiting_verification tasks are pending a completion-authority verdict and are not claimable agent work. \
Output includes task ID, title, priority, assignee, timestamps. \
Tip: Look for status='todo' tasks to claim.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("status", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional status filter: todo|claimed|in_progress|awaiting_verification|done|cancelled");
        ]);
        ("include_done", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Include done tasks (default: false)");
          ("default", `Bool false);
        ]);
        ("include_cancelled", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Include cancelled tasks (default: false)");
          ("default", `Bool false);
        ]);
      ]);
    ];
  };

  {
    name = "masc_update_priority";
    description = "Change the priority of a task. Priority 1 is highest (most urgent), 5 is lowest. Use this to reprioritize work based on new information or urgency changes.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID to update");
        ]);
        ("priority", `Assoc [
          ("type", `String "integer");
          ("description", `String "New priority (1=highest, 5=lowest)");
          ("minimum", `Int 1);
          ("maximum", `Int 5);
        ]);
      ]);
      ("required", `List [`String "task_id"; `String "priority"]);
    ];
  };
  {
    name = "masc_transition";
    description =
      "Move a Task through the agent actions claim, start, submit_for_verification, done, cancel, or release. Ownership is exact and cannot be overridden by caller arguments. Direct done is terminal for advisory/default tasks. Tasks with contract.strict=true require the assignee to submit completion evidence, then wait for an authenticated human-operator or typed auto-judge verdict outside this tool. approve/reject are deliberately unavailable here. Supports expected_version CAS.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name");
        ]);
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID (e.g., 'task-001')");
        ]);
        ("action", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent transition action: claim | start | submit_for_verification | done | cancel | release");
          ("enum", `List (List.map (fun action -> `String action) Masc_domain.valid_task_action_strings));
        ]);
        ("expected_version", `Assoc [
          ("type", `String "integer");
          ("description", `String "Optional CAS guard (current backlog.version). Transition fails if mismatched");
        ]);
        ("notes", `Assoc [
          ("type", `String "string");
          ("description", `String "Evidence summary for submit_for_verification, or completion notes for done");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Cancellation reason (used with action='cancel')");
        ]);
        ("handoff_context", `Assoc [
          ("type", `String "object");
          ("description", `String handoff_context_description);
          ("properties", `Assoc [
            ("summary", `Assoc [
              ("type", `String "string");
              ("minLength", `Int 1);
              ("description", `String "REQUIRED. Non-empty one-line summary of current state at release time. Example: 'tests green, PR #123 pending review'.");
            ]);
            ("reason", `Assoc [
              ("type", `String "string");
              ("description", `String "Why the task is being released (blocker, handoff, pause).");
            ]);
            ("next_step", `Assoc [
              ("type", `String "string");
              ("description", `String "What the next owner should do first.");
            ]);
            ("failure_mode", `Assoc [
              ("type", `String "string");
              ("description", `String "If released due to failure, describe the failure mode.");
            ]);
            ("reclaim_policy", `Assoc [
              ("type", `String "string");
              ("enum", `List [ `String "allow_reclaim"; `String "block_reclaim" ]);
              ("description", `String "Explicit reclaim policy. Omit or use allow_reclaim for normal handoff. Use block_reclaim only for deterministic terminal mismatches that must require operator review.");
            ]);
            ("evidence_refs", `Assoc [
              ("type", `String "array");
              ("items", `Assoc [ ("type", `String "string"); ("minLength", `Int 1) ]);
              ("description", `String "Typed verifier evidence. Use artifact:<producer-root-relative-path> for files or note:<text> for narrative, commit, trace, receipt, or URL evidence. Bare and absolute paths are invalid.");
            ]);
          ]);
          ("required", `List [`String "summary"]);
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "task_id"; `String "action"]);
    ];
  };
  (* RFC-0267 Phase 2: assign an existing goalless task to a goal. *)
  {
    name = "masc_task_set_goal";
    description = "Assign an existing, currently goalless task to a goal. Both task_id and goal_id are required and validated against the backlog and the goal store; an unknown id is rejected (never silently ignored or auto-picked). A task that already has a goal is rejected — reassignment is out of scope.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "ID of the task to assign");
        ]);
        ("goal_id", `Assoc [
          ("type", `String "string");
          ("description", `String "ID of the goal to assign the task to");
        ]);
      ]);
      ("required", `List [`String "task_id"; `String "goal_id"]);
    ];
  };
]
