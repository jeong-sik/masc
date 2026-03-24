(** MCP tool schemas for room management operations (extra).

    Only schemas dispatched by Tool_room remain here.
    Other schemas have been moved to their owning modules:
    - Tool_council, Tool_cost, Tool_rate_limit, Tool_encryption,
      Tool_relay, Tool_mitosis, Tool_handover, Tool_tempo, Tool_walph,
      Tool_hat, Tool_inline_dispatch (via Tool_schemas_inline) *)

open Types

let schemas : tool_schema list = [
  {
    name = "masc_rooms_list";
    description = "Internal compatibility tool for listing named room scopes with agent/task counts and the active room indicator. \
Repo-root room semantics remain the canonical default workflow. \
Use this only when you explicitly need named-room compatibility behavior.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
    visibility = Public;
  };
  {
    name = "masc_room_create";
    description = "Internal compatibility tool for creating a named room scope. Room ID is auto-generated from name (slugified). \
Repo-root room semantics remain the canonical default workflow. \
Use this only when you explicitly need named-room compatibility behavior.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("name", `Assoc [
          ("type", `String "string");
          ("description", `String "Room display name (e.g., 'My Project Dev', 'Personal Projects')");
        ]);
        ("description", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional room description");
        ]);
      ]);
      ("required", `List [`String "name"]);
    ];
    visibility = Public;
  };
  {
    name = "masc_room_enter";
    description = "Internal compatibility tool for switching into a named room scope by ID. \
Repo-root room semantics remain the canonical default workflow. \
Use this only when you explicitly need named-room compatibility behavior.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("room_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Room ID to enter (e.g., 'my-project-dev', 'default')");
        ]);
        ("agent_type", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent type: 'claude', 'gemini', or 'codex'");
          ("default", `String "claude");
        ]);
      ]);
      ("required", `List [`String "room_id"]);
    ];
    visibility = Public;
  };
  {
    name = "masc_room_strategy_get";
    description = "Read current room-level search strategy and speculation defaults. \
Use when you need to check routing configuration before modifying it. \
Pair with masc_room_strategy_set to update the strategy.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
    visibility = Public;
  };
  {
    name = "masc_room_strategy_set";
    description = "Update room-level search strategy and speculation defaults. \
Use when you want to change the command-plane routing behavior (legacy vs best_first_v1) or toggle speculative routing. \
Call masc_room_strategy_get first to see current settings.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("search_strategy_default", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "legacy"; `String "best_first_v1"]);
          ("description", `String "Optional room default for command-plane search strategy.");
        ]);
        ("speculation_enabled", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Enable or disable room-level speculative routing.");
        ]);
        ("speculation_budget", `Assoc [
          ("type", `String "integer");
          ("description", `String "Optional max number of candidates to speculate over when speculation is enabled.");
        ]);
      ]);
    ];
    visibility = Public;
  };
]
