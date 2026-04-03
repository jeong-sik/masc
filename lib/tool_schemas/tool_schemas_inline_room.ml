open Types

let schemas : tool_schema list = [
  {
    name = "masc_start";
    description = "One-step onboarding: sets the active project root, joins the default namespace as agent, and optionally creates+claims a task. Use this instead of calling masc_set_room, masc_join, masc_add_task, and a separate claim step manually.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("path", `Assoc [
          ("type", `String "string");
          ("description", `String "Project directory path (absolute, relative, or ~/...). Omit if the active project scope is already set.");
        ]);
        ("task_title", `Assoc [
          ("type", `String "string");
          ("description", `String "If provided, creates a task with this title, claims it, and sets it as current_task. Omit to just join without a task.");
        ]);
      ]);
    ];
  };
  {
    name = "masc_set_room";
    description = "Set the project root for MASC operations. Use this to point MASC at a different project's .masc/ directory; runtime coordination stays in the default flattened namespace.";
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
    name = "masc_join";
    description = "Join the active MASC project namespace to collaborate with other AI agents. Historical tool naming still says 'room', but current builds use the shared .masc/ root default namespace. Call at session start. Your presence will be visible to other agents (gemini, codex, etc). They can @mention you for help. Check masc_status after joining to see active agents and available tasks.";
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
    description = "Leave the active MASC project namespace and mark yourself as offline. \
Call when: (1) session ends, (2) switching project scopes, (3) work complete. \
Side effects: releases all your locks, sets presence to offline. \
Other agents will see you've left via SSE. \
Example: masc_leave({agent_name: 'claude-xyz'})";
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
    name = "masc_lock";
    description = "Acquire a lock for a file path (relative to project root). Use masc_unlock to release.";
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
    description = "Release a lock for a file path (relative to project root).";
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
    name = "masc_broadcast";
    description = "Send a message visible to ALL agents via SSE push. Use for: status updates ('Starting task X'), help requests ('@gemini can you review this?'), completions. Use @agent_name to ping specific agent. Default: verbose format.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name");
        ]);
        ("message", `Assoc [
          ("type", `String "string");
          ("description", `String "Message content (use @mention for specific agents)");
        ]);
        ("format", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "compact"; `String "verbose"]);
          ("description", `String "Output format: 'compact' or 'verbose' (default, JSON)");
          ("default", `String "verbose");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "message"]);
    ];
  };
  {
    name = "masc_messages";
    description = "Get recent broadcast messages from all agents. \
Use to: catch up after joining, check if someone @mentioned you, see namespace activity. \
Returns chronological list with sender, timestamp, content. \
Default: last 20 messages. Use limit param for more/less. \
Tip: Search for '@your-name' in results to find mentions.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("since_seq", `Assoc [
          ("type", `String "integer");
          ("description", `String "Get messages after this sequence number");
          ("default", `Int 0);
        ]);
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description", `String "Max messages to return");
          ("default", `Int 10);
        ]);
      ]);
    ];
  };
  {
    name = "masc_listen";
    description = "Listen for incoming messages (blocking). Returns after message arrives or timeout.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name");
        ]);
        ("timeout", `Assoc [
          ("type", `String "integer");
          ("description", `String "Max seconds to wait (default: 300)");
          ("default", `Int 300);
        ]);
      ]);
      ("required", `List [`String "agent_name"]);
    ];
  };
  {
    name = "masc_who";
    description = "List all agents currently in the active namespace with their capabilities. \
Shows: agent name, join time, capabilities (e.g., ['typescript', 'testing']). \
Use to: find who can help, check if specific agent is online, see team composition. \
Agents appear after masc_join, disappear after masc_leave. \
Tip: Use capabilities to find the right agent for @mentions.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
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
]
