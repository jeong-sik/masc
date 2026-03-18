(** Tool schemas for Tool_control — separated to break Config dependency cycle *)

open Types

let schemas : tool_schema list = [
  {
    name = "masc_pause";
    description = "Pause the MASC room. Stops orchestrator from spawning new agents. Broadcasts notification to all agents. Use when you need to stop automated work temporarily.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Reason for pausing (e.g., 'Need to review', 'Taking a break')");
          ("default", `String "Manual pause");
        ]);
      ]);
    ];
  };
  {
    name = "masc_resume";
    description = "Resume the MASC room after pause. Allows orchestrator to spawn agents again. Broadcasts notification to all agents.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_pause_status";
    description = "Check if the room is currently paused and get pause details.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_switch_mode";
    description = "Switch MASC mode to control which tool categories are visible. \
Use when you want to reduce token overhead (minimal/solo) or enable more features (parallel/full). \
Modes: minimal (~20), standard, parallel, full (~322), solo (~23), agent (~20), custom. \
Pair with masc_get_config to see current mode, masc_tool_enable for individual tools.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("mode", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "minimal"; `String "standard"; `String "parallel"; `String "full"; `String "solo"; `String "custom"]);
          ("description", `String "Mode preset: minimal, standard, parallel, full, solo, or custom");
        ]);
        ("categories", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "For 'custom' mode: list of categories to enable (core, comm, portal, worktree, health, discovery, voting, interrupt, cost, auth, ratelimit, encryption)");
        ]);
      ]);
      ("required", `List [`String "mode"]);
    ];
  };
  {
    name = "masc_get_config";
    description = "Get current MASC mode configuration: enabled/disabled categories and available presets. \
Use when checking which tools are visible before requesting a mode switch. \
Pair with masc_switch_mode to change modes.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_tool_enable";
    description = "Enable specific tools or entire categories without switching to Full mode. \
Use when you need a tool not in the current mode preset (e.g., masc_perpetual_start in Standard mode). \
Pass tool= for individual, tools= for multiple, or category= for bulk (ecosystem, discovery, code, board, etc.). \
Pair with masc_tool_disable to revert, or masc_switch_mode for wholesale changes.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("tool", `Assoc [
          ("type", `String "string");
          ("description", `String "Single tool name to enable (e.g. masc_perpetual_start)");
        ]);
        ("tools", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Multiple tool names to enable at once");
        ]);
        ("category", `Assoc [
          ("type", `String "string");
          ("description", `String "Enable all tools in a category (e.g. ecosystem, discovery, code, board)");
        ]);
      ]);
    ];
  };
  {
    name = "masc_tool_disable";
    description = "Disable previously extra-enabled tools, or clear all extra-enabled tools with clear=true. \
Use when cleaning up tools you no longer need, or resetting to the mode preset baseline. \
Pair with masc_tool_enable to re-add tools later.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("tool", `Assoc [
          ("type", `String "string");
          ("description", `String "Single tool name to disable");
        ]);
        ("tools", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Multiple tool names to disable");
        ]);
        ("clear", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Clear all extra-enabled tools");
        ]);
      ]);
    ];
  };
]
