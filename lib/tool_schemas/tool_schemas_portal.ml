open Types

let schemas : tool_schema list = [
  {
    name = "masc_portal_open";
    description = "Open a private direct channel to another agent for A2A communication (unlike broadcast, portal messages are not public). \
Use when delegating tasks to a specific agent, requesting expert help, or handing off parallel work. \
Follow up with masc_portal_send to send messages; close with masc_portal_close.";
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
    description = "Send a task or message through your open portal to the connected agent. \
Use when requesting code review, delegating subtasks, or consulting an expert agent. \
After masc_portal_open establishes the channel; check responses via portal status.";
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
    description = "Close your portal connection to the target agent. \
Use when finished with the A2A exchange or cleaning up before session end. \
Auto-closes on session end. Pair with masc_portal_open to re-establish if needed.";
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
