(** MCP tool schemas for room management operations (extra).

    This file now only carries room-level strategy controls. *)

open Types

let schemas : tool_schema list = [
  {
    name = "masc_vote_create";
    description = "Create a room vote. Hidden from the default MCP surface but retained for legacy/internal coordination flows.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("topic", `Assoc [
          ("type", `String "string");
          ("description", `String "Vote topic or proposal text.");
        ]);
        ("options", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Allowed vote choices.");
        ]);
        ("required_votes", `Assoc [
          ("type", `String "integer");
          ("description", `String "Minimum votes required before resolution.");
        ]);
      ]);
      ("required", `List [`String "topic"; `String "options"]);
    ];
  };
  {
    name = "masc_vote_cast";
    description = "Cast a vote in an existing room vote. Hidden from the default MCP surface but retained for legacy/internal coordination flows.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("vote_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Existing vote identifier.");
        ]);
        ("choice", `Assoc [
          ("type", `String "string");
          ("description", `String "Selected option.");
        ]);
      ]);
      ("required", `List [`String "vote_id"; `String "choice"]);
    ];
  };
  {
    name = "masc_vote_status";
    description = "Read a room vote status by id. Hidden from the default MCP surface but retained for legacy/internal coordination flows.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("vote_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Existing vote identifier.");
        ]);
      ]);
      ("required", `List [`String "vote_id"]);
    ];
  };
  {
    name = "masc_votes";
    description = "List room votes. Hidden from the default MCP surface but retained for legacy/internal coordination flows.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
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
  };
]
