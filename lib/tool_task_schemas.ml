(** Tool_task_schemas — JSON schema definitions for task tools.

    Pure data module containing MCP tool schemas for all task operations.

    @since God file decomposition — extracted from tool_task.ml *)

let schemas : Types.tool_schema list = [
  {
    name = "masc_add_task";
    description = "Add a new task to the backlog for agents to claim. \
Tasks default to an advisory verification contract with completion/evidence requirements. \
Normal status flow is todo → claimed → awaiting_verification → done/cancelled when verification FSM is enabled. \
Priority 1=urgent, 5=low (default 3). \
Returns task-XXX ID for tracking. \
Example: masc_add_task({title: 'Fix login bug', priority: 1, description: 'Users cannot login with SSO'})";
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
          ("description", `String "REQUIRED for goal rollup visibility. Set this to one of the active_goal_ids from your system prompt <available_goals> block. Tasks without a goal_id are orphaned and do not contribute to goal progress tracking.");
        ]);
        ("required_preset", `Assoc [
          ("type", `String "string");
          ("description", `String "Tool preset required to claim this task. Must match a preset name from tool_policy.toml (e.g., 'dispatch', 'delivery', 'coding'). Only keepers whose preset covers the required tools can claim. Omit for any agent.");
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
                ("autoresearch_loop_id", `Assoc [ ("type", `String "string") ]);
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
    description = "Add multiple tasks in one call (more efficient than repeated masc_add_task). \
Use when: loading sprint backlog, importing from JIRA, creating related tasks. \
Tasks default to the same advisory verification contract/evidence requirements as masc_add_task. \
Each task gets unique ID (task-XXX). Atomic: all succeed or all fail. \
Example: masc_batch_add_tasks({tasks: [{title: 'Task A', priority: 2}, {title: 'Task B'}]})";
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
                ("description", `String "REQUIRED for goal rollup visibility. Set this to one of the active_goal_ids from your system prompt <available_goals> block. Tasks without a goal_id are orphaned and do not contribute to goal progress tracking.");
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
Defaults to active tasks (todo/claimed/in_progress). \
Use include_done/include_cancelled or status to filter. \
Output includes task ID, title, priority, assignee, timestamps. \
Tip: Look for status='todo' tasks to claim.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("status", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional status filter: todo|claimed|in_progress|done|cancelled");
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
    name = "masc_claim_next";
    description = "Automatically claim the highest priority unclaimed task. Use this when you want to pick up the most important available work without manually checking the task board. Returns the claimed task details including priority level.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name");
        ]);
      ]);
      ("required", `List [`String "agent_name"]);
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
    description = "Move a task through its lifecycle: claim, start, done, cancel, release, \
submit_for_verification, approve, or reject. \
Call when you pick up, finish, or abandon a task. Supports CAS via expected_version. \
After masc_add_task or masc_claim_next; pair with masc_deliver before action='done'. \
Use submit_for_verification to request cross-agent review; approve/reject for verifier actions. \
Tasks created through masc_add_task normally route action='done' into awaiting_verification rather than final done.";
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
          ("description", `String "Transition action: claim | start | done | cancel | release | submit_for_verification | approve | reject");
        ]);
        ("expected_version", `Assoc [
          ("type", `String "integer");
          ("description", `String "Optional CAS guard (current backlog.version). Transition fails if mismatched");
        ]);
        ("notes", `Assoc [
          ("type", `String "string");
          ("description", `String "Completion notes (used with action='done')");
        ]);
        ("completion_contract", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [ ("type", `String "string") ]);
          ("description", `String "Optional acceptance checklist that completion notes must satisfy before action='done' is accepted");
        ]);
        ("evaluator_cascade", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional evaluator cascade override for anti-rationalization review. Default: cross_verifier");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Cancellation reason (used with action='cancel')");
        ]);
        ("handoff_context", `Assoc [
          ("type", `String "object");
          ("description", `String "Typed handoff payload used when action='release' on strict contract tasks. 'summary' is REQUIRED and must be a non-empty string. Example: {\"summary\": \"tests green, PR #123 pending review\", \"next_step\": \"wait for CI\", \"evidence_refs\": [\"PR#123\"]}.");
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
            ("evidence_refs", `Assoc [
              ("type", `String "array");
              ("items", `Assoc [ ("type", `String "string") ]);
              ("description", `String "PR numbers, file paths, log links substantiating summary.");
            ]);
          ]);
          ("required", `List [`String "summary"]);
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "task_id"; `String "action"]);
    ];
  };
]
