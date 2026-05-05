(** MCP tool schemas for shared goal planning and goal lifecycle
    operations. *)

open Masc_domain

let goal_horizon_enum = [ "short"; "mid"; "long" ]
let goal_status_enum = [ "active"; "paused"; "done"; "dropped" ]
let goal_phase_enum =
  [
    "executing";
    "awaiting_verification";
    "awaiting_approval";
    "blocked";
    "paused";
    "completed";
    "dropped";
  ]

let goal_review_outcome_enum = [ "done"; "progress"; "blocked"; "dropped" ]
let goal_transition_action_enum =
  [
    "request_complete";
    "approve_completion";
    "reject_completion";
    "pause";
    "resume";
    "operator_block";
    "operator_unblock";
    "drop";
    "reopen";
  ]

let goal_vote_decision_enum = [ "approve"; "reject" ]
let goal_principal_kind_enum = [ "operator"; "keeper" ]
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
            ("kind", enum_schema goal_principal_kind_enum);
            ("id", `Assoc [ ("type", `String "string") ]);
            ("display_name", `Assoc [ ("type", `String "string") ]);
          ] );
      ("required", `List [ `String "kind"; `String "id" ]);
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
        "List shared planning goals from the Goal Store, optionally filtered by horizon, explicit phase, or legacy status. \
Use when a PM/planner agent needs current long/mid/short goals before creating tasks or reviews. \
The dashboard Goal Tree reads the same store. Linked tasks prefer structured task.goal_id; title tags like [goal:<id>] remain a legacy fallback. \
The response includes each goal's explicit lifecycle phase and verification policy.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("horizon", enum_schema ~description:"Optional horizon filter" goal_horizon_enum);
                  ("phase", enum_schema ~description:"Optional explicit Goal FSM phase filter" goal_phase_enum);
                  ("status", enum_schema ~description:"Optional legacy status filter" goal_status_enum);
                ] );
            ("additionalProperties", `Bool false);
          ];
    };
    {
      name = "masc_goal_upsert";
      description =
        "Create or update a shared Goal Store entry used by Planning > Goal Tree. \
For new goals, provide at least title; omitted horizon defaults to short. \
After creation, link tasks into the tree with task.goal_id=<goal_id>; legacy [goal:<id>] title markers remain supported for compatibility. \
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
                  ("horizon", enum_schema goal_horizon_enum);
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
      name = "masc_goal_review";
      description =
        "Compatibility wrapper for legacy goal review flows. \
Use masc_goal_transition / masc_goal_verify for the full Goal FSM and quorum verification.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("goal_id", `Assoc [ ("type", `String "string") ]);
                  ("outcome", enum_schema goal_review_outcome_enum);
                  ("new_horizon", enum_schema goal_horizon_enum);
                  ("note", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "goal_id"; `String "outcome" ]);
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
Supports mixed operator and keeper principals, one vote per principal, and N-of-M quorum resolution.";
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
