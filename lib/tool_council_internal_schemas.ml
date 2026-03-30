(** Tool_council_internal_schemas — Types.tool_schema definitions for
    council governance tools.

    These are the internal dispatch schemas (with [input_schema] field),
    separate from {!Tool_council_schemas} which provides the MCP protocol
    definitions (with [inputSchema] field).

    @since 2.122.0 *)

let schemas : Types.tool_schema list = [
  {
    name = "masc_petition_submit";
    description = "Submit a Governance V2 petition. Creates or merges a case, records requested action metadata, and files the item into the petition inbox.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("title", `Assoc [
          ("type", `String "string");
          ("description", `String "Petition title or agenda item");
        ]);
        ("origin", `Assoc [
          ("type", `String "string");
          ("description", `String "Origin tag such as human, automation, test, or harness");
        ]);
        ("subject_type", `Assoc [
          ("type", `String "string");
          ("description", `String "Subject classification such as task, operation, policy, or dispute");
        ]);
        ("risk_class", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "low"; `String "high"]);
          ("description", `String "Explicit risk classification. If omitted, the runtime derives it from the requested action.");
        ]);
        ("requested_action", `Assoc [
          ("type", `String "object");
          ("description", `String "Action metadata to execute when the case is adopted");
          ("properties", `Assoc [
            ("action_type", `Assoc [("type", `String "string")]);
            ("target_type", `Assoc [("type", `String "string")]);
            ("target_id", `Assoc [("type", `String "string")]);
            ("payload", `Assoc [("type", `String "object")]);
          ]);
        ]);
        ("source_refs", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Evidence or source references attached to the petition");
        ]);
      ]);
      ("required", `List [`String "title"]);
    ];
  };
  {
    name = "masc_case_brief_submit";
    description = "Add a support/oppose/neutral brief to a Governance V2 case. Brief submission can trigger a ruling and execution order.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("case_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Governance V2 case ID");
        ]);
        ("stance", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "support"; `String "oppose"; `String "neutral"]);
          ("description", `String "Brief stance for the case");
        ]);
        ("summary", `Assoc [
          ("type", `String "string");
          ("description", `String "Short brief text");
        ]);
        ("evidence_refs", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Evidence references supporting the brief");
        ]);
      ]);
      ("required", `List [`String "case_id"; `String "summary"]);
    ];
  };
  {
    name = "masc_cases";
    description = "List Governance V2 cases. Use this instead of the legacy debate/session listing tools.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("status", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional case status filter");
        ]);
        ("include_test", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Include test/harness cases that are hidden by default");
        ]);
      ]);
    ];
  };
  {
    name = "masc_case_status";
    description = "Read a single Governance V2 case bundle including petitions, briefs, ruling, and execution order.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("case_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Governance V2 case ID");
        ]);
      ]);
      ("required", `List [`String "case_id"]);
    ];
  };
  {
    name = "masc_ruling_status";
    description = "Read the latest Governance V2 ruling (approved, denied, pending) for a case. Use when checking whether a governance petition has been decided before proceeding with the action.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("case_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Governance V2 case ID");
        ]);
      ]);
      ("required", `List [`String "case_id"]);
    ];
  };
  {
    name = "masc_execution_orders";
    description = "List Governance V2 execution orders, inspect one case order, or confirm/deny a human gate.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("case_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Governance V2 case ID");
        ]);
        ("decision", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "confirm"; `String "deny"]);
          ("description", `String "Optional human-gate decision for a high-risk execution order");
        ]);
      ]);
    ];
  };
  {
    name = "masc_governance_status";
    description = "Get Governance V2 status (pending rulings, auto-executable cases, human-gated orders, executed cases).";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_route";
    description = "Route a query to the best-fit agents using deterministic heuristic classification and sparse tier selection, returning selected agents and estimated cost. \
Use when you have a task and need to identify which agents should handle it. \
Pair with masc_dispatch_assign to actually assign work to the selected agents.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("query", `Assoc [
          ("type", `String "string");
          ("description", `String "The query to route");
        ]);
        ("max_agents", `Assoc [
          ("type", `String "integer");
          ("description", `String "Max agents to select (default: 3)");
        ]);
      ]);
      ("required", `List [`String "query"]);
    ];
  };
  {
    name = "masc_execute";
    description = "Execute an action based on a governance decision by matching the topic pattern to a handler. \
Use when a governance ruling has been made and the resulting action needs to run (e.g., 'Merge PR #123'). \
Call masc_execute_dry_run first to preview. Pair with masc_execution_orders for the order context.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("topic", `Assoc [
          ("type", `String "string");
          ("description", `String "The decision topic (e.g., 'Merge PR #456')");
        ]);
        ("result", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "unanimous"; `String "majority"; `String "deadlock"]);
          ("description", `String "Voting result (default: majority)");
        ]);
      ]);
      ("required", `List [`String "topic"]);
    ];
  };
  {
    name = "masc_execute_dry_run";
    description = "Preview what action a governance execution would take without actually running it. \
Use when you want to verify the matched handler and parameters before committing to masc_execute. \
Pair with masc_execute to run the action after confirming the dry-run output.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("topic", `Assoc [
          ("type", `String "string");
          ("description", `String "The decision topic");
        ]);
        ("result", `Assoc [
          ("type", `String "string");
          ("description", `String "Voting result");
        ]);
      ]);
      ("required", `List [`String "topic"]);
    ];
  };
  {
    name = "masc_governance_feed";
    description = "Get a timeline of governance decisions, parameter changes, and human board posts.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("filter", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "decisions"; `String "human_only"; `String "all"]);
          ("description", `String "Feed filter (default: decisions)");
        ]);
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description", `String "Max items (default: 20)");
        ]);
      ]);
    ];
  };
  {
    name = "masc_runtime_params";
    description = "List all governable runtime parameters with current values, defaults, and override status.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_set_param";
    description = "Set a runtime parameter. Low-risk params apply immediately; high-risk params create a governance petition requiring approval.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("param_key", `Assoc [
          ("type", `String "string");
          ("description", `String "Parameter key (e.g. autonomy.tick_interval_seconds). Use masc_runtime_params to list available keys.");
        ]);
        ("value", `Assoc [
          ("description", `String "New value (number, string, or boolean depending on parameter type)");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Why this change is needed (recorded in audit log)");
        ]);
      ]);
      ("required", `List [`String "param_key"; `String "value"]);
    ];
  };
]
