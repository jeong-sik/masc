open Types

let schemas : tool_schema list = [
  {
    name = "masc_start";
    description = "One-step onboarding: sets the active project root and optionally creates+claims a task. Provide path to point MASC at your project directory. Optionally provide task_title to create and claim a task immediately.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("path", `Assoc [
          ("type", `String "string");
          ("description", `String "Project directory path (absolute, relative, or ~/...). Omit if the active project scope is already set.");
        ]);
        ("task_title", `Assoc [
          ("type", `String "string");
          ("description", `String "If provided, creates a task with this title, claims it, and sets it as current_task. Omit to just set the project scope.");
        ]);
      ]);
    ];
  };
  {
    name = "masc_set_project";
    description = "Set the active project root for MASC operations. Points MASC at a project's .masc/ directory. Prefer masc_start for full onboarding.";
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
    description = "List active agents with their session information. \
Shows: agent name, last activity, capabilities. \
Use to: find who can help, check if specific agent is active, see team composition. \
Tip: Use capabilities to find the right agent for @mentions.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
]
