open Types

(** Issue #8520: hand-mirrored from
    [Mcp_server_eio_governance.valid_mcp_session_action_strings]. This
    library ([masc_tool_schemas]) depends only on [masc_types]; pulling
    in the governance module would inflate the dep graph. Sync
    regression test in [test_types.ml :: mcp_session_action_ssot]
    catches drift (same cycle-avoidance pattern as #8484 / #8490 / #8513). *)
let mcp_session_action_enum_strings =
  [ "get"; "create"; "list"; "cleanup"; "remove" ]

let schemas : tool_schema list = [
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
          ("enum", `List (List.map (fun s -> `String s) mcp_session_action_enum_strings));
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
