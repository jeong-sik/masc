(** Tool schemas for Tool_control — separated to break Config dependency cycle *)

open Types

let schemas : tool_schema list = [
  {
    name = "masc_pause";
    description = "Pause the active MASC project namespace. Stops orchestrator from spawning new agents. Broadcasts notification to all agents. Use when you need to stop automated work temporarily.";
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
    description = "Resume the active MASC project namespace after pause. Allows orchestrator to spawn agents again. Broadcasts notification to all agents.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_pause_status";
    description = "Check if the default project namespace is currently paused and get pause details for the flattened default namespace.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("namespace_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional namespace hint. Current builds always report the default flattened namespace.");
        ]);
      ]);
    ];
  };
]
