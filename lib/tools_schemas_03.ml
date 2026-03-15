(** Split chunk from tools.ml; private schema registry. *)

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
    ];
  };

  {
    name = "masc_error_add";
    description = "Add an error/failure to the planning context (PDCA Check phase). Use to track failures, bugs, and issues encountered during task execution.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID");
        ]);
        ("error_type", `Assoc [
          ("type", `String "string");
          ("description", `String "Type of error: build, test, runtime, logic, api, etc.");
        ]);
        ("message", `Assoc [
          ("type", `String "string");
          ("description", `String "Error message or description");
        ]);
        ("context", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional context (file path, function name, etc.)");
        ]);
      ]);
      ("required", `List [`String "task_id"; `String "error_type"; `String "message"]);
    ];
  };

  {
    name = "masc_error_resolve";
    description = "Mark an error as resolved. Use when you've fixed an issue tracked in the planning context.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID");
        ]);
        ("error_index", `Assoc [
          ("type", `String "integer");
          ("description", `String "0-based index of the error to mark as resolved");
        ]);
      ]);
      ("required", `List [`String "task_id"; `String "error_index"]);
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

  (* ============================================ *)
  (* Session-level Context                        *)
  (* ============================================ *)

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

  (* ============================================ *)
  (* Consensus / Voting System                   *)
  (* ============================================ *)

  {
    name = "masc_vote_create";
    description = "Create a vote for multi-agent consensus. Use for decisions like: which approach to take, PR approval, architecture choices. All active agents can vote.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("proposer", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name (vote creator)");
        ]);
        ("topic", `Assoc [
          ("type", `String "string");
          ("description", `String "What are we voting on? (e.g., 'Approach for API refactoring')");
        ]);
        ("options", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Vote options (e.g., ['Option A: REST', 'Option B: GraphQL'])");
        ]);
        ("required_votes", `Assoc [
          ("type", `String "integer");
          ("description", `String "Number of votes needed to resolve (usually 2 or 3)");
          ("default", `Int 2);
        ]);
      ]);
      ("required", `List [`String "proposer"; `String "topic"; `String "options"]);
    ];
  };

  {
    name = "masc_vote_cast";
    description = "Cast your vote on an active proposal. Your choice must match one of the options exactly.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name");
        ]);
        ("vote_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Vote ID from masc_vote_create");
        ]);
        ("choice", `Assoc [
          ("type", `String "string");
          ("description", `String "Your choice (must match an option exactly)");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "vote_id"; `String "choice"]);
    ];
  };

  {
    name = "masc_vote_status";
    description = "Get status of a specific vote including current votes and result.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("vote_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Vote ID to check");
        ]);
      ]);
      ("required", `List [`String "vote_id"]);
    ];
  };

  {
    name = "masc_votes";
    description = "List all votes in the room (active and resolved). \
Votes are used for: multi-agent decisions, consensus building, approvals. \
Shows: vote_id, question, options, current tally, status. \
Use masc_vote_cast to participate, masc_vote_create to start new vote.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  (* Debate & Consensus tools removed in v2.90.0 (Phase 0 stabilization).
     Replaced by Governance V2 (petitions/rulings) and WALPH. *)
]
