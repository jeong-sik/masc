(** Split chunk from tools.ml; private schema registry. *)

open Types

let schemas : tool_schema list = [
  {
    name = "masc_set_room";
    description = "Point MASC at a different project's .masc/ directory. \
Use when you need to operate on a repo other than the current working directory. \
Pair with masc_init if the target project has no .masc/ yet.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("path", `Assoc [
          ("type", `String "string");
          ("description", `String "Absolute or relative path to the project directory");
        ]);
      ]);
      ("required", `List [`String "path"]);
    ];
  };

  {
    name = "masc_init";
    description = "Create the .masc/ folder to bootstrap a new MASC room in this project. \
Call once per project when no .masc/ exists yet; if it already exists you auto-join. \
After init, call masc_join to register your presence, then masc_add_task or masc_claim_next.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent identity: 'claude' (Claude Code), 'gemini' (Gemini CLI), or 'codex' (Codex CLI)");
        ]);
      ]);
    ];
  };

  {
    name = "masc_join";
    description = "Join the MASC room to collaborate with other AI agents. \
Call at session start before any task work. Your presence becomes visible to other agents \
who can @mention you. After joining, call masc_status to see active agents and tasks.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your identity: 'claude', 'gemini', or 'codex'");
        ]);
        ("capabilities", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Your strengths (e.g., ['typescript', 'code-review', 'testing'])");
        ]);
      ]);
      ("required", `List [`String "agent_name"]);
    ];
  };

  {
    name = "masc_leave";
    description = "Leave the MASC room and go offline, releasing all your locks. \
Call when your session ends, you switch rooms, or your work is complete. \
Pair with masc_join at session start; other agents see your departure via SSE.";
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
    name = "masc_status";
    description = "Return the current room snapshot: active agents, task queue, recent broadcasts, and cluster info. \
Call when you need situational awareness after masc_join or before claiming work. \
Pair with masc_agents for per-agent detail or masc_tasks for the full backlog.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_pause";
    description = "Pause the MASC room, blocking the orchestrator from spawning new agents. \
Use when you need to halt automated work temporarily (e.g., review needed, incident). \
Pair with masc_resume to lift the pause; check masc_pause_status for current state.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Reason for pausing (e.g., 'Need to review', 'Taking a break')");
          ("default", `String "Manual pause");
        ]);
      ]);
    ];
  };

  {
    name = "masc_resume";
    description = "Resume a paused MASC room, allowing the orchestrator to spawn agents again. \
Call when the pause reason is resolved (review done, incident cleared). \
After masc_pause; broadcasts resume notification to all agents.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_pause_status";
    description = "Check whether the room is currently paused and get pause reason and timestamp. \
Use when an operation fails unexpectedly to see if the room is paused. \
Pair with masc_pause to pause or masc_resume to lift.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_suspend";
    description = "Admin tool: immediately suspend a misbehaving agent, blacklisting it for a cooldown period. \
Trigger: runaway agent, security incident, or resource abuse. \
The target is forced offline and cannot rejoin until expiry. Check masc_circuit_status afterward.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("target_agent", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent ID to suspend (e.g., 'claude-abc123')");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Reason for suspension (logged for audit)");
        ]);
        ("duration_hours", `Assoc [
          ("type", `String "number");
          ("description", `String "Suspension duration in hours (default: 1.0)");
          ("default", `Float 1.0);
        ]);
      ]);
      ("required", `List [`String "target_agent"; `String "reason"]);
    ];
  };

  {
    name = "masc_circuit_status";
    description = "Check the circuit breaker state for an agent: closed (normal), half_open (testing), or open (blocked). \
Use when an agent cannot join or act and you suspect repeated failures triggered the breaker. \
Pair with masc_suspend to force-open or masc_gardener_reset_circuit to clear.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent ID to check (optional, defaults to caller)");
        ]);
      ]);
    ];
  };

  {
    name = "masc_add_task";
    description = "Add a single task to the backlog (status: todo, priority 1-5, default 3). \
Use when you identify new work that any agent can pick up. Returns a task-XXX ID. \
After adding, agents claim via masc_claim_next or masc_transition(action='claim').";
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
      ]);
      ("required", `List [`String "title"]);
    ];
  };

  {
    name = "masc_batch_add_tasks";
    description = "Add multiple tasks atomically in one call, more efficient than repeated masc_add_task. \
Use when loading a sprint backlog, importing from JIRA, or creating a batch of related tasks. \
Each task gets a unique task-XXX ID. Pair with masc_tasks to verify they landed.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("tasks", `Assoc [
          ("type", `String "array");
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
    name = "masc_transition";
    description = "Move a task through its lifecycle: claim, start, done, cancel, or release. \
Call when you pick up, finish, or abandon a task. Supports CAS via expected_version. \
After masc_add_task or masc_claim_next; pair with masc_deliver before action='done'.";
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
          ("description", `String "Transition action: claim | start | done | cancel | release");
        ]);
        ("expected_version", `Assoc [
          ("type", `String "integer");
          ("description", `String "Optional CAS guard (current backlog.version). Transition fails if mismatched");
        ]);
        ("notes", `Assoc [
          ("type", `String "string");
          ("description", `String "Completion notes (used with action='done')");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Cancellation reason (used with action='cancel')");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "task_id"; `String "action"]);
    ];
  };

  {
    name = "masc_task_history";
    description = "Fetch the transition event log for a task (who claimed, started, completed it and when). \
Use when debugging a stuck task or auditing task lifecycle after an incident. \
Pair with masc_transition to drive state changes or masc_tasks to see current states.";
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
    description = "List tasks in the backlog with status, assignee, and priority. Defaults to active tasks only. \
Use when you want to see available work (status='todo') or check what others are doing. \
Pair with masc_claim_next to grab the top task or masc_transition to change a task state.";
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
    name = "masc_lock";
    description = "Acquire an exclusive lock on a file path to prevent concurrent edits by other agents. \
Use when you are about to modify a shared file and other agents are active in the room. \
Pair with masc_unlock when done. Locks auto-release on masc_leave.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name");
        ]);
        ("file", `Assoc [
          ("type", `String "string");
          ("description", `String "File path to lock (relative to project root)");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "file"]);
    ];
  };
  {
    name = "masc_unlock";
    description = "Release an exclusive file lock you previously acquired. \
Call when you finish editing a locked file. After masc_lock; \
also released automatically on masc_leave or masc_cleanup_zombies.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name");
        ]);
        ("file", `Assoc [
          ("type", `String "string");
          ("description", `String "File path to unlock (relative to project root)");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "file"]);
    ];
  };

  {
    name = "masc_archive_view";
    description = "View tasks that were completed and moved to the archive by masc_gc. \
Use when you need to reference past work or audit completed deliverables. \
Pair with masc_gc to control archival or masc_tasks for active work.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description", `String "Max number of archived tasks to show (default: 20)");
        ]);
      ]);
    ];
  };

  {
    name = "masc_workflow_guide";
    description = "Get personalized next-step guidance based on your current agent state. \
Call when you are unsure which MASC tool to use next or want to verify your workflow. \
Pair with masc_check to assert specific prerequisites before acting.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_check";
    description = "Assert preconditions on your agent state (joined, task claimed, worktree active, etc). \
Call when you want to confirm prerequisites before starting work; returns pass/fail with fix hints. \
Pair with masc_workflow_guide for next-step recommendations.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("assertions", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [
            ("type", `String "string");
            ("enum", `List [
              `String "room_set"; `String "joined"; `String "task_claimed";
              `String "current_task_set"; `String "worktree_active";
            ]);
          ]);
          ("description", `String "List of state assertions to check. Each returns true/false with a fix hint if false.");
        ]);
      ]);
      ("required", `List [`String "assertions"]);
    ];
  };
]
