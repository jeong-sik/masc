open Types

(** Issue #8501: hand-mirrored from
    [Tool_agent.valid_agent_card_action_strings] and
    [Tool_agent.valid_collaboration_format_strings]. masc_tool_schemas
    only depends on masc_types so it cannot derive directly. The sync
    regression test [test_types.ml :: agent_tool_variants_ssot] catches
    drift. Same shape as #8467/#8480/#8484/#8490/#8493 mirror+sync
    pattern. *)

let schemas : tool_schema list = [
  {
    name = "masc_agents";
    description = "Get detailed status of all agents: zombie detection, current tasks, capabilities, last seen time.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description", `String "Max agents to return (default: 20)");
          ("minimum", `Int 1);
          ("maximum", `Int 50);
          ("default", `Int 20);
        ]);
      ]);
      ("additionalProperties", `Bool false);
    ];
  };
  {
    name = "masc_agent_update";
    description = "Update your own agent metadata (status or capabilities) with transition guards.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("status", `Assoc [
          ("type", `String "string");
          (* Issue #8372: derived from Types.agent_status Variant SSOT.
             Hand-rolled enum risks dropping a constructor on extension. *)
          ("enum", `List (List.map (fun s -> `String s) Types.valid_agent_status_strings));
          ("description", `String
            (Printf.sprintf "Optional status: %s"
               (String.concat " | " Types.valid_agent_status_strings)));
        ]);
        ("capabilities", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Optional capability list (overwrites existing)");
        ]);
      ]);
      ("additionalProperties", `Bool false);
    ];
  };
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
    name = "masc_register_capabilities";
    description = "Register your skill tags so other agents can discover you by capability.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name");
        ]);
        ("capabilities", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "List of your capabilities (e.g., ['typescript', 'testing'])");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "capabilities"]);
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

]
