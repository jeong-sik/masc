(** Tool schemas for Tool_misc — separated to break Config dependency cycle *)

open Types

let schemas : tool_schema list = [
  {
    name = "masc_transport_status";
    description = "Return the active transport surfaces and runtime counters for HTTP, gRPC, WebSocket, and WebRTC. \
Use when selecting a client transport or debugging whether realtime transports are enabled and reachable.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_websocket_discovery";
    description = "Return the standalone WebSocket discovery payload equivalent to GET /ws, including enablement, port, URL, and session count. \
Use before opening a WebSocket client to discover the correct ws:// endpoint.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_webrtc_offer";
    description = "Create a WebRTC signaling offer in the server registry and return an offer_id. \
Use from the initiating side before calling masc_webrtc_answer from the answering side.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Name of the agent creating the offer");
        ]);
        ("ice_candidates", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "ICE candidates gathered by the offering peer");
          ("default", `List []);
        ]);
        ("dtls_fingerprint", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional DTLS fingerprint for the offering peer");
        ]);
      ]);
      ("required", `List [`String "agent_name"]);
    ];
  };
  {
    name = "masc_webrtc_answer";
    description = "Accept a pending WebRTC signaling offer by offer_id and return the peer_id plus server-side ICE credentials. \
Use from the answering side after a prior masc_webrtc_offer call.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("offer_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Offer identifier returned by masc_webrtc_offer");
        ]);
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Name of the agent accepting the offer");
        ]);
        ("ice_candidates", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Optional ICE candidates gathered by the answering peer");
          ("default", `List []);
        ]);
      ]);
      ("required", `List [`String "offer_id"; `String "agent_name"]);
    ];
  };
  {
    name = "masc_dashboard";
    description = "Render the MASC dashboard summarizing rooms, agents, and tasks in one view. \
Use when you need a quick overview of cluster state; set scope='current' for this room only. \
Pair with masc_agents for agent details, masc_run_list for task details.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("compact", `Assoc [
          ("type", `String "boolean");
          ("description", `String "If true, show compact single-line summary instead of full dashboard");
        ]);
        ("scope", `Assoc [
          ("type", `String "string");
          ("description", `String "Dashboard scope: 'all' (default) or 'current'");
          ("default", `String "all");
        ]);
      ]);
    ];
  };
  {
    name = "masc_verify_handoff";
    description = "Compare original and received context to detect semantic drift, information loss, or distortion after handoff. \
Call after claiming a handoff to verify context integrity (default threshold: 0.85 similarity). \
Pair with masc_handover_get for the original context, masc_handover_claim for the received.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("original", `Assoc [
          ("type", `String "string");
          ("description", `String "Original context before handoff");
        ]);
        ("received", `Assoc [
          ("type", `String "string");
          ("description", `String "Received context after handoff");
        ]);
        ("threshold", `Assoc [
          ("type", `String "number");
          ("description", `String "Similarity threshold (default: 0.85)");
          ("default", `Float 0.85);
        ]);
      ]);
      ("required", `List [`String "original"; `String "received"]);
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
    name = "masc_tool_stats";
    description = "Return in-memory tool usage statistics: top tools by call count, stale tools (30+ days unused), and never-called tools. \
Use when auditing tool adoption or identifying dead tools for cleanup. \
Pair with masc_tool_help for details on specific tools. Data resets on server restart.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("top_n", `Assoc [
          ("type", `String "integer");
          ("description", `String "Number of top tools to return (default: 20)");
          ("default", `Int 20);
        ]);
      ]);
    ];
  };
  {
    name = "masc_tool_help";
    description = "Return canonical help text, parameters, and metadata for a specific MASC tool by name. \
Use when you need detailed usage guidance for a tool beyond its short description. \
Pair with masc_tool_stats to discover which tools exist.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("tool_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Exact MCP tool name to explain");
        ]);
      ]);
      ("required", `List [`String "tool_name"]);
    ];
  };
  {
    name = "masc_tool_admin_snapshot";
    description = "Return a unified admin snapshot of tool inventory, auth/RBAC, and command-plane surfaces. \
Use when auditing the full server configuration or diagnosing tool visibility issues. \
Pair with masc_tool_admin_update to apply changes based on the snapshot.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("include_hidden", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Include hidden tools in tool_inventory (default: true)");
          ("default", `Bool true);
        ]);
        ("include_deprecated", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Include deprecated tools in tool_inventory (default: true)");
          ("default", `Bool true);
        ]);
      ]);
    ];
  };
  {
    name = "masc_tool_admin_update";
    description = "Apply auth, unit-policy, or keeper-policy updates through a single admin entrypoint. \
Use when toggling auth or updating unit/keeper policies. \
After masc_tool_admin_snapshot to review current state before making changes.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("section", `Assoc [
          ("type", `String "string");
          ("description", `String "One of: auth, unit_policy");
        ]);
        ("enabled", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Enable or disable auth for section=auth");
        ]);
        ("require_token", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Require tokens for section=auth");
        ]);
        ("default_role", `Assoc [
          ("type", `String "string");
          ("description", `String "Default role for unauthenticated agents: reader|worker|admin");
        ]);
        ("token_expiry_hours", `Assoc [
          ("type", `String "integer");
          ("description", `String "Token expiry in hours for section=auth");
        ]);
        ("unit_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Managed unit id for section=unit_policy");
        ]);
        ("policy", `Assoc [
          ("type", `String "object");
          ("description", `String "Unit policy envelope for section=unit_policy");
        ]);
        ("budget", `Assoc [
          ("type", `String "object");
          ("description", `String "Unit budget envelope for section=unit_policy");
        ]);
      ]);
      ("required", `List [`String "section"]);
    ];
  };
  {
    name = "masc_keeper_tool_catalog";
    description = "List all visible masc_* tools alongside keeper-internal wrapper coverage, with optional tier/hidden/deprecated filters. \
Use when auditing which tools the keeper can wrap or checking tool visibility by tier. \
Pair with masc_tool_admin_snapshot for a broader admin view including auth and command-plane surfaces.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("tier", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional tier filter: essential, standard, full");
        ]);
        ("include_hidden", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Include hidden tools in the catalog");
        ]);
        ("include_deprecated", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Include deprecated tools in the catalog");
        ]);
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description", `String "Max tools per page (default 50, max 500)");
        ]);
        ("offset", `Assoc [
          ("type", `String "integer");
          ("description", `String "Skip first N tools for pagination (default 0)");
        ]);
      ]);
    ];
  };
  {
    name = "masc_config_snapshot";
    description = "Return a read-only snapshot of the current runtime configuration. \
Env vars are categorized (server, storage, transport, chain, inference, keeper, dashboard) \
with source (env or default) and sensitivity flags. Sensitive values are masked.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
]
