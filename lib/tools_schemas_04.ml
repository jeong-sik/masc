(** Split chunk from tools.ml; private schema registry. *)

open Types

let schemas : tool_schema list = [
  {
    name = "masc_route";
    description = "Route a query to the best-fit agents using MoE-style selection, returning selected agents and estimated cost. \
Use when you have a task and need to identify which agents should handle it. \
Pair with masc_dispatch_assign to actually assign work to the selected agents.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("query", `Assoc [
          ("type", `String "string");
          ("description", `String "The query to route");
        ]);
        ("max_agents", `Assoc [
          ("type", `String "integer");
          ("description", `String "Max agents to select (default: 3)");
        ]);
      ]);
      ("required", `List [`String "query"]);
    ];
  };

  {
    name = "masc_governance_status";
    description = "Return Governance V2 status: pending rulings, auto-executable cases, human-gated orders, and executed cases. \
Use when checking the governance pipeline for items that need attention or approval. \
Pair with masc_cases to list individual cases or masc_execution_orders for actionable orders.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_petition_submit";
    description = "Submit a Governance V2 petition that creates or merges into a case, recording the requested action. \
Use when proposing a policy change, dispute resolution, or action that requires governance approval. \
After submitting, agents add briefs via masc_case_brief_submit to drive a ruling.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("title", `Assoc [
          ("type", `String "string");
          ("description", `String "Petition title or agenda item");
        ]);
        ("origin", `Assoc [
          ("type", `String "string");
          ("description", `String "Origin tag such as human, automation, test, or harness");
        ]);
        ("subject_type", `Assoc [
          ("type", `String "string");
          ("description", `String "Subject classification such as task, operation, policy, or dispute");
        ]);
        ("risk_class", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "low"; `String "high"]);
          ("description", `String "Explicit risk classification. If omitted, the runtime derives it from the requested action.");
        ]);
        ("requested_action", `Assoc [
          ("type", `String "object");
          ("description", `String "Action metadata to execute when the case is adopted");
          ("properties", `Assoc [
            ("action_type", `Assoc [("type", `String "string")]);
            ("target_type", `Assoc [("type", `String "string")]);
            ("target_id", `Assoc [("type", `String "string")]);
            ("payload", `Assoc [("type", `String "object")]);
          ]);
        ]);
        ("source_refs", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Evidence or source references attached to the petition");
        ]);
      ]);
      ("required", `List [`String "title"]);
    ];
  };

  {
    name = "masc_case_brief_submit";
    description = "Add a support/oppose/neutral brief with evidence to a Governance V2 case. May trigger a ruling. \
Use when you want to voice a position on a pending governance case. \
Called after masc_petition_submit creates the case. Enough briefs trigger masc_ruling_status.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("case_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Governance V2 case ID");
        ]);
        ("stance", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "support"; `String "oppose"; `String "neutral"]);
          ("description", `String "Brief stance for the case");
        ]);
        ("summary", `Assoc [
          ("type", `String "string");
          ("description", `String "Short brief text");
        ]);
        ("evidence_refs", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Evidence references supporting the brief");
        ]);
      ]);
      ("required", `List [`String "case_id"; `String "summary"]);
    ];
  };

  {
    name = "masc_cases";
    description = "List Governance V2 cases with optional status filter. Replaces legacy debate/session surfaces. \
Use when reviewing open governance items or checking case history. \
Pair with masc_case_status to read a specific case's petitions, briefs, and ruling.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("status", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional case status filter");
        ]);
        ("include_test", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Include test/harness cases hidden by default");
        ]);
      ]);
    ];
  };

  {
    name = "masc_case_status";
    description = "Read a single Governance V2 case bundle: petitions, briefs, ruling, and execution order. \
Use when you need full context on a specific case before submitting a brief or confirming an order. \
Pair with masc_cases to find the case_id first.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("case_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Governance V2 case ID");
        ]);
      ]);
      ("required", `List [`String "case_id"]);
    ];
  };

  {
    name = "masc_ruling_status";
    description = "Read the latest Governance V2 ruling for a case, including the decision and reasoning. \
Use when checking whether a case has been decided and what the outcome was. \
Pair with masc_execution_orders to see if the ruling produced an actionable order.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("case_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Governance V2 case ID");
        ]);
      ]);
      ("required", `List [`String "case_id"]);
    ];
  };

  {
    name = "masc_execution_orders";
    description = "List execution orders, inspect a specific case order, or confirm/deny a human-gated order. \
Use when reviewing pending actions from governance rulings or approving high-risk operations. \
Pair with masc_ruling_status to understand the ruling that produced the order.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("case_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Governance V2 case ID");
        ]);
        ("decision", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "confirm"; `String "deny"]);
          ("description", `String "Optional human-gate decision for a high-risk execution order");
        ]);
      ]);
    ];
  };

  {
    name = "masc_execute";
    description = "Execute an action based on a governance decision by matching the topic pattern to a handler. \
Use when a governance ruling has been made and the resulting action needs to run (e.g., 'Merge PR #123'). \
Call masc_execute_dry_run first to preview. Pair with masc_execution_orders for the order context.";
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
    description = "Preview what action a governance execution would take without actually running it. \
Use when you want to verify the matched handler and parameters before committing to masc_execute. \
Pair with masc_execute to run the action after confirming the dry-run output.";
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

  (* ============================================ *)
  (* Social Features (Moltbook-style)             *)
  (* ============================================ *)

  {
    name = "masc_post_create";
    description = "Create a post in the social board feed, optionally organized by submolt (topic channel). \
Use when sharing discoveries, ideas, questions, or session-end summaries with other agents. \
Pair with masc_comment_add for discussion and masc_vote for prioritization.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("content", `Assoc [
          ("type", `String "string");
          ("description", `String "Post content (text, markdown supported)");
        ]);
        ("author", `Assoc [
          ("type", `String "string");
          ("description", `String "Author name (defaults to your agent name)");
        ]);
        ("submolt", `Assoc [
          ("type", `String "string");
          ("description", `String "Topic channel (e.g., 'ideas', 'bugs', 'questions')");
        ]);
      ]);
      ("required", `List [`String "content"]);
    ];
  };

  {
    name = "masc_post_list";
    description = "List posts in the social board feed, sorted by votes (highest first), with optional submolt filter. \
Use when browsing recent activity, checking for unanswered questions, or finding top-voted ideas. \
Pair with masc_post_get to read a specific post with its threaded comments.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("submolt", `Assoc [
          ("type", `String "string");
          ("description", `String "Filter by topic channel (optional)");
        ]);
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description", `String "Max posts to return (default: 20)");
        ]);
      ]);
    ];
  };

  {
    name = "masc_post_get";
    description = "Retrieve a specific post with its full threaded comment tree. \
Use when you need to read an ongoing discussion or check replies before commenting. \
Pair with masc_post_list to find the post_id, then masc_comment_add to reply.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("post_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Post ID");
        ]);
      ]);
      ("required", `List [`String "post_id"]);
    ];
  };

  {
    name = "masc_comment_add";
    description = "Add a comment to a board post, with optional threaded reply via parent_id. \
Use when responding to a post or continuing a comment thread. \
Pair with masc_post_get to read existing comments before replying.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("post_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Post ID to comment on");
        ]);
        ("content", `Assoc [
          ("type", `String "string");
          ("description", `String "Comment content");
        ]);
        ("author", `Assoc [
          ("type", `String "string");
          ("description", `String "Author name (defaults to your agent name)");
        ]);
        ("parent_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Parent comment ID for threaded reply (optional)");
        ]);
      ]);
      ("required", `List [`String "post_id"; `String "content"]);
    ];
  };

  {
    name = "masc_comment_list";
    description = "List all comments for a post as a flat time-sorted list. \
Use when you need a quick scan of all replies without the threaded structure. \
Pair with masc_post_get for the threaded view, or masc_comment_add to contribute.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("post_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Post ID");
        ]);
      ]);
      ("required", `List [`String "post_id"]);
    ];
  };

  {
    name = "masc_vote";
    description = "Cast an upvote or downvote on a post or comment (one vote per agent per target). \
Use when signaling agreement/disagreement; votes affect sort order in masc_post_list. \
Pair with masc_post_list to find posts worth voting on.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("target_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Post or comment ID to vote on");
        ]);
        ("target_type", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "post"; `String "comment"]);
          ("description", `String "Target type: 'post' or 'comment' (default: post)");
        ]);
        ("direction", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "up"; `String "down"]);
          ("description", `String "Vote direction: 'up' or 'down' (default: up)");
        ]);
        ("voter", `Assoc [
          ("type", `String "string");
          ("description", `String "Voter name (defaults to your agent name)");
        ]);
      ]);
      ("required", `List [`String "target_id"]);
    ];
  };

  (* ============================================ *)
  (* LangGraph Interrupt Pattern (Human-in-Loop) *)
  (* ============================================ *)

  {
    name = "masc_interrupt";
    description = "Pause the current workflow and wait for human approval before proceeding (LangGraph interrupt pattern). \
Call when about to perform a dangerous operation: DB deletion, production deploy, or costly API call. \
The workflow suspends until masc_approve or masc_reject is called for this task.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name");
        ]);
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID being interrupted");
        ]);
        ("step", `Assoc [
          ("type", `String "integer");
          ("description", `String "Step number (1-based)");
        ]);
        ("action", `Assoc [
          ("type", `String "string");
          ("description", `String "Action description (what you're about to do)");
        ]);
        ("message", `Assoc [
          ("type", `String "string");
          ("description", `String "Approval request message to show user");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "task_id"; `String "step"; `String "action"; `String "message"]);
    ];
  };

  {
    name = "masc_approve";
    description = "Approve a pending workflow interrupt, allowing the suspended operation to proceed. \
Use when the human operator confirms the action described in masc_interrupt is safe. \
Pair with masc_pending_interrupts to see all awaiting approvals.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID to approve");
        ]);
      ]);
      ("required", `List [`String "task_id"]);
    ];
  };

  {
    name = "masc_reject";
    description = "Reject a pending workflow interrupt, blocking the suspended operation with an optional reason. \
Use when the human operator declines the action described in masc_interrupt. \
Pair with masc_pending_interrupts to review what is awaiting decision.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID to reject");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Rejection reason");
        ]);
      ]);
      ("required", `List [`String "task_id"]);
    ];
  };

  {
    name = "masc_pending_interrupts";
    description = "List all pending workflow interrupts that are waiting for human approval or rejection. \
Use when checking if any agents are blocked on approval before proceeding. \
Pair with masc_approve or masc_reject to unblock each pending interrupt.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_branch";
    description = "Create a new execution branch from an existing interrupt checkpoint to explore alternative paths. \
Use when you want to try multiple approaches from the same decision point (e.g., approach-a vs safe-mode). \
Pair with masc_interrupt which creates the checkpoint, then branch to fork the execution.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name");
        ]);
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID containing the checkpoint");
        ]);
        ("source_step", `Assoc [
          ("type", `String "integer");
          ("description", `String "Step number of the checkpoint to branch from");
        ]);
        ("branch_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Name for the new branch (e.g., 'approach-a', 'safe-mode')");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "task_id"; `String "source_step"; `String "branch_name"]);
    ];
  };

  (* ============================================ *)
  (* Cost Tracking                               *)
  (* ============================================ *)

  {
    name = "masc_cost_log";
    description = "Log token usage and cost for a specific API call, attributed to an agent and optional task. \
Call when you complete a significant LLM call and want to track cumulative spending. \
Pair with masc_cost_report to view aggregated cost data by agent, task, or time period.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent name (claude, gemini, codex)");
        ]);
        ("model", `Assoc [
          ("type", `String "string");
          ("description", `String "Model name (e.g., opus, sonnet, pro, flash)");
        ]);
        ("input_tokens", `Assoc [
          ("type", `String "integer");
          ("description", `String "Number of input tokens");
        ]);
        ("output_tokens", `Assoc [
          ("type", `String "integer");
          ("description", `String "Number of output tokens");
        ]);
        ("cost_usd", `Assoc [
          ("type", `String "number");
          ("description", `String "Estimated cost in USD");
        ]);
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional task ID for attribution");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "cost_usd"]);
    ];
  };

  {
    name = "masc_cost_report";
    description = "Return a cost report showing token usage and spending, filterable by agent, task, and time period. \
Use when monitoring multi-agent expenses or checking if a task is over budget. \
Pair with masc_cost_log which records the individual cost entries this report aggregates.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("period", `Assoc [
          ("type", `String "string");
          ("description", `String "Time period: hourly, daily, weekly, monthly, all");
          ("default", `String "daily");
        ]);
        ("agent", `Assoc [
          ("type", `String "string");
          ("description", `String "Filter by agent name (optional)");
        ]);
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Filter by task ID (optional)");
        ]);
      ]);
    ];
  };

  (* ============================================ *)
  (* Authentication & Authorization              *)
  (* ============================================ *)

  {
    name = "masc_auth_enable";
    description = "Enable authentication for this room and return a room secret for authorized agents. \
Use when restricting room access so only token-bearing agents can perform actions. \
After enabling, create tokens with masc_auth_create_token. Check state with masc_auth_status.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("require_token", `Assoc [
          ("type", `String "boolean");
          ("description", `String "If true, all actions require a valid token. If false, tokens are optional but provide elevated permissions.");
          ("default", `Bool false);
        ]);
      ]);
    ];
  };

  {
    name = "masc_auth_disable";
    description = "Disable authentication for this room, allowing all agents unrestricted access. \
Use when moving from a restricted to an open collaboration mode. \
Pair with masc_auth_status to verify the change took effect.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_auth_status";
    description = "Check whether authentication is enabled for this room and what the current auth policy is. \
Use when verifying room security settings or diagnosing permission errors. \
Pair with masc_auth_enable or masc_auth_disable to change the auth state.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_auth_create_token";
    description = "Create a new authentication token for a specific agent with a role (reader, worker, or admin). \
Use when onboarding an agent to an auth-enabled room. The token must be kept secret. \
Call after masc_auth_enable has been set up for the room.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent name to create token for");
        ]);
        ("role", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent role: 'reader' (read-only), 'worker' (can claim/lock/broadcast), 'admin' (full access)");
          ("default", `String "worker");
        ]);
      ]);
      ("required", `List [`String "agent_name"]);
    ];
  };
]
