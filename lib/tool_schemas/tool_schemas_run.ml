(** Tool_schemas_run — SSOT for run-tracking tool schemas.

    Defines schemas for task execution lifecycle: init, plan, get,
    and list.
*)

open Masc_domain

let schemas : Masc_domain.tool_schema list =
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
      name = "masc_run_get";
      description =
        "Retrieve the full execution history for a task including plan revisions, log notes, and deliverables. If the task has no run record yet, create an empty run scaffold and return it. Use when reviewing progress before handoff or for post-mortem analysis.";
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
