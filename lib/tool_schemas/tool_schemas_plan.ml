open Masc_domain

let schemas : tool_schema list = [
  {
    name = "masc_plan_init";
    description = "Initialize a planning context for a task, creating task_plan.md, notes.md, and deliverable.md structure. \
Use when starting structured work on a claimed task that needs planning artifacts. \
After masc_claim_next or masc_add_task; follow up with masc_plan_update to write the plan.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID to create planning context for");
        ]);
      ]);
      ("required", `List [`String "task_id"]);
      ("additionalProperties", `Bool false);
    ];
  };
  {
    name = "masc_plan_update";
    description = "Overwrite the current task plan with new content (markdown). \
Use when refining or replacing the execution plan for your current task. \
After masc_plan_init creates the structure; pair with masc_plan_get to review.";
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
      ("additionalProperties", `Bool false);
    ];
  };
  {
    name = "masc_plan_get";
    description = "Retrieve the full planning context for a task as markdown (plan, notes, deliverable). \
Use when loading task context into your working memory before starting work. \
After masc_plan_init; omit task_id if masc_plan_set_task was called.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID (optional if current task is set)");
        ]);
      ]);
      ("required", `List []);
      ("additionalProperties", `Bool false);
    ];
  };
  {
    name = "masc_plan_set_task";
    description = "Set the current task for your session so you can omit task_id in subsequent planning calls. \
Use when starting work on a task after claiming it. \
After masc_claim_next; auto-cleared on masc_leave.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID to set as current");
        ]);
      ]);
      ("required", `List [`String "task_id"]);
      ("additionalProperties", `Bool false);
    ];
  };
  {
    name = "masc_plan_get_task";
    description = "Get the task_id you're currently working on (session-scoped). \
Use when resuming work after a context switch or verifying your current assignment. \
Set via masc_plan_set_task. Auto-cleared on masc_leave.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
      ("required", `List []);
      ("additionalProperties", `Bool false);
    ];
  };
  {
    name = "masc_plan_clear_task";
    description = "Clear your current task assignment without completing it (does not change task status). \
Use when switching to a different task, abandoning work, or resetting session state. \
Use masc_transition to change task status separately. Auto-called on masc_leave.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
      ("required", `List []);
      ("additionalProperties", `Bool false);
    ];
  };
  {
    name = "masc_note_add";
    description = "Add a note/observation to the planning context. Notes are timestamped and appended.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID");
        ]);
        ("note", `Assoc [
          ("type", `String "string");
          ("description", `String "Note content");
        ]);
      ]);
      ("required", `List [`String "task_id"; `String "note"]);
      ("additionalProperties", `Bool false);
    ];
  };
  {
    name = "masc_deliver";
    description = "Attach final output/result to a task for handoff or review. \
Use for: code diffs, PR URLs, analysis reports, generated files. \
Deliverables persist with task and are visible to other agents. \
Call before masc_transition(action='done'). \
Example: masc_deliver({task_id: 'task-001', content: 'PR: github.com/org/repo/pull/123'})";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID");
        ]);
        ("content", `Assoc [
          ("type", `String "string");
          ("description", `String "Deliverable content");
        ]);
      ]);
      ("required", `List [`String "task_id"; `String "content"]);
      ("additionalProperties", `Bool false);
    ];
  };
]
