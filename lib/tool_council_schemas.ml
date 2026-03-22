(** Tool council schemas — MCP tool definitions for governance tools. *)

let definitions =
  [
    `Assoc
      [
        ("name", `String "masc_petition_submit");
        ("description", `String "Submit a governance petition and file or merge a case in Governance V2. \
Use when proposing a policy change, reporting a violation, or requesting a governance action. \
Pair with masc_case_status to track the resulting case.");
        ( "inputSchema",
          `Assoc
            [
              ("type", `String "object");
              ( "properties",
                `Assoc
                  [
                    ("title", `Assoc [ ("type", `String "string") ]);
                    ("origin", `Assoc [ ("type", `String "string") ]);
                    ("subject_type", `Assoc [ ("type", `String "string") ]);
                    ("risk_class", `Assoc [ ("type", `String "string"); ("enum", `List [ `String "low"; `String "high" ]) ]);
                    ( "requested_action",
                      `Assoc
                        [
                          ("type", `String "object");
                          ( "properties",
                            `Assoc
                              [
                                ("action_type", `Assoc [ ("type", `String "string") ]);
                                ("target_type", `Assoc [ ("type", `String "string") ]);
                                ("target_id", `Assoc [ ("type", `String "string") ]);
                                ("payload", `Assoc [ ("type", `String "object") ]);
                              ] );
                        ] );
                    ( "source_refs",
                      `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ] );
                  ] );
              ("required", `List [ `String "title" ]);
            ] );
      ];
    `Assoc
      [
        ("name", `String "masc_case_brief_submit");
        ("description", `String "Add a brief (support/oppose/neutral) to a governance case, which can trigger a ruling and execution order. \
Use when providing evidence or opinion on an open governance case. \
After masc_case_status identifies the case_id; pair with masc_ruling_status to check for a ruling.");
        ( "inputSchema",
          `Assoc
            [
              ("type", `String "object");
              ( "properties",
                `Assoc
                  [
                    ("case_id", `Assoc [ ("type", `String "string") ]);
                    ("stance", `Assoc [ ("type", `String "string"); ("enum", `List [ `String "support"; `String "oppose"; `String "neutral" ]) ]);
                    ("summary", `Assoc [ ("type", `String "string") ]);
                    ( "evidence_refs",
                      `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ] );
                  ] );
              ("required", `List [ `String "case_id"; `String "summary" ]);
            ] );
      ];
    `Assoc
      [
        ("name", `String "masc_cases");
        ("description", `String "List governance cases from Governance V2 with optional status filter. \
Use when reviewing open, pending, or resolved governance cases. \
Pair with masc_case_status to inspect a specific case in detail.");
        ( "inputSchema",
          `Assoc
            [
              ("type", `String "object");
              ( "properties",
                `Assoc
                  [
                    ("status", `Assoc [ ("type", `String "string") ]);
                    ("include_test", `Assoc [ ("type", `String "boolean") ]);
                  ] );
            ] );
      ];
    `Assoc
      [
        ("name", `String "masc_case_status");
        ("description", `String "Read a single Governance V2 case bundle with petitions, briefs, and rulings. \
Use when inspecting the full details of a specific governance case. \
After masc_cases lists available cases; pair with masc_case_brief_submit to contribute.");
        ( "inputSchema",
          `Assoc
            [
              ("type", `String "object");
              ("properties", `Assoc [ ("case_id", `Assoc [ ("type", `String "string") ]) ]);
              ("required", `List [ `String "case_id" ]);
            ] );
      ];
    `Assoc
      [
        ("name", `String "masc_ruling_status");
        ("description", `String "Read the latest ruling for a Governance V2 case. \
Use when checking whether a case has been decided and what the outcome is. \
After masc_case_brief_submit may trigger a ruling; pair with masc_execution_orders for enforcement.");
        ( "inputSchema",
          `Assoc
            [
              ("type", `String "object");
              ("properties", `Assoc [ ("case_id", `Assoc [ ("type", `String "string") ]) ]);
              ("required", `List [ `String "case_id" ]);
            ] );
      ];
    `Assoc
      [
        ("name", `String "masc_governance_rule");
        ("description", `String "Submit an explicit ruling on a Governance V2 case. \
Approve, deny, or dismiss a pending case with a summary and optional evidence. \
Use when a case needs a decision: stale cases can be dismissed, valid petitions approved or denied. \
After masc_case_status shows a pending case; pair with masc_ruling_status to verify.");
        ( "inputSchema",
          `Assoc
            [
              ("type", `String "object");
              ( "properties",
                `Assoc
                  [
                    ("case_id", `Assoc [ ("type", `String "string"); ("description", `String "Governance V2 case ID") ]);
                    ("decision", `Assoc [ ("type", `String "string"); ("enum", `List [ `String "approve"; `String "deny"; `String "dismiss" ]); ("description", `String "Ruling decision") ]);
                    ("summary", `Assoc [ ("type", `String "string"); ("description", `String "Ruling rationale") ]);
                    ("confidence", `Assoc [ ("type", `String "number"); ("description", `String "Confidence 0-1 (default 0.9)") ]);
                    ("evidence_refs", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]); ("description", `String "Evidence references") ]);
                  ] );
              ("required", `List [ `String "case_id"; `String "decision"; `String "summary" ]);
            ] );
      ];
    `Assoc
      [
        ("name", `String "masc_execution_orders");
        ("description", `String "List execution orders, inspect a case order, or confirm/deny a human gate decision. \
Use when reviewing or acting on enforcement actions from governance rulings. \
After masc_ruling_status shows a ruling; confirm/deny to execute or block the order.");
        ( "inputSchema",
          `Assoc
            [
              ("type", `String "object");
              ( "properties",
                `Assoc
                  [
                    ("case_id", `Assoc [ ("type", `String "string") ]);
                    ("decision", `Assoc [ ("type", `String "string"); ("enum", `List [ `String "confirm"; `String "deny" ]) ]);
                  ] );
            ] );
      ];
    `Assoc
      [
        ("name", `String "masc_governance_status");
        ("description", `String "Read a compact Governance V2 status summary with open cases, pending decisions, and recent rulings. \
Use when getting a quick overview of the governance system state. \
Pair with masc_cases for detailed case listing or masc_governance_report for audit-level detail.");
        ("inputSchema", `Assoc [ ("type", `String "object"); ("properties", `Assoc []) ]);
      ];
    `Assoc
      [
        ("name", `String "masc_route");
        ("description", `String "Route a query to appropriate agents using the governance router. \
Use when you need to find which agents should handle a governance-related question. \
Pair with masc_portal_open to directly contact the recommended agent.");
        ( "inputSchema",
          `Assoc
            [
              ("type", `String "object");
              ("properties", `Assoc [ ("query", `Assoc [ ("type", `String "string") ]) ]);
              ("required", `List [ `String "query" ]);
            ] );
      ];
    `Assoc
      [
        ("name", `String "masc_execute");
        ("description", `String "Execute a governance decision topic via the executor API to apply the ruling. \
Use when a governance ruling needs to be enforced as an action. \
After masc_ruling_status confirms the ruling; pair with masc_execute_dry_run to preview first.");
        ( "inputSchema",
          `Assoc
            [
              ("type", `String "object");
              ( "properties",
                `Assoc
                  [
                    ("topic", `Assoc [ ("type", `String "string") ]);
                    ("result", `Assoc [ ("type", `String "string") ]);
                  ] );
              ("required", `List [ `String "topic" ]);
            ] );
      ];
    `Assoc
      [
        ("name", `String "masc_execute_dry_run");
        ("description", `String "Dry-run the governance executor to preview what a ruling execution would do without applying it. \
Use when you want to verify the effects of a governance execution before committing. \
Before masc_execute to run the actual execution.");
        ( "inputSchema",
          `Assoc
            [
              ("type", `String "object");
              ( "properties",
                `Assoc
                  [
                    ("topic", `Assoc [ ("type", `String "string") ]);
                    ("result", `Assoc [ ("type", `String "string") ]);
                  ] );
              ("required", `List [ `String "topic" ]);
            ] );
      ];
    `Assoc
      [
        ("name", `String "masc_governance_feed");
        ("description", `String "Get a timeline of governance decisions, parameter changes, and human board posts.");
        ( "inputSchema",
          `Assoc
            [
              ("type", `String "object");
              ( "properties",
                `Assoc
                  [
                    ("filter", `Assoc [ ("type", `String "string"); ("enum", `List [ `String "decisions"; `String "human_only"; `String "all" ]); ("description", `String "Feed filter (default: decisions)") ]);
                    ("limit", `Assoc [ ("type", `String "integer"); ("description", `String "Max items (default: 20)") ]);
                  ] );
            ] );
      ];
    `Assoc
      [
        ("name", `String "masc_runtime_params");
        ("description", `String "List all governable runtime parameters with current values, defaults, and override status.");
        ("inputSchema", `Assoc [ ("type", `String "object"); ("properties", `Assoc []) ]);
      ];
    `Assoc
      [
        ("name", `String "masc_set_param");
        ("description", `String "Set a runtime parameter. Low-risk params apply immediately; high-risk params create a governance petition requiring approval.");
        ( "inputSchema",
          `Assoc
            [
              ("type", `String "object");
              ( "properties",
                `Assoc
                  [
                    ("param_key", `Assoc [ ("type", `String "string"); ("description", `String "Parameter key (e.g. lodge.tick_interval_seconds). Use masc_runtime_params to list available keys.") ]);
                    ("value", `Assoc [ ("description", `String "New value (number, string, or boolean depending on parameter type)") ]);
                    ("reason", `Assoc [ ("type", `String "string"); ("description", `String "Why this change is needed (recorded in audit log)") ]);
                  ] );
              ("required", `List [ `String "param_key"; `String "value" ]);
            ] );
      ];
  ]
