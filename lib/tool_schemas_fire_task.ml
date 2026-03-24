open Types

let schemas : tool_schema list = [
  {
    name = "masc_fire_task";
    description = "Submit a task and walk away. Creates a MASC task, optionally provisions a \
worktree, and spawns a background agent to execute it. Returns immediately with the task_id \
so you can continue other work. \
Use when you want to delegate a self-contained goal to another agent without waiting for the result. \
Check progress later with masc_status or masc_poll_events.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("goal", `Assoc [
          ("type", `String "string");
          ("description", `String "The task goal for the background agent to accomplish. \
Be specific: include file paths, acceptance criteria, and constraints.");
        ]);
        ("agent", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent CLI to spawn (e.g. 'claude', 'gemini', 'codex'). \
Defaults to 'claude'.");
          ("default", `String "claude");
        ]);
        ("priority", `Assoc [
          ("type", `String "integer");
          ("description", `String "Task priority (1=highest, 5=lowest). Default: 3.");
          ("default", `Int 3);
        ]);
        ("use_worktree", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Create an isolated git worktree for the agent. \
Recommended for file-modifying tasks. Default: false.");
          ("default", `Bool false);
        ]);
      ]);
      ("required", `List [`String "goal"]);
    ];
    visibility = Public;
  };
]
