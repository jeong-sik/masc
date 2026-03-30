(** MCP tool schemas for room management operations (extra).

    This file now only carries room-level strategy controls. *)

open Types

let schemas : tool_schema list = [
  {
    name = "masc_room_strategy_get";
    description = "Read current room search strategy and speculation defaults.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_room_strategy_set";
    description = "Update room search strategy (legacy or best_first_v1) and speculation routing defaults.";
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
