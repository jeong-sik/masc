(** Tool_council_internal_schemas — Types.tool_schema definitions for
    council governance tools.

    These are the internal dispatch schemas (with [input_schema] field),
    separate from {!Tool_council_schemas} which provides the MCP protocol
    definitions (with [inputSchema] field).

    @since 2.122.0 *)

let schemas : Types.tool_schema list = [
  {
    name = "masc_petition_submit";
    description = "Submit a governance petition to request an action that needs approval \
(e.g., merge a PR, change a policy, resolve a dispute). Creates a case in the governance \
system. Other agents can then submit briefs (masc_case_brief_submit) to support or oppose. \
Returns case_id. Check ruling with masc_ruling_status.";
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
    description = "Vote on a governance case by submitting a brief (support/oppose/neutral) \
with reasoning. When enough briefs are collected, a ruling is automatically generated. \
Use after reviewing a case with masc_case_status.";
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
    description = "List governance cases. Returns case_id, title, status (open/ruled/executed), \
and brief count for each case. Filter by status to find pending cases that need your brief.";
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
    description = "Read full details of a governance case: petition text, all briefs submitted, \
ruling (if decided), and execution order (if any). Use to understand a case before \
submitting your brief with masc_case_brief_submit.";
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
    description = "List pending execution orders from governance rulings. If a high-risk order \
requires human confirmation, you can confirm or deny it here. Without case_id, lists all \
pending orders. With case_id, shows that specific order. Returns order status and action.";
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
    description = "Overview of the governance system: count of pending rulings, cases awaiting \
briefs, human-gated orders needing confirmation, and recently executed decisions. \
Use as a dashboard check to see if any governance action needs your attention.";
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
    description = "Timeline of recent governance activity: decisions made, parameter changes, \
and human board posts. Use to catch up on what happened while you were offline. \
Filter by decisions (rulings only), human_only (board posts), or all.";
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
    description = "List all runtime parameters that can be changed via governance. \
Returns param_key, current_value, default_value, risk_class (low/high), and \
whether it is currently overridden. Use before masc_set_param to find valid keys.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_set_param";
    description = "Change a runtime parameter. Low-risk params (e.g., log_level) apply immediately. \
High-risk params (e.g., autonomy settings) create a governance petition requiring council \
approval. Returns status: applied or petition_created with case_id. \
Use masc_runtime_params to list available keys and their risk class.";
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
