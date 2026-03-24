(** Tool_improve_loop_schemas — MCP control surface for the keeper-driven
    masc-mcp self-improvement loop. *)

open Types

let schemas : tool_schema list =
  [
    {
      name = "masc_improve_loop_start";
      description =
        "Start the masc-mcp self-improvement loop. Persists keeper name, repo scope, poll interval, and execution mode for repeated issue/PR burn-down cycles.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("repo", `Assoc [ ("type", `String "string") ]);
                  ("keeper_name", `Assoc [ ("type", `String "string") ]);
                  ("poll_interval_sec", `Assoc [ ("type", `String "integer") ]);
                  ("dry_run", `Assoc [ ("type", `String "boolean") ]);
                ] );
          ];
      visibility = Public;
    };
    {
      name = "masc_improve_loop_status";
      description =
        "Read the persisted state of the masc-mcp self-improvement loop, including current candidate, pause reason, last success/failure, and recent queue summary.";
      input_schema =
        `Assoc [ ("type", `String "object"); ("properties", `Assoc []) ];
      visibility = Public;
    };
    {
      name = "masc_improve_loop_pause";
      description =
        "Pause the self-improvement loop without deleting state. Use when a human needs to inspect or take over.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc [ ("reason", `Assoc [ ("type", `String "string") ]) ] );
          ];
      visibility = Public;
    };
    {
      name = "masc_improve_loop_resume";
      description =
        "Resume a previously paused self-improvement loop. Preserves queue state and last known candidate.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc [ ("dry_run", `Assoc [ ("type", `String "boolean") ]) ] );
          ];
      visibility = Public;
    };
    {
      name = "masc_improve_loop_tick";
      description =
        "Run one selection/execution cycle for the self-improvement loop. Ranks PR conflicts, failing PRs, and open issues, then prepares or executes the next action.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("limit", `Assoc [ ("type", `String "integer") ]);
                  ("execute", `Assoc [ ("type", `String "boolean") ]);
                  ("review_ok", `Assoc [ ("type", `String "boolean") ]);
                ] );
          ];
      visibility = Public;
    };
  ]
