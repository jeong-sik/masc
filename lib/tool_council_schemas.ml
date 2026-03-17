(** Tool council schemas — MCP tool definitions for governance tools. *)

let definitions =
  [
    `Assoc
      [
        ("name", `String "masc_petition_submit");
        ("description", `String "Submit a governance petition and file or merge a case in Governance V2.");
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
        ("description", `String "Add a brief to a governance case. Brief submission can trigger a ruling and execution order.");
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
        ("description", `String "List governance cases from Governance V2.");
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
        ("description", `String "Read a single Governance V2 case bundle.");
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
        ("description", `String "Read the latest ruling for a Governance V2 case.");
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
        ("name", `String "masc_execution_orders");
        ("description", `String "List execution orders, inspect a case order, or confirm/deny a human gate decision.");
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
        ("description", `String "Read a compact Governance V2 status summary.");
        ("inputSchema", `Assoc [ ("type", `String "object"); ("properties", `Assoc []) ]);
      ];
    `Assoc
      [
        ("name", `String "masc_route");
        ("description", `String "Route a query to appropriate agents using the governance router.");
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
        ("description", `String "Execute a governance decision topic via the executor API.");
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
        ("description", `String "Dry-run the governance executor for a topic and result.");
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
  ]
