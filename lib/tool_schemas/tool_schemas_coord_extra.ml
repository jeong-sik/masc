(** MCP tool schemas for project management operations (extra). *)

open Types

let goal_horizon_enum = [ "short"; "mid"; "long" ]
let goal_status_enum = [ "active"; "paused"; "done"; "dropped" ]
let goal_review_outcome_enum = [ "done"; "progress"; "blocked"; "dropped" ]

let schemas : tool_schema list =
  [
    {
      name = "masc_goal_list";
      description =
        "List shared planning goals from the Goal Store, optionally filtered by horizon or status. \
Use when a PM/planner agent needs current long/mid/short goals before creating tasks or reviews. \
The dashboard Goal Tree reads the same store. Linked tasks prefer explicit goal_id linkage; title tags like [goal:<id>] remain a legacy fallback.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ( "horizon",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("enum", `List (List.map (fun v -> `String v) goal_horizon_enum));
                        ("description", `String "Optional horizon filter: short | mid | long");
                      ] );
                  ( "status",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("enum", `List (List.map (fun v -> `String v) goal_status_enum));
                        ("description", `String "Optional status filter: active | paused | done | dropped");
                      ] );
                ] );
          ];
    };
    {
      name = "masc_goal_upsert";
      description =
        "Create or update a shared Goal Store entry used by Planning > Goal Tree. \
For new goals, provide at least title; omitted horizon defaults to short. \
After creation, link tasks into the tree with goal_id=<goal_id>; include [goal:<id>] in the title only for legacy compatibility.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("id", `Assoc [ ("type", `String "string") ]);
                  ( "horizon",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("enum", `List (List.map (fun v -> `String v) goal_horizon_enum));
                      ] );
                  ("title", `Assoc [ ("type", `String "string") ]);
                  ("metric", `Assoc [ ("type", `String "string") ]);
                  ("target_value", `Assoc [ ("type", `String "string") ]);
                  ("due_date", `Assoc [ ("type", `String "string") ]);
                  ("priority", `Assoc [ ("type", `String "integer") ]);
                  ( "status",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("enum", `List (List.map (fun v -> `String v) goal_status_enum));
                      ] );
                  ("parent_goal_id", `Assoc [ ("type", `String "string") ]);
                ] );
          ];
    };
    {
      name = "masc_goal_review";
      description =
        "Apply a review outcome to an existing shared goal. \
Use to mark progress, completion, blockage, or drop decisions after evaluating sub-tasks. \
Optionally move the goal to a new horizon and store a review note.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("goal_id", `Assoc [ ("type", `String "string") ]);
                  ( "outcome",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "enum",
                          `List
                            (List.map (fun v -> `String v) goal_review_outcome_enum) );
                      ] );
                  ( "new_horizon",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("enum", `List (List.map (fun v -> `String v) goal_horizon_enum));
                      ] );
                  ("note", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "goal_id"; `String "outcome" ]);
          ];
    };
  ]
