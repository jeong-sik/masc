open Types

let schemas : tool_schema list = [
  {
    name = "masc_start";
    description = "One-step onboarding: sets the active project root, joins as agent, and optionally creates+claims a task.";
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
      ("additionalProperties", `Bool false);
    ];
  };
  {
    name = "masc_join";
    description = "Join the active MASC project as agent_name to collaborate with other AI agents. \
Call at session start or to re-register presence. Other agents can @mention you. \
Check masc_status after joining to see active agents and available tasks.";
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
      ("additionalProperties", `Bool false);
    ];
  };
  {
    name = "masc_leave";
    description = "Leave the active MASC project and mark yourself as offline. \
Call when: (1) session ends, (2) switching projects, (3) work complete. \
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
      ("additionalProperties", `Bool false);
    ];
  };
  {
    name = "masc_broadcast";
    description = "Send a message visible to ALL agents via SSE push. Use for: status updates ('Starting task X'), help requests ('@gemini can you review this?'), completions. Use @agent_name to ping specific agent.";
    (* Issue #8595: removed dead `format` enum field. The handler in
       tool_inline_dispatch_comm.handle_broadcast never read it; the
       typed PoC handler explicitly destructured it as `_format`.
       Schema previously lied to LLM clients about output shape
       customization. Same anti-pattern as #8546 admin_section. *)
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
      ]);
      ("required", `List [`String "agent_name"; `String "message"]);
      ("additionalProperties", `Bool false);
    ];
  };
  {
    name = "masc_messages";
    description = "Get recent broadcast messages from all agents. \
Use to: catch up after joining, check if someone @mentioned you, see project activity. \
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
      ("additionalProperties", `Bool false);
    ];
  };
  {
    name = "masc_who";
    description = "List all agents currently in the active project with their capabilities. \
Shows: agent name, join time, capabilities (e.g., ['typescript', 'testing']). \
Use to: find who can help, check if specific agent is online, see team composition. \
Agents appear after masc_join, disappear after masc_leave. \
Tip: Use capabilities to find the right agent for @mentions.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
      ("additionalProperties", `Bool false);
    ];
  };
]
