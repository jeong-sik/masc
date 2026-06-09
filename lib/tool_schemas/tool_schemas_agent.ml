open Masc_domain

(** Issue #8501: hand-mirrored from
    [Tool_agent.valid_agent_card_action_strings]. masc_tool_schemas
    only depends on masc_types so it cannot derive directly. The sync
    regression test [test_types.ml :: keeper_tool_variants_ssot] catches
    drift. Same shape as #8467/#8480/#8484/#8490/#8493 mirror+sync
    pattern. *)

let agent_card_action_enum_strings = [ "get"; "refresh" ]

(* masc_agents / masc_agent_update schemas removed (2026-06-09): the
   agent-status surface they fronted read/wrote the dead .masc/agents/
   registry (producer Workspace_eio.register_agent had 0 call sites). *)
let schemas : tool_schema list = [
  {
    name = "masc_agent_fitness";
    description = "Get fitness scores for agents based on completion rate, reliability, and speed metrics.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: Get fitness for specific agent. If omitted, returns all agents.");
        ]);
        ("days", `Assoc [
          ("type", `String "integer");
          ("description", `String "Number of days to analyze (default: 7)");
          ("default", `Int 7);
        ]);
      ]);
      ("additionalProperties", `Bool false);
    ];
  };
  {
    name = "masc_get_metrics";
    description = "Fetch raw performance metrics for an agent: task completion, timing, error rates, collaboration history.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent name to get metrics for");
        ]);
        ("days", `Assoc [
          ("type", `String "integer");
          ("description", `String "Number of days of history (default: 7)");
          ("default", `Int 7);
          ("minimum", `Int 1);
          ("maximum", `Int 90);
        ]);
      ]);
      ("required", `List [`String "agent_name"]);
      ("additionalProperties", `Bool false);
    ];
  };

  {
    name = "masc_agent_card";
    description = "Return the MASC server agent card and optional live agent summary.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("action", `Assoc [
          ("type", `String "string");
          ("enum", `List (List.map (fun s -> `String s) agent_card_action_enum_strings));
          ("description", `String "Card action: get or refresh.");
          ("default", `String "get");
        ]);
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional live agent name to include in the card.");
        ]);
      ]);
      ("additionalProperties", `Bool false);
    ];
  };

]
