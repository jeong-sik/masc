(** Tool Team Session Schemas — MCP tool JSON schema definitions.

    Extracted from tool_team_session.ml for modularity.
    Pure data module — no logic, zero dependencies beyond Types. *)

open Types

let schemas : tool_schema list =
  [
    {
      name = "masc_team_session_start";
      description =
        "Start a supervised team collaboration session with periodic checkpoints and final report artifacts. \
Use when orchestrating multi-agent work that needs progress tracking and proof generation. \
Pair with masc_team_session_step to record turns and masc_team_session_finalize to end.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ( "goal",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("description", `String "Session goal (required)");
                      ] );
                  ( "operation_id",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "description",
                          `String
                            "Optional managed operation id to attach this team session to. When provided, the operation detachment_session_id is updated to this session." );
                      ] );
                  ( "duration_seconds",
                    `Assoc
                      [
                        ("type", `String "integer");
                        ( "description",
                          `String
                            "Session duration in seconds (default: 3600)" );
                      ] );
                  ( "duration_minutes",
                    `Assoc
                      [
                        ("type", `String "integer");
                        ( "description",
                          `String
                            "Session duration in minutes (used when duration_seconds is omitted)" );
                      ] );
                  ( "execution_scope",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "enum",
                          `List
                            [
                              `String "observe_only";
                              `String "limited_code_change";
                              `String "autonomous";
                            ] );
                      ] );
                  ( "checkpoint_interval_sec",
                    `Assoc
                      [
                        ("type", `String "integer");
                        ( "description",
                          `String "Checkpoint interval in seconds (default: 60)"
                        );
                      ] );
                  ( "min_agents",
                    `Assoc
                      [
                        ("type", `String "integer");
                        ( "description",
                          `String "Minimum expected participating agents" );
                      ] );
                  ( "orchestration_mode",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "enum",
                          `List
                            [
                              `String "manual";
                              `String "assist";
                              `String "auto";
                            ] );
                      ] );
	                  ( "communication_mode",
	                    `Assoc
	                      [
	                        ("type", `String "string");
                        ( "enum",
                          `List
                            [
                              `String "off";
                              `String "broadcast";
                              `String "portal";
	                              `String "hybrid";
	                            ] );
	                      ] );
	                  ( "scale_profile",
	                    `Assoc
	                      [
	                        ("type", `String "string");
	                        ("enum", `List [ `String "standard"; `String "local64" ]);
	                      ] );
	                  ( "control_profile",
	                    `Assoc
	                      [
	                        ("type", `String "string");
	                        ("enum", `List [ `String "flat"; `String "hierarchical_quality_v1" ]);
	                      ] );
	                  ( "model_cascade",
	                    `Assoc
	                      [
	                        ("type", `String "array");
                        ("items", `Assoc [ ("type", `String "string") ]);
                      ] );
                  ( "fallback_policy",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "enum",
                          `List
                            [
                              `String "none";
                              `String "cascade_then_task";
                              `String "task_only";
                              `String "local_first_conditional";
                              `String "strict_local_only";
                              `String "cloud_first";
                            ] );
                      ] );
                  ( "instruction_profile",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("enum", `List [ `String "standard"; `String "strict" ]);
                      ] );
                  ( "alert_channel",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "enum",
                          `List
                            [ `String "broadcast"; `String "board"; `String "both" ]
                        );
                      ] );
                  ( "auto_resume",
                    `Assoc
                      [
                        ("type", `String "boolean");
                        ( "description",
                          `String "Recover and resume after process restart" );
                      ] );
                  ( "report_formats",
                    `Assoc
                      [
                        ("type", `String "array");
                        ("items", `Assoc [ ("type", `String "string") ]);
                      ] );
                  ( "agents",
                    `Assoc
                      [
                        ("type", `String "array");
                        ( "items",
                          `Assoc
                            [
                              ( "oneOf",
                                `List
                                  [
                                    `Assoc [ ("type", `String "string") ];
                                    `Assoc
                                      [
                                        ("type", `String "object");
                                        ( "properties",
                                          `Assoc
                                            [
                                              ("name", `Assoc [ ("type", `String "string") ]);
                                            ] );
                                      ];
                                  ] );
                            ] );
                      ] );
                ] );
            ("required", `List [ `String "goal" ]);
          ];
    };
    {
      name = "masc_team_session_status";
      description = "Get the current status, progress summary, and health metrics for a team session. \
Use when checking session progress mid-execution or after a checkpoint. \
After masc_team_session_start; pair with masc_team_session_events for detailed timeline.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc [ ("session_id", `Assoc [ ("type", `String "string") ]) ]
            );
            ("required", `List [ `String "session_id" ]);
          ];
    };
    {
      name = "masc_team_session_step";
      description =
        "Record a turn (note/broadcast/portal/task/checkpoint) in a team session, optionally spawning workers or attaching vote/run evidence. \
Use when advancing session progress with notes, delegating work, or recording checkpoints. \
After masc_team_session_start; the primary write path for all session activity.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("session_id", `Assoc [ ("type", `String "string") ]);
                  ( "turn_kind",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "enum",
                          `List
                            [
                              `String "note";
                              `String "broadcast";
                              `String "portal";
                              `String "task";
                              `String "checkpoint";
                            ] );
                      ] );
                  ( "actor",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "description",
                          `String
                            "Optional explicit actor. If provided, it must match the authenticated caller." );
                      ] );
                  ("message", `Assoc [ ("type", `String "string") ]);
                  ("target_agent", `Assoc [ ("type", `String "string") ]);
                  ("delegate_prompt", `Assoc [ ("type", `String "string") ]);
                  ("task_title", `Assoc [ ("type", `String "string") ]);
                  ("task_description", `Assoc [ ("type", `String "string") ]);
                  ("task_priority", `Assoc [ ("type", `String "integer") ]);
	                  ("spawn_role", `Assoc [ ("type", `String "string") ]);
	                  ( "execution_scope",
	                    `Assoc
	                      [
	                        ("type", `String "string");
	                        ( "enum",
	                          `List
	                            [
	                              `String "observe_only";
	                              `String "limited_code_change";
	                              `String "autonomous";
	                            ] );
	                      ] );
	                  ( "worker_class",
	                    `Assoc
	                      [
	                        ("type", `String "string");
	                        ( "enum",
	                          `List
	                            [
	                              `String "manager";
	                              `String "executor";
	                              `String "scout";
	                              `String "librarian";
	                              `String "metacog";
	                            ] );
	                      ] );
	                  ("parent_actor", `Assoc [ ("type", `String "string") ]);
	                  ( "capsule_mode",
	                    `Assoc
	                      [
	                        ("type", `String "string");
	                        ( "enum",
	                          `List
	                            [
	                              `String "fresh";
	                              `String "inherit";
	                              `String "capsule";
	                            ] );
	                      ] );
	                  ("runtime_pool", `Assoc [ ("type", `String "string") ]);
	                  ("lane_id", `Assoc [ ("type", `String "string") ]);
	                  ( "control_domain",
	                    `Assoc
	                      [
	                        ("type", `String "string");
	                        ( "enum",
	                          `List
	                            [
	                              `String "execution";
	                              `String "quality";
	                              `String "knowledge";
	                              `String "runtime";
	                              `String "meta";
	                            ] );
	                      ] );
	                  ("supervisor_actor", `Assoc [ ("type", `String "string") ]);
	                  ( "task_profile",
	                    `Assoc
	                      [
	                        ("type", `String "string");
	                        ( "enum",
	                          `List
	                            [
	                              `String "extract";
	                              `String "normalize";
	                              `String "summarize";
	                              `String "verify";
	                              `String "decide";
	                              `String "synthesize";
	                            ] );
	                      ] );
	                  ( "risk_level",
	                    `Assoc
	                      [
	                        ("type", `String "string");
	                        ( "enum",
	                          `List
	                            [
	                              `String "low";
	                              `String "medium";
	                              `String "high";
	                            ] );
	                      ] );
	                  ("routing_confidence", `Assoc [ ("type", `String "number") ]);
	                  ("routing_reason", `Assoc [ ("type", `String "string") ]);
	                  ("spawn_selection_note", `Assoc [ ("type", `String "string") ]);
	                  ("spawn_prompt", `Assoc [ ("type", `String "string") ]);
	                  ("spawn_timeout_seconds", `Assoc [ ("type", `String "integer") ]);
                  ( "delivery_contract",
                    `Assoc
                      [
                        ("type", `String "object");
                        ( "description",
                          `String
                            "Create or update the persisted delivery contract for this session. Planner turns should write acceptance checks here so later worker verification, report, and proof use the same contract." );
                        ( "properties",
                          `Assoc
                            [
                              ("contract_id", `Assoc [ ("type", `String "string") ]);
                              ("summary", `Assoc [ ("type", `String "string") ]);
                              ( "acceptance_checks",
                                `Assoc
                                  [
                                    ("type", `String "array");
                                    ("items", `Assoc [ ("type", `String "string") ]);
                                  ] );
                              ( "required_artifacts",
                                `Assoc
                                  [
                                    ("type", `String "array");
                                    ("items", `Assoc [ ("type", `String "string") ]);
                                  ] );
                              ("repair_budget", `Assoc [ ("type", `String "integer") ]);
                              ( "generator_roles",
                                `Assoc
                                  [
                                    ("type", `String "array");
                                    ("items", `Assoc [ ("type", `String "string") ]);
                                  ] );
                              ("evaluator_role", `Assoc [ ("type", `String "string") ]);
                              ("evaluator_cascade", `Assoc [ ("type", `String "string") ]);
                              ( "evidence_refs",
                                `Assoc
                                  [
                                    ("type", `String "array");
                                    ("items", `Assoc [ ("type", `String "string") ]);
                                  ] );
                            ] );
                      ] );
                  ( "wait_mode",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("enum", `List [ `String "background"; `String "blocking" ]);
                      ] );
                  ( "worker_policy",
                    `Assoc
                      [
                        ("type", `String "object");
                        ( "properties",
                          `Assoc
                            [
                              ("thinking", `Assoc [ ("type", `String "boolean"); ("description", `String "Enable extended thinking mode") ]);
                              ("thinking_budget", `Assoc [ ("type", `String "integer"); ("description", `String "Max thinking tokens (Anthropic only)") ]);
                              ("timeout_seconds", `Assoc [ ("type", `String "integer") ]);
                              ("max_turns", `Assoc [ ("type", `String "integer") ]);
                            ] );
                      ] );
                  ( "spawn_batch",
                    `Assoc
                      [
                        ("type", `String "array");
                        ( "items",
                          `Assoc
                            [
                              ("type", `String "object");
                              ( "properties",
                                `Assoc
	                                  [
	                                    ("spawn_role", `Assoc [ ("type", `String "string") ]);
	                                    ( "execution_scope",
	                                      `Assoc
	                                        [
	                                          ("type", `String "string");
	                                          ( "enum",
	                                            `List
	                                              [
	                                                `String "observe_only";
	                                                `String "limited_code_change";
	                                                `String "autonomous";
	                                              ] );
	                                        ] );
	                                    ( "worker_class",
	                                      `Assoc
	                                        [
	                                          ("type", `String "string");
	                                          ( "enum",
	                                            `List
	                                              [
	                                                `String "manager";
	                                                `String "executor";
	                                                `String "scout";
	                                                `String "librarian";
	                                                `String "metacog";
	                                              ] );
	                                        ] );
	                                    ("parent_actor", `Assoc [ ("type", `String "string") ]);
	                                    ( "capsule_mode",
	                                      `Assoc
	                                        [
	                                          ("type", `String "string");
	                                          ( "enum",
	                                            `List
	                                              [
	                                                `String "fresh";
	                                                `String "inherit";
	                                                `String "capsule";
	                                              ] );
	                                        ] );
	                                    ("runtime_pool", `Assoc [ ("type", `String "string") ]);
	                                    ("lane_id", `Assoc [ ("type", `String "string") ]);
	                                    ( "control_domain",
	                                      `Assoc
	                                        [
	                                          ("type", `String "string");
	                                          ( "enum",
	                                            `List
	                                              [
	                                                `String "execution";
	                                                `String "quality";
	                                                `String "knowledge";
	                                                `String "runtime";
	                                                `String "meta";
	                                              ] );
	                                        ] );
	                                    ("supervisor_actor", `Assoc [ ("type", `String "string") ]);
	                                    ( "task_profile",
	                                      `Assoc
	                                        [
	                                          ("type", `String "string");
	                                          ( "enum",
	                                            `List
	                                              [
	                                                `String "extract";
	                                                `String "normalize";
	                                                `String "summarize";
	                                                `String "verify";
	                                                `String "decide";
	                                                `String "synthesize";
	                                              ] );
	                                        ] );
	                                    ( "risk_level",
	                                      `Assoc
	                                        [
	                                          ("type", `String "string");
	                                          ( "enum",
	                                            `List
	                                              [
	                                                `String "low";
	                                                `String "medium";
	                                                `String "high";
	                                              ] );
	                                        ] );
	                                    ("routing_confidence", `Assoc [ ("type", `String "number") ]);
	                                    ("routing_reason", `Assoc [ ("type", `String "string") ]);
	                                    ( "spawn_selection_note",
	                                      `Assoc [ ("type", `String "string") ] );
	                                    ("spawn_prompt", `Assoc [ ("type", `String "string") ]);
                                    ( "spawn_timeout_seconds",
                                      `Assoc [ ("type", `String "integer") ] );
                                    ( "worker_policy",
                                      `Assoc
                                        [
                                          ("type", `String "object");
                                          ( "properties",
                                            `Assoc
                                              [
                                                ("thinking", `Assoc [ ("type", `String "boolean") ]);
                                                ("timeout_seconds", `Assoc [ ("type", `String "integer") ]);
                                                ("max_turns", `Assoc [ ("type", `String "integer") ]);
                                              ] );
                                        ] );
                                  ] );
                              ( "required",
                                `List
                                  [
                                    `String "spawn_prompt";
                                  ] );
                            ] );
                      ] );
                  ("vote_topic", `Assoc [ ("type", `String "string") ]);
                  ( "vote_options",
                    `Assoc
                      [
                        ("type", `String "array");
                        ("items", `Assoc [ ("type", `String "string") ]);
                      ] );
                  ("vote_required_votes", `Assoc [ ("type", `String "integer") ]);
                  ("vote_choice", `Assoc [ ("type", `String "string") ]);
                  ("run_task_id", `Assoc [ ("type", `String "string") ]);
                  ("run_note", `Assoc [ ("type", `String "string") ]);
                  ("run_deliverable", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "session_id" ]);
          ];
    };
    {
      name = "masc_team_session_finalize";
      description =
        "Stop a team session, wait for terminal status, then optionally generate report and proof artifacts in one call. \
Use when ending a session and you want both the stop and artifact generation done atomically. \
Alternative to calling masc_team_session_stop then masc_team_session_report separately.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("session_id", `Assoc [ ("type", `String "string") ]);
                  ("reason", `Assoc [ ("type", `String "string") ]);
                  ("wait_timeout_sec", `Assoc [ ("type", `String "integer") ]);
                  ("generate_report", `Assoc [ ("type", `String "boolean") ]);
                  ("generate_proof", `Assoc [ ("type", `String "boolean") ]);
                  ( "proof_level",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("enum", `List [ `String "standard"; `String "strong" ]);
                      ] );
                ] );
            ("required", `List [ `String "session_id" ]);
          ];
    };
    {
      name = "masc_team_session_stop";
      description =
        "Request graceful stop for a team session and optionally generate report artifacts. \
Use when the session goal is achieved or time is up. \
After masc_team_session_step turns are complete; follow with masc_team_session_prove for proof.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("session_id", `Assoc [ ("type", `String "string") ]);
                  ("reason", `Assoc [ ("type", `String "string") ]);
                  ("generate_report", `Assoc [ ("type", `String "boolean") ]);
                ] );
            ("required", `List [ `String "session_id" ]);
          ];
    };
    {
      name = "masc_team_session_report";
      description = "Generate or regenerate report artifacts (markdown summary, metrics) for a team session. \
Use when you need fresh reports after additional evidence or a re-run. \
After masc_team_session_stop; pair with masc_team_session_prove for verifiable proof.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("session_id", `Assoc [ ("type", `String "string") ]);
                  ("force_regenerate", `Assoc [ ("type", `String "boolean") ]);
                ] );
            ("required", `List [ `String "session_id" ]);
          ];
    };
    {
      name = "masc_team_session_list";
      description =
        "List recent team sessions with optional status filter and health/cascade summary. \
Use when finding past sessions to compare, resume, or audit. \
Pair with masc_team_session_compare to diff two sessions.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("status", `Assoc [ ("type", `String "string") ]);
                  ( "limit",
                    `Assoc
                      [
                        ("type", `String "integer");
                        ("description", `String "Max sessions to return (default: 20)");
                      ] );
                ] );
          ];
    };
    {
      name = "masc_team_session_compare";
      description =
        "Compare two team sessions side by side, returning throughput, policy, and communication deltas. \
Use when evaluating whether a configuration change improved session outcomes. \
After masc_team_session_list identifies the two session IDs.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("base_session_id", `Assoc [ ("type", `String "string") ]);
                  ("target_session_id", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "base_session_id"; `String "target_session_id" ]);
          ];
    };
    {
      name = "masc_team_session_events";
      description =
        "Read the team session event timeline with optional event type and timestamp filters. \
Use when reviewing what happened during a session or debugging a specific time range. \
After masc_team_session_start; the most-called session tool for progress monitoring.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("session_id", `Assoc [ ("type", `String "string") ]);
                  ( "event_types",
                    `Assoc
                      [
                        ("type", `String "array");
                        ("items", `Assoc [ ("type", `String "string") ]);
                      ] );
                  ("after_ts", `Assoc [ ("type", `String "number") ]);
                  ("limit", `Assoc [ ("type", `String "integer") ]);
                ] );
            ("required", `List [ `String "session_id" ]);
          ];
    };
    {
      name = "masc_team_session_prove";
      description =
        "Generate verifiable proof artifacts (proof.json/proof.md) for a team session based on timeline evidence. \
Use when session work needs an auditable proof trail with evidence hashes. \
After masc_team_session_stop or masc_team_session_report.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("session_id", `Assoc [ ("type", `String "string") ]);
                  ( "generate_report_if_missing",
                    `Assoc [ ("type", `String "boolean") ] );
                  ( "proof_level",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("enum", `List [ `String "standard"; `String "strong" ]);
                      ] );
                ] );
            ("required", `List [ `String "session_id" ]);
          ];
    };
  ]
