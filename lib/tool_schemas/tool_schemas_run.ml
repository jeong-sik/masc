(** Tool_schemas_run — SSOT for run-tracking tool schemas.

    Defines schemas for task execution lifecycle: init, plan, log,
    deliverable, get, and list.
*)

open Types

let schemas : Types.tool_schema list =
  [
    {
      name = "masc_run_init";
      description =
        "Initialize execution memory (.masc/runs/{task_id}/) to track plan, logs, and deliverables. Use after claiming a task to enable structured progress tracking.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("task_id", `Assoc [ ("type", `String "string") ]);
                  ("agent_name", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "task_id"; `String "agent_name" ]);
            ("additionalProperties", `Bool false);
          ];
    };
    {
      name = "masc_run_plan";
      description = "Set or update the execution plan for a task run.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("task_id", `Assoc [ ("type", `String "string") ]);
                  ("plan", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "task_id"; `String "plan" ]);
            ("additionalProperties", `Bool false);
          ];
    };
    {
      name = "masc_run_log";
      description =
        "Append a timestamped note to a task's execution log for audit and handoff continuity. Use when reaching milestones, finding blockers, or making key decisions during execution.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("task_id", `Assoc [ ("type", `String "string") ]);
                  ("note", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "task_id"; `String "note" ]);
            ("additionalProperties", `Bool false);
          ];
    };
    {
      name = "masc_run_deliverable";
      description = "Record the final deliverable/output of a task run.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("task_id", `Assoc [ ("type", `String "string") ]);
                  ("deliverable", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "task_id"; `String "deliverable" ]);
            ("additionalProperties", `Bool false);
          ];
    };
    {
      name = "masc_run_get";
      description =
        "Retrieve the full execution history for a task including plan revisions, log notes, and deliverables. Use when reviewing progress before handoff or for post-mortem analysis.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc [ ("task_id", `Assoc [ ("type", `String "string") ]) ] );
            ("required", `List [ `String "task_id" ]);
            ("additionalProperties", `Bool false);
          ];
    };
    {
      name = "masc_run_list";
      description =
        "List all task runs with their current status (init, active, completed). Use when surveying execution state across tasks or finding abandoned runs to resume.";
      input_schema =
        `Assoc
          [
            ("type", `String "object"); ("properties", `Assoc []);
            ("additionalProperties", `Bool false);
          ];
    };
  ]
