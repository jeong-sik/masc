open Types

let schemas : tool_schema list = [
  (* masc_approval_pending *)
  {
    name = "masc_approval_pending";
    description = "List pending HITL approvals that are blocking keeper or operator progress. \
Returns approval ids plus keeper, tool, risk, input kind, and a preview so an operator can decide what to resolve.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  (* masc_approval_resolve *)
  {
    name = "masc_approval_resolve";
    description = "Resolve a pending HITL approval by id. \
If the id is stale, keeper_name + tool_name + input_kind can be supplied as fallback hints to resolve the single matching pending approval safely.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("id", `Assoc [
          ("type", `String "string");
          ("description", `String "Approval id to resolve");
        ]);
        ("decision", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "approve"; `String "reject"]);
          ("description", `String "Approval decision");
          ("default", `String "approve");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Reject reason. Used when decision='reject'.");
        ]);
        ("keeper_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Fallback hint: keeper name for stale approval ids");
        ]);
        ("tool_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Fallback hint: tool name for stale approval ids");
        ]);
        ("input_kind", `Assoc [
          ("type", `String "string");
          ("description", `String "Fallback hint: approval input.kind for stale approval ids");
        ]);
      ]);
      ("required", `List [`String "id"]);
    ];
  };

  (* masc_mcp_session *)
  {
    name = "masc_mcp_session";
    description = "Create, get, list, or remove MCP sessions that track client context across requests. \
Use when managing multi-request workflows that need session continuity (Mcp-Session-Id header). \
Pair with masc_subscription to receive session-scoped event notifications.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("action", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "get"; `String "create"; `String "list"; `String "cleanup"; `String "remove"]);
          ("description", `String "Session action");
        ]);
        ("session_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Session ID (for get/remove)");
        ]);
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent name (for create)");
        ]);
      ]);
      ("required", `List [`String "action"]);
    ];
  };

  (* masc_cancellation, masc_subscription, masc_progress,
     masc_governance_set removed: pruned from surfaces *)

  (* masc_spawn *)
  {
    name = "masc_spawn";
    description = "Spawn an agent process (claude, gemini, codex, or llama) to execute a task. \
Use when you need another agent to work in parallel on a subtask. \
For llama, provide model explicitly. Pair with masc_add_task to create the task first.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent to spawn: 'claude', 'gemini', 'codex', or custom command");
        ]);
        ("model", `Assoc [
          ("type", `String "string");
          ("description", `String "Explicit model id. Required when agent_name='llama'.");
        ]);
        ("prompt", `Assoc [
          ("type", `String "string");
          ("description", `String "The task/prompt to send to the agent");
        ]);
        ("timeout_seconds", `Assoc [
          ("type", `String "integer");
          ("default", `Int 300);
          ("description", `String "Max execution time in seconds (default: 300)");
        ]);
        ("working_dir", `Assoc [
          ("type", `String "string");
          ("description", `String "Working directory for the agent (optional)");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "prompt"]);
    ];
  };
]
