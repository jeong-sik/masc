(** MCP tool schemas for room management operations (core).

    Only schemas dispatched by Tool_coord remain here.
    Other schemas have been moved to their owning modules:
    - Tool_task, Tool_control, Tool_suspend, Tool_plan, Tool_portal,
      Tool_inline_dispatch (via Tool_schemas_inline) *)

open Types

let schemas : tool_schema list = [
  {
    name = "masc_status";
    description = "Get current project status: active agents, task queue, recent broadcasts, and cluster info. \
Use when you need a snapshot of who is online and what tasks are available. \
Call after masc_join to orient yourself. Pair with masc_tasks for detailed backlog.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_reset";
    description = "DESTRUCTIVE: Reset the active MASC project completely. Deletes ALL data in .masc/ folder. \
Removes: tasks, messages, agents, locks, cache, telemetry. Cannot be undone. \
Use only for: fresh start, corrupted state recovery, testing. \
Requires confirm=true to execute. Example: masc_reset({confirm: true})";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("confirm", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Set to true to confirm reset");
          ("default", `Bool false);
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
          ("description", `String "List of state assertions to check. Each returns true/false with a fix hint if false. Historical key 'room_set' means project scope configured.");
        ]);
      ]);
      ("required", `List [`String "assertions"]);
    ];
  };

  {
    name = "masc_heartbeat";
    description = "Update your heartbeat timestamp to prove you are still active. \
Call every few minutes during long tasks; agents silent for 5+ min become zombie candidates.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
]
