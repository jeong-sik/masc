(** Tool schemas for Tool_a2a — separated to break Config dependency cycle *)

open Types

let schemas : tool_schema list = [
  {
    name = "masc_a2a_discover";
    description = "Discover available A2A agents with capabilities, skills, and protocol bindings. \
Use when looking for agents to delegate tasks to, or checking what skills are available in the room. \
Pair with masc_a2a_delegate to send work, or masc_a2a_query_skill for skill details.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("endpoint", `Assoc [
          ("type", `String "string");
          ("description", `String "Remote endpoint URL (optional, defaults to local room)");
        ]);
        ("capability", `Assoc [
          ("type", `String "string");
          ("description", `String "Filter by capability (e.g., 'typescript', 'code-review')");
        ]);
      ]);
    ];
    visibility = Public;
  };
  {
    name = "masc_a2a_query_skill";
    description = "Query detailed information about an agent's skill: input/output modes and usage examples. \
Use when you want to understand a skill's capabilities before delegating work via masc_a2a_delegate. \
Call masc_a2a_discover first to find available agents and skill IDs.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Target agent name");
        ]);
        ("skill_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Skill ID to query (e.g., 'task-management', 'git-worktree')");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "skill_id"]);
    ];
    visibility = Public;
  };
  {
    name = "masc_a2a_delegate";
    description = "Delegate a task to another A2A agent via portal. Returns task ID. \
Use when you want another agent to handle a subtask. Modes: sync (wait), async (fire-and-forget), stream (real-time). \
Call masc_a2a_discover first to find capable agents. Pair with masc_a2a_subscribe for async results.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("target_agent", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent to delegate to");
        ]);
        ("task_type", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "sync"; `String "async"; `String "stream"]);
          ("default", `String "async");
          ("description", `String "Type: 'sync' (wait), 'async' (fire-and-forget), 'stream' (real-time)");
        ]);
        ("message", `Assoc [
          ("type", `String "string");
          ("description", `String "Task description or prompt to send");
        ]);
        ("artifacts", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [
            ("type", `String "object");
            ("properties", `Assoc [
              ("name", `Assoc [("type", `String "string")]);
              ("mime_type", `Assoc [("type", `String "string")]);
              ("data", `Assoc [("type", `String "string")]);
            ]);
          ]);
          ("description", `String "Optional input artifacts (files, data)");
        ]);
        ("timeout", `Assoc [
          ("type", `String "integer");
          ("default", `Int 300);
          ("description", `String "Timeout in seconds (default: 300)");
        ]);
      ]);
      ("required", `List [`String "target_agent"; `String "message"]);
    ];
    visibility = Public;
  };
  {
    name = "masc_a2a_subscribe";
    description = "Subscribe to events from agents (task_update, broadcast, completion, error) via SSE. \
Use when monitoring delegated tasks or wanting real-time updates from other agents. \
Pair with masc_poll_events to read buffered events, and masc_a2a_unsubscribe to clean up.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent to subscribe to (or '*' for all agents)");
        ]);
        ("events", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [
            ("type", `String "string");
            ("enum", `List [`String "task_update"; `String "broadcast"; `String "completion"; `String "error"]);
          ]);
          ("description", `String "Event types to subscribe to");
        ]);
      ]);
      ("required", `List [`String "events"]);
    ];
    visibility = Public;
  };
  {
    name = "masc_a2a_unsubscribe";
    description = "Stop receiving events from a background subscription. \
Call when: (1) done monitoring, (2) switching to different events, (3) cleanup before leave. \
Frees server resources - always unsubscribe when done. \
Get subscription_id from masc_a2a_subscribe response. \
Example: masc_a2a_unsubscribe({subscription_id: 'sub-abc123'})";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("subscription_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Subscription ID to remove");
        ]);
      ]);
      ("required", `List [`String "subscription_id"]);
    ];
    visibility = Public;
  };
  {
    name = "masc_poll_events";
    description = "Poll buffered events for a subscription and optionally clear the buffer. \
Use when checking for async task updates or broadcast events between work steps. \
Workflow: masc_a2a_subscribe -> do work -> masc_poll_events periodically -> masc_a2a_unsubscribe.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("subscription_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Subscription ID to poll events from");
        ]);
        ("clear", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Clear buffer after reading (default: true)");
          ("default", `Bool true);
        ]);
      ]);
      ("required", `List [`String "subscription_id"]);
    ];
    visibility = Public;
  };
  {
    name = "masc_heartbeat_result";
    description = "Submit heartbeat completion evidence after running an assigned heartbeat_task MCP tool loop. \
Call when a worker agent finishes its heartbeat action cycle with status (acted/skipped/failed). \
Reports tool usage and decision metadata. Pair with masc_heartbeat_start to initiate the cycle.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("worker_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Worker agent name (e.g., 'model-worker-local')");
        ]);
        ("agent", `Assoc [
          ("type", `String "string");
          ("description", `String "Original source agent name (e.g., 'dreamer')");
        ]);
        ("status", `Assoc [
          ("type", `String "string");
          ("description", `String "Completion status: acted | skipped | failed");
          ("enum", `List [`String "acted"; `String "skipped"; `String "failed"]);
        ]);
        ("summary", `Assoc [
          ("type", `String "string");
          ("description", `String "Short completion summary");
        ]);
        ("tool_call_count", `Assoc [
          ("type", `String "integer");
          ("description", `String "Number of MCP tool calls executed by the worker");
        ]);
        ("tool_names", `Assoc [
          ("type", `String "array");
          ("description", `String "Executed MCP tool names");
          ("items", `Assoc [("type", `String "string")]);
        ]);
        ("decision_reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Why the worker chose this outcome");
        ]);
        ("decision_confidence", `Assoc [
          ("type", `String "number");
          ("description", `String "Confidence score between 0.0 and 1.0");
        ]);
        ("failure_reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional explicit failure reason");
        ]);
      ]);
      ("required",
        `List
          [
            `String "worker_name";
            `String "agent";
            `String "status";
            `String "summary";
            `String "tool_call_count";
            `String "tool_names";
            `String "decision_reason";
            `String "decision_confidence";
          ]);
    ];
    visibility = Public;
  };
]
