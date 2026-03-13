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

  (* ============================================ *)
  (* Council - Multi-agent Debate & Consensus     *)
  (* ============================================ *)

  {
    name = "masc_debate_start";
    description = "Start a structured debate on a topic. Agents can take positions (support/oppose/neutral) \
and provide arguments with evidence. Use for: complex decisions, design discussions, technical debates.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("topic", `Assoc [
          ("type", `String "string");
          ("description", `String "The topic to debate");
        ]);
      ]);
      ("required", `List [`String "topic"]);
    ];
  };

  {
    name = "masc_debate_argue";
    description = "Add an argument to an ongoing debate. Take a position and provide your reasoning. \
Use reply_to to respond to a specific argument (ping-pong style).";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("debate_id", `Assoc [
          ("type", `String "string");
          ("description", `String "The debate ID");
        ]);
        ("position", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "support"; `String "oppose"; `String "neutral"]);
          ("description", `String "Your position on the topic");
        ]);
        ("content", `Assoc [
          ("type", `String "string");
          ("description", `String "Your argument");
        ]);
        ("evidence", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Supporting evidence (optional)");
        ]);
        ("reply_to", `Assoc [
          ("type", `String "integer");
          ("description", `String "Index of argument to reply to (for ping-pong debate)");
        ]);
        ("mentions", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Agent names to mention/notify");
        ]);
      ]);
      ("required", `List [`String "debate_id"; `String "content"]);
    ];
  };

  {
    name = "masc_debate_close";
    description = "Close a debate. No more arguments can be added.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("debate_id", `Assoc [
          ("type", `String "string");
          ("description", `String "The debate ID to close");
        ]);
      ]);
      ("required", `List [`String "debate_id"]);
    ];
  };

  {
    name = "masc_debate_status";
    description = "Get status and summary of a debate.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("debate_id", `Assoc [
          ("type", `String "string");
          ("description", `String "The debate ID");
        ]);
      ]);
      ("required", `List [`String "debate_id"]);
    ];
  };

  {
    name = "masc_debates";
    description = "List all debates (open and closed).";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_consensus_start";
    description = "Start a voting session for consensus. Agents vote approve/reject/abstain with reasons.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("topic", `Assoc [
          ("type", `String "string");
          ("description", `String "The topic to vote on");
        ]);
        ("quorum", `Assoc [
          ("type", `String "integer");
          ("description", `String "Minimum votes required (default: 2)");
        ]);
        ("threshold", `Assoc [
          ("type", `String "number");
          ("description", `String "Majority threshold 0.0-1.0 (default: 0.5)");
        ]);
      ]);
      ("required", `List [`String "topic"]);
    ];
  };

  {
    name = "masc_consensus_vote";
    description = "Cast a vote in a consensus session.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("session_id", `Assoc [
          ("type", `String "string");
          ("description", `String "The voting session ID");
        ]);
        ("decision", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "approve"; `String "reject"; `String "abstain"]);
          ("description", `String "Your vote");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Reason for your vote");
        ]);
      ]);
      ("required", `List [`String "session_id"; `String "decision"]);
    ];
  };

  {
    name = "masc_consensus_close";
    description = "Close a voting session and get the result.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("session_id", `Assoc [
          ("type", `String "string");
          ("description", `String "The voting session ID");
        ]);
      ]);
      ("required", `List [`String "session_id"]);
    ];
  };

  {
    name = "masc_consensus_result";
    description = "Get the result of a voting session (Unanimous/Majority/Deadlock/Escalate).";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("session_id", `Assoc [
          ("type", `String "string");
          ("description", `String "The voting session ID");
        ]);
      ]);
      ("required", `List [`String "session_id"]);
    ];
  };

  {
    name = "masc_sessions";
    description = "List active voting sessions.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
]
