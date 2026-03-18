(** Split chunk from tools.ml; private schema registry. *)

open Types

let schemas : tool_schema list = [
  {
    name = "masc_claim_next";
    description = "Claim the highest-priority unclaimed task from the backlog in one step. \
Use when you are ready to work and want the most urgent available task. \
After masc_join; follow with masc_plan_set_task to set session context, then masc_transition(action='done').";
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
    description = "Change a task's priority (1=highest, 5=lowest). \
Use when new information shifts urgency, e.g., a blocker is discovered or a deadline moves. \
Pair with masc_tasks to review the current backlog order after reprioritizing.";
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
    description = "Send a message visible to all agents in the room via SSE push. \
Use when you need to share status updates, request help (@agent_name to ping), or announce completion. \
Pair with masc_messages to read replies or masc_listen to wait for responses.";
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
    description = "Fetch recent broadcast messages from all agents in chronological order. \
Use when catching up after joining, checking for @mentions, or reviewing room activity. \
Pair with masc_broadcast to send messages or masc_listen to block-wait for new ones.";
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
    description = "Block-wait for incoming messages, returning when a message arrives or timeout is reached. \
Use when you are idle and waiting for instructions, @mentions, or task assignments. \
Pair with masc_broadcast to send a reply or masc_messages for non-blocking reads.";
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
    description = "List all agents currently in the room with their capabilities and join time. \
Use when you need to find who can help or check if a specific agent is online. \
Pair with masc_find_by_capability to search by skill or masc_broadcast to @mention someone.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_reset";
    description = "DESTRUCTIVE: wipe all MASC room data (tasks, messages, agents, locks, cache). Cannot be undone. \
Use only when you need a fresh start or the room state is corrupted beyond repair. \
Requires confirm=true. After reset, call masc_init and masc_join to rebuild.";
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
    description = "Open a private A2A channel to another agent for direct task delegation or expert help. \
Use when you need 1:1 communication instead of room-wide broadcast. \
After opening, send requests via masc_portal_send; check masc_portal_status for responses.";
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
    description = "Send a task or request through your open portal to the connected agent. \
Use when you have an active portal and need to delegate a subtask or request a review. \
After masc_portal_open; check masc_portal_status to see if they have responded.";
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
    description = "Close your open portal connection to another agent. \
Use when the delegated work is done or you are cleaning up before masc_leave. \
Portals auto-close on masc_leave. Check masc_portal_status to see active portals.";
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
    description = "Get the status of your portal connections and any pending A2A tasks from connected agents. \
Use when you have sent a portal request and want to check for responses. \
After masc_portal_open or masc_portal_send; pair with masc_portal_close to tear down.";
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
    description = "Create an isolated Git worktree under .worktrees/{agent}-{task}/ with a new branch. \
Use when you need full file isolation for parallel work instead of file locks. \
After masc_claim_next; remove with masc_worktree_remove once the PR is merged.";
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
    description = "Remove a worktree and its local branch after the PR is merged. \
Call when your task branch has been merged and you no longer need the isolated workspace. \
After masc_worktree_create; check masc_worktree_list for remaining worktrees.";
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
    description = "List all active Git worktrees in the project, showing which agents work on which tasks. \
Use when you want to see existing isolation branches or check for stale worktrees to clean up. \
Pair with masc_worktree_create to add or masc_worktree_remove to clean up.";
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
    description = "Update your heartbeat timestamp to prove you are still active. \
Call every few minutes during long tasks; agents silent for 5+ min become zombie candidates. \
Prefer masc_heartbeat_start for automatic pings. Pair with masc_cleanup_zombies to reap stale agents.";
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
    description = "Remove zombie agents (no heartbeat for 5+ min) and release their file locks. \
Use when you see stale agents in masc_agents or suspect a crashed session left locks behind. \
Pair with masc_gc for full room maintenance including old tasks and messages.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_heartbeat_start";
    description = "Start automatic background heartbeat pings at a given interval. \
Call after masc_join to keep your presence alive during long-running work. \
Smart mode skips beats when busy. Stop with masc_heartbeat_stop before masc_leave.";
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
    description = "Stop a periodic heartbeat that was started by masc_heartbeat_start. \
Call when your long task is complete or you are about to masc_leave. \
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
    description = "List all active heartbeat timers in the room with their interval and last beat time. \
Use when debugging presence issues or looking for orphaned heartbeats before cleanup. \
Pair with masc_heartbeat_stop to cancel or masc_cleanup_zombies to reap dead agents.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_gc";
    description = "Run garbage collection: remove zombie agents, archive stale tasks, delete old messages. \
Call periodically or when the room feels cluttered; defaults to 7-day age threshold. \
Pair with masc_archive_view to inspect what was archived or masc_cleanup_zombies for agents only.";
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
    description = "Get detailed status of all agents: zombie detection, current tasks, capabilities, and last seen time. \
Use when you need a full roster beyond what masc_who shows, including health indicators. \
Pair with masc_cleanup_zombies to remove stale agents or masc_find_by_capability to search.";
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
    description = "Register your skill tags so other agents can discover you by capability. \
Call after masc_join if you did not pass capabilities at join time, or to update them later. \
Pair with masc_find_by_capability to search others or masc_who to see the full roster.";
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
    description = "Update an agent's metadata (status or capabilities) with transition guards. \
Use when you need to correct an external agent's state or change your own status to busy/listening. \
Pair with masc_agents to verify the update or masc_register_capabilities for capability-only changes.";
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
    description = "Search for active (non-zombie) agents that have a specific capability tag. \
Use when you need help with a particular skill (e.g., 'typescript') and want to find the right agent. \
Pair with masc_broadcast to @mention the found agent or masc_portal_open for direct delegation.";
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
    description = "Get or regenerate the A2A-compatible Agent Card for this MASC instance. \
Use when integrating with external A2A systems or verifying advertised capabilities. \
Action 'get' returns current card; 'refresh' rebuilds it from live bindings. Pair with masc_agents.";
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
