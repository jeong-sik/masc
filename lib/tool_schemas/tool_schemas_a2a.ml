(** Tool schemas for Tool_a2a — separated to break Config dependency cycle *)

open Types

let schemas : tool_schema list = [
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
  };
]
