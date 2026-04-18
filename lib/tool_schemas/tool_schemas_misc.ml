(** Tool schemas for Tool_misc — separated to break Config dependency cycle *)

open Types

(** Issue #8493: hand-mirrored from
    [Env_config_snapshot.valid_config_category_strings ()].
    [masc_tool_schemas] only depends on [masc_types], so it cannot
    derive directly. The sync regression test
    [test_types.ml :: config_category_ssot] asserts these stay in
    lock-step so adding a new category in [env_config_snapshot.ml]
    fails the test before shipping with a stale schema. Same shape as
    #8467 / #8480 / #8484 / #8490 mirror+sync pattern.

    Order matches [all_categories ()] for UI/schema determinism. The
    schema previously hand-listed only 9 of 21 categories — missing
    keeper_execution, keeper_guardrails, autonomy, level2, economy,
    governance, channel, process, worker, web_search, session. *)
let config_category_enum_strings =
  [ "server"; "auth"; "transport"; "storage"; "runtime"; "rate_limiting";
    "inference"; "keeper"; "keeper_execution"; "keeper_guardrails";
    "autonomy"; "level2"; "dashboard"; "economy"; "governance"; "channel";
    "process"; "worker"; "web_search"; "session" ]

let schemas : tool_schema list = [
  {
    name = "masc_config";
    description = "Return the effective runtime configuration with source attribution (env var or default) for each setting. \
Sensitive values (tokens, passwords) are masked. Use to inspect or verify the server config without restarting. \
Pass category to filter results to a single section.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("category", `Assoc [
          ("type", `String "string");
          (* Issue #8493: derive from local mirror that tracks
             [Env_config_snapshot.valid_config_category_strings ()]. *)
          ("enum", `List (List.map (fun s -> `String s) config_category_enum_strings));
          ("description", `String "Filter by config category");
        ]);
      ]);
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
    description = "Render the MASC dashboard summarizing rooms, agents, and tasks. Set scope='current' for this room only.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("compact", `Assoc [
          ("type", `String "boolean");
          ("description", `String "If true, show compact single-line summary instead of full dashboard");
        ]);
        ("scope", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "all"; `String "current"]);
          ("description", `String "Dashboard scope (default: all)");
          ("default", `String "all");
        ]);
      ]);
    ];
  };
  {
    name = "masc_gc";
    description = "Run garbage collection: remove zombie agents, archive stale tasks, delete old messages (default: 7-day threshold).";
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
    description = "Remove zombie agents (no heartbeat for 5+ min) and release their file locks.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_tool_stats";
    description = "In-memory tool usage stats: top calls, stale (30+ days), never-called. Resets on server restart.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("top_n", `Assoc [
          ("type", `String "integer");
          ("description", `String "Number of top tools to return (default: 20)");
          ("default", `Int 20);
          ("minimum", `Int 1);
          ("maximum", `Int 100);
        ]);
      ]);
    ];
  };
  {
    name = "masc_tool_help";
    description = "Return canonical help text, parameters, and metadata for a specific MASC tool by name.";
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
    name = "masc_web_search";
    description = "Search the public web and return top result titles, URLs, and snippets. \
Read-only helper for current-information lookups before deeper file or repo work. \
Uses configured web-search providers with structured fallback behavior and returns structured JSON.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("query", `Assoc [
          ("type", `String "string");
          ("description", `String "Search query text");
        ]);
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description", `String "Maximum number of results to return (default 5, max 10)");
          ("default", `Int 5);
          ("minimum", `Int 1);
          ("maximum", `Int 10);
        ]);
      ]);
      ("required", `List [`String "query"]);
    ];
  };
  {
    name = "masc_tool_admin_snapshot";
    description = "Return a unified admin snapshot of tool inventory, auth/RBAC, and command-plane surfaces.";
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
          ("enum", `List [`String "auth"; `String "unit_policy"]);
          ("description", `String "Config section to update");
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
          (* Issue #8386: derived from Types.agent_role Variant SSOT.
             Hand-rolled enum risks dropping a constructor on extension. *)
          ("enum", `List (List.map (fun s -> `String s) Types.valid_agent_role_strings));
          ("description", `String
            (Printf.sprintf "Default role for unauthenticated agents (%s)"
               (String.concat " | " Types.valid_agent_role_strings)));
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
]
