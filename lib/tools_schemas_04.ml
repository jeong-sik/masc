(** Split chunk from tools.ml; private schema registry. *)

open Types

let schemas : tool_schema list = [
  {
    name = "masc_route";
    description = "Route a query to appropriate agents using MoE-style selection. \
Returns: selected agents, estimated cost, complexity score.";
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
    description = "Get Governance V2 status (pending rulings, auto-executable cases, human-gated orders, executed cases).";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_petition_submit";
    description = "Submit a Governance V2 petition. Creates or merges a case, records requested action metadata, and files the item into the petition inbox.";
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
    description = "Add a support/oppose/neutral brief to a Governance V2 case. Brief submission can trigger a ruling and execution order.";
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
    description = "List Governance V2 cases. Use this instead of legacy debate/session surfaces.";
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
    description = "Read a single Governance V2 case bundle including petitions, briefs, ruling, and execution order.";
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
    description = "Read the latest Governance V2 ruling for a case.";
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
    description = "List Governance V2 execution orders, inspect one case order, or confirm/deny a human gate.";
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
    description = "Execute an action based on governance decision. \
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

  (* ============================================ *)
  (* Social Features (Moltbook-style)             *)
  (* ============================================ *)

  {
    name = "masc_post_create";
    description = "Create a post in the social feed. Use for: sharing discoveries, ideas, questions. \
Posts can be organized by submolt (topic channels). Agents can upvote/downvote and comment.";
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
    description = "List posts in the social feed. Sorted by votes (highest first). \
Filter by submolt to see specific topics.";
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
    description = "Get a specific post with its comments (threaded).";
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
    description = "Add a comment to a post. Supports threaded replies via parent_id.";
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
    description = "List all comments for a post (flat list, sorted by time).";
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
    description = "Vote on a post or comment. Each agent can only vote once per target. \
Votes affect sort order (higher votes = more visibility).";
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
    description = "Pause workflow and wait for user approval (LangGraph interrupt pattern). Use before dangerous operations like database deletion, production changes, or external API calls. The workflow will be suspended until approved or rejected.";
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
    description = "Approve an interrupted workflow checkpoint. Use when user confirms the dangerous action should proceed.";
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
    description = "Reject an interrupted workflow checkpoint. Use when user declines the dangerous action.";
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
    description = "List all pending interrupted workflows waiting for approval.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_branch";
    description = "Create a new execution branch from an existing checkpoint. Use for exploring alternative paths (e.g., 'try approach A here, try approach B there'). The source checkpoint is marked as 'branched' and a new checkpoint is created with the same state but a new branch name.";
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
    description = "Log token usage and cost for tracking multi-agent expenses. Call after significant API calls to track spending per agent and task.";
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
    description = "Get cost report showing token usage and spending by agent. Use to monitor multi-agent collaboration expenses.";
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
    description = "Enable authentication for this room. Returns a room secret that should be shared securely with authorized agents. Once enabled, agents need tokens to perform actions.";
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
    description = "Disable authentication for this room. All agents can perform any action without tokens.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_auth_status";
    description = "Check authentication status for this room.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_auth_create_token";
    description = "Create a new authentication token for an agent. The token should be kept secret and passed in subsequent requests.";
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
