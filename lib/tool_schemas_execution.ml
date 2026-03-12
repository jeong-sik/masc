open Types

let schemas : tool_schema list = [
  {
    name = "masc_execute";
    description = "Execute an action based on council decision. \
Matches topic pattern (e.g., 'Merge PR #123') and runs corresponding action.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("topic", `Assoc [
          ("type", `String "string");
          ("description", `String "The decision topic (e.g., 'Merge PR #456')");
        ]);
        ("result", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "unanimous"; `String "majority"; `String "deadlock"]);
          ("description", `String "Voting result (default: majority)");
        ]);
      ]);
      ("required", `List [`String "topic"]);
    ];
  };
  {
    name = "masc_execute_dry_run";
    description = "Dry run - show what action would be taken without executing.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("topic", `Assoc [
          ("type", `String "string");
          ("description", `String "The decision topic");
        ]);
        ("result", `Assoc [
          ("type", `String "string");
          ("description", `String "Voting result");
        ]);
      ]);
      ("required", `List [`String "topic"]);
    ];
  };
  {
    name = "masc_run_init";
    description = "Initialize execution memory for a task. Creates .masc/runs/{task_id}/ to track plan, notes, and deliverables.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID to track");
        ]);
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent working on the task");
        ]);
      ]);
      ("required", `List [`String "task_id"; `String "agent_name"]);
    ];
  };
  {
    name = "masc_run_plan";
    description = "Set or update the execution plan for a task run. \
Use at start of work to document your approach. Supports markdown. \
Plan is versioned - updates create new revision. Other agents can view via masc_run_get. \
Example: masc_run_plan({task_id: 'task-001', plan: '## Steps\\n1. Analyze code\\n2. Write tests\\n3. Refactor'})";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID");
        ]);
        ("plan", `Assoc [
          ("type", `String "string");
          ("description", `String "The plan (markdown supported)");
        ]);
      ]);
      ("required", `List [`String "task_id"; `String "plan"]);
    ];
  };
  {
    name = "masc_run_log";
    description = "Add a timestamped note to task's execution log. \
Use for: progress updates, blockers found, decisions made, key findings. \
Auto-timestamps with ISO8601. Creates audit trail for handoffs. \
Example: masc_run_log({task_id: 'task-001', note: 'Found 3 failing tests in auth module'})";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID");
        ]);
        ("note", `Assoc [
          ("type", `String "string");
          ("description", `String "Note to add (will be timestamped)");
        ]);
      ]);
      ("required", `List [`String "task_id"; `String "note"]);
    ];
  };
  {
    name = "masc_run_deliverable";
    description = "Record the final deliverable/output of a task run. Marks the run as completed.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID");
        ]);
        ("deliverable", `Assoc [
          ("type", `String "string");
          ("description", `String "The deliverable (markdown supported)");
        ]);
      ]);
      ("required", `List [`String "task_id"; `String "deliverable"]);
    ];
  };
  {
    name = "masc_run_get";
    description = "Get full execution history for a task as markdown. \
Returns: plan, logs (timestamped), and deliverable if completed. \
Use when: resuming work, reviewing progress, preparing handoff. \
Example: masc_run_get({task_id: 'task-001'}) → '## Plan\\n...\\n## Logs\\n- 10:00 Started...'";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID to retrieve");
        ]);
      ]);
      ("required", `List [`String "task_id"]);
    ];
  };
  {
    name = "masc_run_list";
    description = "List all task runs with status (active/completed). \
Shows: task_id, has_plan, log_count, has_deliverable. \
Use to find: abandoned work, completed runs for review, active executions. \
Example response: [{task_id: 'task-001', status: 'active', logs: 5}]";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_bounded_run";
    description = "Run multi-agent loop with formal constraints. Guarantees: termination (hard_max_iterations), safety (post-check prevents silent violations), predictive limits (token_buffer). Use for autonomous agent collaboration with budget control.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agents", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "List of agents to use in round-robin: ['gemini', 'codex', 'claude']");
        ]);
        ("prompt", `Assoc [
          ("type", `String "string");
          ("description", `String "Initial prompt for agents");
        ]);
        ("constraints", `Assoc [
          ("type", `String "object");
          ("description", `String "Execution limits");
          ("properties", `Assoc [
            ("max_turns", `Assoc [
              ("type", `String "integer");
              ("description", `String "Maximum agent turns (default: 10)");
            ]);
            ("max_tokens", `Assoc [
              ("type", `String "integer");
              ("description", `String "Maximum total tokens (default: 100000)");
            ]);
            ("max_cost_usd", `Assoc [
              ("type", `String "number");
              ("description", `String "Maximum cost in USD (default: 1.0)");
            ]);
            ("max_time_seconds", `Assoc [
              ("type", `String "number");
              ("description", `String "Maximum wall-clock time (default: 300)");
            ]);
            ("token_buffer", `Assoc [
              ("type", `String "integer");
              ("description", `String "Buffer for predictive token limit (default: 5000)");
            ]);
            ("hard_max_iterations", `Assoc [
              ("type", `String "integer");
              ("description", `String "Absolute failsafe iteration limit (default: 100)");
            ]);
          ]);
        ]);
        ("goal", `Assoc [
          ("type", `String "object");
          ("description", `String "Termination condition");
          ("properties", `Assoc [
            ("path", `Assoc [
              ("type", `String "string");
              ("description", `String "JSONPath to check in agent output, e.g., '$.status' or '$.result.done'");
            ]);
            ("condition", `Assoc [
              ("type", `String "object");
              ("description", `String "Comparison: {eq: value}, {gte: 0.95}, {lt: 5}, {in: ['done', 'success']}");
            ]);
          ]);
          ("required", `List [`String "path"; `String "condition"]);
        ]);
      ]);
      ("required", `List [`String "agents"; `String "prompt"; `String "goal"]);
    ];
  };
  {
    name = "masc_gardener_execute_spawn";
    description = "Execute an approved spawn: create agent in Neo4j and post announcement. Use masc_gardener_propose_spawn first to check if spawn is allowed. This action consumes daily spawn budget and resets the cooldown timer.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("topic", `Assoc [
          ("type", `String "string");
          ("description", `String "The topic/role that was approved for spawn");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Spawn reason (for audit)");
        ]);
        ("urgency", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "low"; `String "medium"; `String "high"; `String "critical"]);
          ("description", `String "Urgency level");
          ("default", `String "medium");
        ]);
      ]);
      ("required", `List [`String "topic"]);
    ];
  };
  {
    name = "masc_gardener_execute_retire";
    description = "Execute an approved retirement: initiate grace period and post warning. The agent is warned but not immediately removed — they have a grace period to increase activity. Use masc_gardener_retire_agent first to check if retirement is allowed.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Name of the agent to retire");
        ]);
      ]);
      ("required", `List [`String "agent_name"]);
    ];
  };
]
