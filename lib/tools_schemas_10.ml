(** Split chunk from tools.ml; private schema registry. *)

open Types

let schemas : tool_schema list = [
  {
    name = "masc_gardener_execute_spawn";
    description = "Execute an approved spawn: create agent in Neo4j and post announcement. Use masc_gardener_propose_spawn first to check if spawn is allowed. This action consumes daily spawn budget and resets the cooldown timer.";
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
    description = "Execute an approved retirement: initiate grace period and post warning. The agent is warned but not immediately removed — they have a grace period to increase activity. Use masc_gardener_retire_agent first to check if retirement is allowed.";
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
    description = "Manually reset the circuit breaker if it's stuck open due to consecutive failures. Use with caution — only when you've addressed the root cause of the failures.";
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
    description = "List all documents in the agent knowledge library. Returns title, confidence, source, and tags for each document.";
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
    description = "Read a specific library document by topic name.";
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
    description = "Add a new document to the library. Documents with confidence < 0.5 go to candidates/.";
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
    description = "Promote a candidate document to the main library after verification.";
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
    description = "Search library documents by content or tags.";
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
    description = "Request verification of task output.";
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
    description = "Submit a verification verdict for a task request.";
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
    description = "Check verification status by request ID.";
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
    description = "List pending verification requests for the current agent.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_verify_auto";
    description = "Run automated verification for a request.";
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
    description = "Search code using ripgrep with regex support. Returns structured results with file path, line number, and matched content. Use for finding specific patterns, function names, or text across the codebase.";
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
    description = "Extract symbols (functions, types, classes) from a file using heuristics. Token-efficient alternative to reading full file content. Saves ~70% tokens by returning only symbol names and line numbers.";
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
    description = "Read file with offset/limit pagination. Token-efficient way to read specific sections of large files. Use with masc_code_symbols to determine relevant line ranges.";
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
    description = "In-memory tool usage statistics for the current server session. Returns top-20 tools by call count, tools unused for 30+ days, and tools never called. Data resets on server restart; telemetry.jsonl is the durable store.";
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
    description = "Return canonical help and metadata for a specific MASC tool.";
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
    description = "Return a unified admin snapshot of tool inventory, auth/RBAC, mode gates, keeper policy, and command-plane policy surfaces.";
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
    description = "Apply mode, auth, unit-policy, or keeper-policy updates through a single admin entrypoint.";
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
