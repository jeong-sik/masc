(** Split chunk from tools.ml; private schema registry. *)

open Types

let schemas : tool_schema list = [
  {
    name = "masc_plan_init";
    description = "Create a planning context (task_plan.md, notes.md, deliverable.md) for a task. \
Call after masc_claim_next or masc_transition(action='claim') to set up structured planning. \
Pair with masc_plan_update to write the plan and masc_note_add for observations.";
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
    description = "Overwrite the current task execution plan with new content (markdown). \
Use when your approach changes or you want to refine the plan mid-task. \
After masc_plan_init; pair with masc_plan_get to read the full planning context.";
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
    description = "Append a timestamped note or observation to the task planning context. \
Use when you discover something worth recording during execution (findings, blockers, decisions). \
After masc_plan_init; pair with masc_plan_get to review all notes or masc_error_add for failures.";
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
    description = "Attach final output (PR URL, diff, report) to a task for handoff or review. \
Call when work is complete, before masc_transition(action='done'). \
Deliverables persist with the task and are visible to other agents via masc_plan_get.";
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
    description = "Record an error or failure in the task planning context (PDCA Check phase). \
Use when you hit a build, test, or runtime failure during execution to track it for review. \
Pair with masc_error_resolve once fixed or masc_plan_get to see all errors.";
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
    description = "Mark a previously recorded error as resolved in the planning context. \
Call when you have fixed an issue tracked via masc_error_add. \
Use masc_plan_get to find the error_index (0-based) to resolve.";
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
    description = "Retrieve the full planning context for a task as markdown (plan, notes, errors, deliverables). \
Use when resuming work, reviewing progress, or preparing for handoff. \
Omit task_id to use the current session task set via masc_plan_set_task.";
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
    description = "Set the current task for your session so you can omit task_id in planning calls. \
Call after masc_claim_next or masc_transition(action='claim') to bind your session to a task. \
Auto-cleared on masc_leave. Check with masc_plan_get_task.";
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
    description = "Get the task_id currently bound to your session (returns null if none). \
Use when resuming after a context switch or verifying your current assignment. \
Set via masc_plan_set_task; auto-cleared on masc_leave.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
      ("required", `List []);
    ];
  };

  {
    name = "masc_plan_clear_task";
    description = "Unbind your session from the current task without changing the task's status. \
Use when switching to a different task or resetting your session context. \
Does NOT mark the task done; use masc_transition for status changes. Auto-called on masc_leave.";
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
    description = "Create a vote for multi-agent consensus on a decision (approach, PR approval, architecture). \
Use when 2+ agents need to agree before proceeding. All active agents can participate. \
Pair with masc_vote_cast to collect votes and masc_vote_status to check the result.";
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
    description = "Cast your vote on an active proposal. Choice must match one of the options exactly. \
Call when you receive a vote notification or see an open vote in masc_votes. \
After masc_vote_create; check masc_vote_status to see if quorum is reached.";
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
    description = "Get the current tally and result of a specific vote. \
Use when you want to check if quorum has been reached or see who voted for what. \
After masc_vote_create or masc_vote_cast; pair with masc_votes to list all votes.";
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
    description = "List all votes in the room (active and resolved) with their tallies and status. \
Use when you want an overview of pending decisions or past consensus outcomes. \
Pair with masc_vote_cast to participate or masc_vote_create to start a new vote.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  (* Debate & Consensus tools removed in v2.90.0 (Phase 0 stabilization).
     Replaced by Governance V2 (petitions/rulings) and WALPH. *)
]
