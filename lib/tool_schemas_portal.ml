open Types

let schemas : tool_schema list = [
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
]
