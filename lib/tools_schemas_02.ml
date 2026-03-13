(** Split chunk from tools.ml; private schema registry. *)

open Types

let schemas : tool_schema list = [
  {
    name = "masc_claim_next";
    description = "Automatically claim the highest priority unclaimed task. Use this when you want to pick up the most important available work without manually checking the task board. Returns the claimed task details including priority level.";
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
    name = "masc_update_priority";
    description = "Change the priority of a task. Priority 1 is highest (most urgent), 5 is lowest. Use this to reprioritize work based on new information or urgency changes.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID to update");
        ]);
        ("priority", `Assoc [
          ("type", `String "integer");
          ("description", `String "New priority (1=highest, 5=lowest)");
          ("minimum", `Int 1);
          ("maximum", `Int 5);
        ]);
      ]);
      ("required", `List [`String "task_id"; `String "priority"]);
    ];
  };

  {
    name = "masc_broadcast";
    description = "Send a message visible to ALL agents via SSE push. Use for: status updates ('Starting task X'), help requests ('@gemini can you review this?'), completions ('✅ Done!'). Use @agent_name to ping specific agent. Default: verbose format.";
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
Use to: catch up after joining, check if someone @mentioned you, see room activity. \
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
    description = "List all agents currently in the room with their capabilities. \
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
    name = "masc_reset";
    description = "⚠️ DESTRUCTIVE: Reset MASC room completely. Deletes ALL data in .masc/ folder. \
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

  (* Portal/A2A Tools - Direct Agent-to-Agent Communication *)
  {
    name = "masc_portal_open";
    description = "Open a direct channel to another agent (A2A protocol). Unlike broadcast, portal messages are PRIVATE between two agents. Use for: delegating tasks to specific agent, getting expert help, parallel work handoff. The target agent will see your tasks in their portal_status.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name (e.g., 'claude')");
        ]);
        ("target_agent", `Assoc [
          ("type", `String "string");
          ("description", `String "Target agent name (e.g., 'gemini')");
        ]);
        ("initial_message", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional initial message to send");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "target_agent"]);
    ];
  };

  {
    name = "masc_portal_send";
    description = "Send a task/request through your open portal. The connected agent will receive this as a pending A2A task. Good for: code review requests, parallel subtasks, expert consultations. Check portal_status to see if they've responded. Default: verbose format.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name");
        ]);
        ("message", `Assoc [
          ("type", `String "string");
          ("description", `String "Message/task to send through portal");
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
    name = "masc_portal_close";
    description = "Close your portal connection to external services. \
Use when: finished with external API, cleaning up before leave. \
Portals are tunnels to external MCP servers (e.g., GitHub, Slack). \
Auto-closes on masc_leave. Check masc_portal_status for active portals.";
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
    name = "masc_portal_status";
    description = "Get status of your portal connections and pending A2A tasks.";
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

  (* Git Worktree Integration - v2 Agent Isolation *)
  {
    name = "masc_worktree_create";
    description = "Create an isolated Git worktree for your work. This requires the active MASC base repository to have `.git` (resolved with git root detection) and always creates worktrees under `<repo_root>/.worktrees/{agent}-{task}/` with a new branch. If you are in a workspace with multiple repos, run MASC from the target repo root. This is BETTER than file locks: you get complete isolation and can work in parallel. After work, create a PR with `gh pr create` and remove the worktree.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name (e.g., 'claude')");
        ]);
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID or feature name (e.g., 'PK-12345' or 'fix-login')");
        ]);
        ("base_branch", `Assoc [
          ("type", `String "string");
          ("description", `String "Base branch to create worktree from (default: 'develop' or 'main')");
          ("default", `String "develop");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "task_id"]);
    ];
  };

  {
    name = "masc_worktree_remove";
    description = "Remove a worktree after your work is merged. This cleans up both the worktree directory and the local branch. Call this after your PR is merged to keep the repo clean.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name");
        ]);
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID used when creating the worktree");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "task_id"]);
    ];
  };

  {
    name = "masc_worktree_list";
    description = "List all active worktrees in the project. Shows which agents are working on what tasks.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  (* ============================================ *)
  (* Heartbeat & Agent Health                    *)
  (* ============================================ *)

  {
    name = "masc_heartbeat";
    description = "Update your heartbeat timestamp. Call periodically (every few minutes) to indicate you're still active. Agents without heartbeat for 5+ minutes are considered 'zombies' and can be cleaned up.";
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
    name = "masc_cleanup_zombies";
    description = "Clean up zombie agents (no heartbeat for 5+ minutes). Removes stale agents and releases their file locks. Run this periodically or when you suspect agent crashes.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_heartbeat_start";
    description = "Start periodic heartbeat broadcasts. Runs in background, sending pings at specified interval. Smart mode skips heartbeats when agent is busy (60-80% token savings).";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("interval", `Assoc [
          ("type", `String "integer");
          ("description", `String "Interval in seconds between heartbeats (min: 5, max: 300)");
          ("default", `Int 30);
        ]);
        ("message", `Assoc [
          ("type", `String "string");
          ("description", `String "Heartbeat message content");
          ("default", `String "🏓 heartbeat");
        ]);
        ("smart", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Enable smart mode: skip when busy, 3x interval when idle >5min");
          ("default", `Bool false);
        ]);
      ]);
    ];
  };

  {
    name = "masc_heartbeat_stop";
    description = "Stop a periodic heartbeat started by masc_heartbeat_start. \
Use when: long task complete, no longer need keep-alive, cleaning up. \
Get heartbeat_id from masc_heartbeat_start response or masc_heartbeat_list.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("heartbeat_id", `Assoc [
          ("type", `String "string");
          ("description", `String "ID of heartbeat to stop (from masc_heartbeat_start)");
        ]);
      ]);
      ("required", `List [`String "heartbeat_id"]);
    ];
  };

  {
    name = "masc_heartbeat_list";
    description = "List all active heartbeats in the room. \
Shows: heartbeat_id, agent, interval, last_beat time. \
Use to: find orphaned heartbeats, debug presence issues, cleanup before leave.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_gc";
    description = "Garbage collection - cleanup zombies, archive stale tasks, delete old messages. One command to clean everything older than N days.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("days", `Assoc [
          ("type", `String "integer");
          ("default", `Int 7);
          ("description", `String "Age threshold in days (default: 7)");
        ]);
      ]);
    ];
  };

  {
    name = "masc_agents";
    description = "Get detailed status of all agents including zombie detection, current tasks, capabilities, and last seen time.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  (* ============================================ *)
  (* Agent Discovery - Capability Broadcasting   *)
  (* ============================================ *)

  {
    name = "masc_register_capabilities";
    description = "Register your capabilities for agent discovery. Other agents can then find you by capability. Examples: ['typescript', 'code-review', 'testing', 'python', 'architecture'].";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name");
        ]);
        ("capabilities", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "List of your capabilities (e.g., ['typescript', 'testing'])");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "capabilities"]);
    ];
  };

  {
    name = "masc_agent_update";
    description = "Update agent metadata (status/capabilities). Use for external agents or manual corrections. Status guards prevent illegal transitions.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent name or nickname");
        ]);
        ("status", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional status: active | busy | listening | inactive");
        ]);
        ("capabilities", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Optional capability list (overwrites existing)");
        ]);
      ]);
      ("required", `List [`String "agent_name"]);
    ];
  };

  {
    name = "masc_find_by_capability";
    description = "Find agents by capability. Use this to discover who can help with specific tasks. Only returns non-zombie agents.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("capability", `Assoc [
          ("type", `String "string");
          ("description", `String "Capability to search for (e.g., 'typescript')");
        ]);
      ]);
      ("required", `List [`String "capability"]);
    ];
  };

  (* A2A Agent Card - Discovery *)
  {
    name = "masc_agent_card";
    description = "Get or update the A2A-compatible Agent Card for this MASC instance. Agent Cards enable standardized agent discovery and capability advertisement. Use 'get' to retrieve current card, 'refresh' to regenerate with current bindings.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("action", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "get"; `String "refresh"]);
          ("description", `String "Action: 'get' returns current card, 'refresh' regenerates it");
        ]);
      ]);
    ];
  };
]
