(** MCP tool schemas for shared goal planning and goal lifecycle
    operations. *)

open Masc_domain

(* RFC-0294: goal_horizon_enum removed with the workspace-goal horizon.
   masc_goal_list/upsert no longer advertise a horizon arg; with the schema's
   "additionalProperties": false, an explicit horizon key is rejected as an
   unknown property rather than silently ignored. *)
(* RFC-0089: the phase/action enums advertised to MCP clients are derived from
   the Goal_phase ADT (the goal lifecycle SSOT), the same source the
   workspace_goals validator uses, so the schema can never advertise a value the
   validator rejects (or vice versa). *)
let goal_phase_enum = List.map Goal_phase.to_string Goal_phase.all

let goal_transition_action_enum =
  List.map Goal_phase.action_to_string Goal_phase.all_actions

let goal_vote_decision_enum = [ "approve"; "reject" ]
let goal_inherit_mode_enum = [ "extend"; "replace" ]

let enum_schema ?description values =
  `Assoc
    ([
       ("type", `String "string");
       ("enum", `List (List.map (fun value -> `String value) values));
     ]
     @
     match description with
     | Some description -> [ ("description", `String description) ]
     | None -> [])

let goal_principal_schema =
  `Assoc
    [
      ("type", `String "object");
      ( "properties",
        `Assoc
          [
            ("id", `Assoc [ ("type", `String "string") ]);
            ("display_name", `Assoc [ ("type", `String "string") ]);
          ] );
      ("required", `List [ `String "id" ]);
    ]

let goal_verifier_policy_schema =
  `Assoc
    [
      ("type", `String "object");
      ( "properties",
        `Assoc
          [
            ("inherit_mode", enum_schema goal_inherit_mode_enum);
            ("principals", `Assoc [ ("type", `String "array"); ("items", goal_principal_schema) ]);
            ("required_verdicts", `Assoc [ ("type", `String "integer") ]);
          ] );
      ("required", `List [ `String "inherit_mode"; `String "principals" ]);
    ]

let schemas : tool_schema list =
  [
    {
      name = "masc_goal_list";
      description =
        "List shared planning goals from the Goal Store, optionally filtered by explicit phase. \
Valid phases: executing, awaiting_verification, awaiting_approval, blocked, paused, completed, dropped. \
Use when a PM/planner agent needs current goals before creating tasks or reviews. \
The dashboard Goal Tree reads the same store. Goal-task links are managed externally. \
The response includes each goal's explicit lifecycle phase and verification policy.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("phase", enum_schema ~description:"Optional explicit Goal FSM phase filter" goal_phase_enum);
                ] );
            ("additionalProperties", `Bool false);
          ];
    };
    {
      name = "masc_goal_upsert";
      description =
        "Create or update a shared Goal Store entry used by Planning > Goal Tree. \
For new goals, provide at least title. \
After creation, goal-task links are registered separately by the keeper orchestrator. \
Use this tool for goal metadata, parent linkage, and verifier-policy configuration. \
Lifecycle status/phase fields are intentionally omitted here; use masc_goal_transition / masc_goal_verify for lifecycle moves.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("id", `Assoc [ ("type", `String "string") ]);
                  ("title", `Assoc [ ("type", `String "string") ]);
                  ("metric", `Assoc [ ("type", `String "string") ]);
                  ("target_value", `Assoc [ ("type", `String "string") ]);
                  ("due_date", `Assoc [ ("type", `String "string") ]);
                  ("priority", `Assoc [ ("type", `String "integer") ]);
                  ("parent_goal_id", `Assoc [ ("type", `String "string") ]);
                  ("verifier_policy", goal_verifier_policy_schema);
                  ("require_completion_approval", `Assoc [ ("type", `String "boolean") ]);
                ] );
            ("additionalProperties", `Bool false);
          ];
    };
    {
      name = "masc_goal_hygiene_review";
      description =
        "Review Goal Store hygiene for G-GHYG: stale executing goals and active \
metricless goals. By default this is read-only and returns a typed issue rollup. \
When apply=true, actor is required and must be the authenticated operator; \
apply blocks executable hygiene violations instead of inventing metrics.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("apply", `Assoc [ ("type", `String "boolean") ]);
                  ("actor", goal_principal_schema);
                ] );
            ("additionalProperties", `Bool false);
          ];
    };
    {
      name = "masc_goal_transition";
      description =
        "Apply an explicit Goal FSM transition such as request_complete, pause, unblock, or approval resolution. \
The actor field records who initiated the transition.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("goal_id", `Assoc [ ("type", `String "string") ]);
                  ("action", enum_schema goal_transition_action_enum);
                  ("actor", goal_principal_schema);
                  ("note", `Assoc [ ("type", `String "string") ]);
                  ( "override_note",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "description",
                          `String
                            "Operator rationale for forcing request_complete when linked task evidence is incomplete." );
                      ] );
                ] );
            ("required", `List [ `String "goal_id"; `String "action"; `String "actor" ]);
            ("additionalProperties", `Bool false);
          ];
    };
    {
      name = "masc_goal_verify";
      description =
        "Submit one verifier vote on an open goal verification request. \
Supports id-only principals, one vote per principal, and N-of-M quorum resolution.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("goal_id", `Assoc [ ("type", `String "string") ]);
                  ("request_id", `Assoc [ ("type", `String "string") ]);
                  ("principal", goal_principal_schema);
                  ("decision", enum_schema goal_vote_decision_enum);
                  ("note", `Assoc [ ("type", `String "string") ]);
                  ( "evidence_refs",
                    `Assoc
                      [
                        ("type", `String "array");
                        ("items", `Assoc [ ("type", `String "string") ]);
                      ] );
                ] );
            ("required", `List [ `String "goal_id"; `String "principal"; `String "decision" ]);
            ("additionalProperties", `Bool false);
          ];
    };
  ]
