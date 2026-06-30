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
        "Create an execution memory directory (.masc/runs/{task_id}/) to track the run plan. \
         Call when starting work on a claimed task to enable structured progress tracking. \
         After init, use masc_run_plan to set approach and masc_run_get to review.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ( "task_id",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("description", `String "Task ID to track");
                      ] );
                  ( "agent_name",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("description", `String "Agent working on the task");
                      ] );
                ] );
            ("required", `List [ `String "task_id"; `String "agent_name" ]);
            ("additionalProperties", `Bool false);
          ];
    };
    {
      name = "masc_run_plan";
      description =
        "Set or update the execution plan (markdown) for a task run; each update \
         creates a new revision. \\nCall after masc_run_init to document your \
         approach before starting implementation. \\nOther agents can view plans via \
         masc_run_get for workspace and handoff context.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ( "task_id",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("description", `String "Task ID");
                      ] );
                  ( "plan",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("description", `String "The plan (markdown supported)");
                      ] );
                ] );
            ("required", `List [ `String "task_id"; `String "plan" ]);
            ("additionalProperties", `Bool false);
          ];
    };
    {
      name = "masc_run_get";
      description =
        "Retrieve the run record and execution plan for a task. \\nIf the task has no \
         run record yet, create an empty run scaffold and return it so resume flow \
         can continue. \\nUse when resuming work on a task, reviewing progress, or \
         preparing a handoff. \\nPair with masc_run_plan to set the plan.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ( "task_id",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("description", `String "Task ID to retrieve");
                      ] );
                ] );
            ("required", `List [ `String "task_id" ]);
            ("additionalProperties", `Bool false);
          ];
    };
    {
      name = "masc_run_list";
      description =
        "List all task runs with their status (active/completed) and plan presence. \
         \\nUse when starting a session to find abandoned work or review completed \
         runs. \\nAfter finding a run, call masc_run_get for full details or \
         masc_run_init to start a new one.";
      input_schema =
        `Assoc
          [
            ("type", `String "object"); ("properties", `Assoc []);
            ("additionalProperties", `Bool false);
          ];
    };
  ]
