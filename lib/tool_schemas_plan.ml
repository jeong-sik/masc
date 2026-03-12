open Types

let schemas : tool_schema list = [
  {
    name = "masc_plan_init";
    description = "Initialize a planning context for a task. Creates task_plan.md, notes.md, and deliverable.md structure. Works with file or PostgreSQL backend.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID to create planning context for");
        ]);
      ]);
      ("required", `List [`String "task_id"]);
    ];
  };
  {
    name = "masc_plan_update";
    description = "Update the task plan (main execution plan). Overwrites the current plan.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID");
        ]);
        ("content", `Assoc [
          ("type", `String "string");
          ("description", `String "New plan content (markdown)");
        ]);
      ]);
      ("required", `List [`String "task_id"; `String "content"]);
    ];
  };
  {
    name = "masc_plan_get";
    description = "Get the full planning context for a task as markdown (for LLM context).";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID (optional if current task is set)");
        ]);
      ]);
      ("required", `List []);
    ];
  };
  {
    name = "masc_plan_set_task";
    description = "Set the current task for the session. After this, you can omit task_id in subsequent planning calls.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID to set as current");
        ]);
      ]);
      ("required", `List [`String "task_id"]);
    ];
  };
  {
    name = "masc_plan_get_task";
    description = "Get the task_id you're currently working on (session-scoped). \
Returns null if no task is set. Useful for: resuming work after context switch, \
verifying current assignment, debugging session state. \
Set via masc_plan_set_task. Auto-cleared on masc_leave.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
      ("required", `List []);
    ];
  };
  {
    name = "masc_plan_clear_task";
    description = "Clear your current task assignment without completing it. \
Use when: switching to different task, abandoning work, resetting session. \
Does NOT change task status (use masc_transition for that). \
Auto-called on masc_leave.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
      ("required", `List []);
    ];
  };
]
