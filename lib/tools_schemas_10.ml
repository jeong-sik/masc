(** Split chunk from tools.ml; private schema registry. *)

open Types

let schemas : tool_schema list = [
  {
    name = "masc_gardener_execute_spawn";
    description = "Create a new agent in Neo4j and post an announcement after spawn approval. \
Call when masc_gardener_propose_spawn returned approval. \
After propose_spawn approval; consumes daily spawn budget and resets the cooldown timer.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("topic", `Assoc [
          ("type", `String "string");
          ("description", `String "The topic/role that was approved for spawn");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Spawn reason (for audit)");
        ]);
        ("urgency", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "low"; `String "medium"; `String "high"; `String "critical"]);
          ("description", `String "Urgency level");
          ("default", `String "medium");
        ]);
      ]);
      ("required", `List [`String "topic"]);
    ];
  };

  {
    name = "masc_gardener_execute_retire";
    description = "Initiate grace period for an agent retirement after approval, posting a warning (not immediate removal). \
Call when masc_gardener_retire_agent returned approval. \
After retire_agent approval; the agent has a grace period to increase activity before final removal.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Name of the agent to retire");
        ]);
      ]);
      ("required", `List [`String "agent_name"]);
    ];
  };

  {
    name = "masc_gardener_reset_circuit";
    description = "Manually reset the gardener circuit breaker that is stuck open after consecutive failures. \
Use when the root cause of gardener failures has been fixed and the breaker needs clearing. \
Pair with masc_gardener_config to verify breaker state before and after reset.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  (* ============================================ *)
  (* Library Tools - Agent Knowledge Base        *)
  (* ============================================ *)

  {
    name = "masc_library_list";
    description = "List all documents in the agent knowledge library with title, confidence, source, and tags. \
Use when browsing available knowledge or checking if a topic is already documented. \
Pair with masc_library_read to fetch a specific document or masc_library_search to query by content.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("include_candidates", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Include candidate documents awaiting verification");
        ]);
      ]);
    ];
  };

  {
    name = "masc_library_read";
    description = "Read a specific library document by topic name or partial match. \
Use when you need the full content of a known knowledge document. \
After masc_library_list or masc_library_search to find the topic name.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("topic", `Assoc [
          ("type", `String "string");
          ("description", `String "Topic name or partial match (e.g., 'eio-mutex')");
        ]);
      ]);
      ("required", `List [`String "topic"]);
    ];
  };

  {
    name = "masc_library_add";
    description = "Add a new document to the agent knowledge library (confidence < 0.5 goes to candidates/ for review). \
Use when recording a new finding, experiment result, or pattern that other agents should know about. \
Follow up with masc_library_promote to move candidates to the main library after verification.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("title", `Assoc [
          ("type", `String "string");
          ("description", `String "Document title");
        ]);
        ("source", `Assoc [
          ("type", `String "string");
          ("description", `String "Source type: direct_experience, research, experiment, observation");
          ("enum", `List [`String "direct_experience"; `String "research"; `String "experiment"; `String "observation"]);
        ]);
        ("confidence", `Assoc [
          ("type", `String "number");
          ("description", `String "Confidence score 0.0-1.0");
        ]);
        ("tags", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "List of tags");
        ]);
        ("content", `Assoc [
          ("type", `String "string");
          ("description", `String "Document body content (markdown)");
        ]);
      ]);
      ("required", `List [`String "title"; `String "source"; `String "confidence"; `String "content"]);
    ];
  };

  {
    name = "masc_library_promote";
    description = "Promote a candidate document to the main library after verification (new confidence must be >= 0.5). \
Use when a candidate document has been reviewed and confirmed as accurate. \
After masc_library_add placed the document in candidates/.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("topic", `Assoc [
          ("type", `String "string");
          ("description", `String "Topic name to promote");
        ]);
        ("confidence", `Assoc [
          ("type", `String "number");
          ("description", `String "New confidence score (must be >= 0.5)");
        ]);
      ]);
      ("required", `List [`String "topic"; `String "confidence"]);
    ];
  };

  {
    name = "masc_library_search";
    description = "Search the agent knowledge library by content keywords or tags. \
Use when looking for documents on a specific topic without knowing the exact title. \
Pair with masc_library_read to fetch matching documents in full.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("query", `Assoc [
          ("type", `String "string");
          ("description", `String "Search query");
        ]);
      ]);
      ("required", `List [`String "query"]);
    ];
  };

  {
    name = "masc_verify_request";
    description = "Request peer verification of a task's output against optional criteria. \
Use when a completed task needs quality sign-off from another agent. \
Follow up with masc_verify_submit to provide a verdict or masc_verify_auto for automated checks.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID to verify");
        ]);
        ("output", `Assoc [
          ("description", `String "Task output payload to verify");
        ]);
        ("criteria", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [
            ("type", `String "object");
            ("description", `String "Verification criteria definition");
          ]);
          ("description", `String "Optional list of verification criteria");
        ]);
        ("verifier", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional verifier agent");
        ]);
      ]);
      ("required", `List [`String "task_id"]);
    ];
  };

  {
    name = "masc_verify_submit";
    description = "Submit a pass/fail/partial verdict for a pending verification request. \
Use when you have reviewed a task output and are ready to provide your assessment. \
After masc_verify_request creates the verification; pair with masc_verify_status to confirm submission.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("verification_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Verification request ID");
        ]);
        ("verdict", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "pass"; `String "fail"; `String "partial"]);
          ("description", `String "Verification result");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Reason for the verdict");
        ]);
        ("score", `Assoc [
          ("type", `String "number");
          ("description", `String "Score for partial verdict");
        ]);
      ]);
      ("required", `List [`String "verification_id"; `String "verdict"]);
    ];
  };

  {
    name = "masc_verify_status";
    description = "Check the current status of a verification request by its ID. \
Use when waiting for a verification verdict or confirming a submission was recorded. \
After masc_verify_request or masc_verify_submit.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("verification_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Verification request ID");
        ]);
      ]);
      ("required", `List [`String "verification_id"]);
    ];
  };

  {
    name = "masc_verify_pending";
    description = "List pending verification requests assigned to the current agent. \
Use when checking your verification inbox for tasks awaiting review. \
Follow up with masc_verify_submit to provide a verdict for each pending request.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_verify_auto";
    description = "Run automated verification checks for a pending verification request. \
Use when a task output can be verified programmatically instead of manual review. \
After masc_verify_request creates the request; alternative to manual masc_verify_submit.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("verification_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Verification request ID");
        ]);
      ]);
      ("required", `List [`String "verification_id"]);
    ];
  };

  (* ========== Code Navigation Tools ========== *)

  {
    name = "masc_code_search";
    description = "Search code using ripgrep with regex support, returning structured results (file, line, content). \
Use when finding function names, patterns, or text across the codebase from within MASC. \
Pair with masc_code_symbols for file-level symbol outlines or masc_code_read for targeted line ranges.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("query", `Assoc [
          ("type", `String "string");
          ("description", `String "Search pattern (supports regex)");
        ]);
        ("path", `Assoc [
          ("type", `String "string");
          ("description", `String "Search path (default: current directory)");
          ("default", `String ".");
        ]);
        ("file_pattern", `Assoc [
          ("type", `String "string");
          ("description", `String "Glob pattern to filter files (e.g., '*.ml', '*.py')");
          ("default", `String "");
        ]);
        ("case_insensitive", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Case-insensitive search (default: true)");
          ("default", `Bool true);
        ]);
        ("max_results", `Assoc [
          ("type", `String "number");
          ("description", `String "Maximum number of results (default: 50)");
          ("default", `Int 50);
        ]);
      ]);
      ("required", `List [`String "query"]);
    ];
  };

  {
    name = "masc_code_symbols";
    description = "Extract symbols (functions, types, classes) from a file as a token-efficient outline (~70% savings vs full read). \
Use when you need to understand a file's structure without reading all content. \
Pair with masc_code_read to then read specific line ranges of interest.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("path", `Assoc [
          ("type", `String "string");
          ("description", `String "File path to extract symbols from");
        ]);
      ]);
      ("required", `List [`String "path"]);
    ];
  };

  {
    name = "masc_code_read";
    description = "Read a file with offset/limit pagination for token-efficient access to specific sections. \
Use when you know the line range you need, especially for large files. \
After masc_code_symbols identifies the relevant line numbers.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("path", `Assoc [
          ("type", `String "string");
          ("description", `String "File path to read");
        ]);
        ("offset", `Assoc [
          ("type", `String "number");
          ("description", `String "Starting line number (0-indexed, default: 0)");
          ("default", `Int 0);
        ]);
        ("limit", `Assoc [
          ("type", `String "number");
          ("description", `String "Maximum lines to read (default: 100)");
          ("default", `Int 100);
        ]);
      ]);
      ("required", `List [`String "path"]);
    ];
  };

  {
    name = "masc_tool_stats";
    description = "Return in-memory tool usage statistics: top tools by call count, stale tools (30+ days unused), and never-called tools. \
Use when auditing tool adoption or identifying dead tools for cleanup. \
Pair with masc_tool_help for details on specific tools. Data resets on server restart.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("top_n", `Assoc [
          ("type", `String "integer");
          ("description", `String "Number of top tools to return (default: 20)");
          ("default", `Int 20);
        ]);
      ]);
    ];
  };

  {
    name = "masc_tool_help";
    description = "Return canonical help text, parameters, and metadata for a specific MASC tool by name. \
Use when you need detailed usage guidance for a tool beyond its short description. \
Pair with masc_tool_stats to discover which tools exist.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("tool_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Exact MCP tool name to explain");
        ]);
      ]);
      ("required", `List [`String "tool_name"]);
    ];
  };
  {
    name = "masc_tool_admin_snapshot";
    description = "Return a unified admin snapshot of tool inventory, auth/RBAC, mode gates, keeper policy, and command-plane surfaces. \
Use when auditing the full server configuration or diagnosing tool visibility issues. \
Pair with masc_tool_admin_update to apply changes based on the snapshot.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("include_hidden", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Include hidden tools in tool_inventory (default: true)");
          ("default", `Bool true);
        ]);
        ("include_deprecated", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Include deprecated tools in tool_inventory (default: true)");
          ("default", `Bool true);
        ]);
      ]);
    ];
  };
  {
    name = "masc_tool_admin_update";
    description = "Apply mode, auth, unit-policy, or keeper-policy updates through a single admin entrypoint. \
Use when changing server mode, toggling auth, or updating unit/keeper policies. \
After masc_tool_admin_snapshot to review current state before making changes.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("section", `Assoc [
          ("type", `String "string");
          ("description", `String "One of: mode, auth, unit_policy, keeper_policy, persistent_agent_policy");
        ]);
        ("mode", `Assoc [
          ("type", `String "string");
          ("description", `String "Preset mode to switch to for section=mode");
        ]);
        ("enabled_categories", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Custom category set for section=mode");
        ]);
        ("enabled", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Enable or disable auth for section=auth");
        ]);
        ("require_token", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Require tokens for section=auth");
        ]);
        ("default_role", `Assoc [
          ("type", `String "string");
          ("description", `String "Default role for unauthenticated agents: reader|worker|admin");
        ]);
        ("token_expiry_hours", `Assoc [
          ("type", `String "integer");
          ("description", `String "Token expiry in hours for section=auth");
        ]);
        ("unit_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Managed unit id for section=unit_policy");
        ]);
        ("policy", `Assoc [
          ("type", `String "object");
          ("description", `String "Unit policy envelope for section=unit_policy");
        ]);
        ("budget", `Assoc [
          ("type", `String "object");
          ("description", `String "Unit budget envelope for section=unit_policy");
        ]);
        ("name", `Assoc [
          ("type", `String "string");
          ("description", `String "Keeper or persistent agent name for policy updates");
        ]);
        ("policy_mode", `Assoc [
          ("type", `String "string");
          ("description", `String "Keeper policy mode: heuristic | learned_offline_v1");
        ]);
        ("action_budget", `Assoc [
          ("type", `String "string");
          ("description", `String "Keeper action budget: conversation | board");
        ]);
        ("autonomy_level", `Assoc [
          ("type", `String "string");
          ("description", `String "Keeper autonomy level such as L2_Suggestive or L4_Autonomous");
        ]);
        ("reward_model_path", `Assoc [
          ("type", `String "string");
          ("description", `String "Reward model path for learned_offline_v1 keeper policy");
        ]);
      ]);
      ("required", `List [`String "section"]);
    ];
  };
]
