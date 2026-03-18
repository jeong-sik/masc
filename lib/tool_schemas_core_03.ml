open Types

let schemas : tool_schema list = [
  {
    name = "masc_walph_loop";
    description = "Autonomous claim-work-done loop that drains a task backlog using a preset strategy. \nUse when you need repeated task execution (test coverage, lint, docs, review, figma SSIM, or drain). \nPair with masc_walph_control to STOP/PAUSE/RESUME mid-run. Also controllable via @walph in broadcast.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name for claiming tasks");
        ]);
        ("preset", `Assoc [
          ("type", `String "string");
          ("enum", `List [
            `String "coverage";
            `String "refactor";
            `String "docs";
            `String "review";
            `String "figma";
            `String "drain"
          ]);
          ("description", `String "Loop preset: coverage (80%+ test coverage), refactor (0 lint errors), docs (90%+ doc coverage), review (PR self-review), figma (SSIM visual fidelity loop), drain (empty backlog)");
          ("default", `String "drain");
        ]);
        ("max_iterations", `Assoc [
          ("type", `String "integer");
          ("description", `String "Maximum iterations before forced stop (default: 10)");
          ("default", `Int 10);
          ("minimum", `Int 1);
          ("maximum", `Int 100);
        ]);
        ("max_consecutive_errors", `Assoc [
          ("type", `String "integer");
          ("description", `String "Stop loop after this many consecutive errors (default: 5)");
          ("default", `Int 5);
          ("minimum", `Int 1);
          ("maximum", `Int 100);
        ]);
        ("error_backoff_sec", `Assoc [
          ("type", `String "integer");
          ("description", `String "Sleep seconds after an error before retrying (default: 2)");
          ("default", `Int 2);
          ("minimum", `Int 0);
          ("maximum", `Int 300);
        ]);
        ("target", `Assoc [
          ("type", `String "string");
          ("description", `String "Target file or directory for preset (e.g., src/utils.ts)");
        ]);
      ]);
      ("required", `List [`String "agent_name"]);
    ];
  };
  {
    name = "masc_walph_control";
    description = "Send a control command (STOP, PAUSE, RESUME, STATUS) to a running walph loop. \
Use when you need to halt, suspend, or inspect a walph loop mid-execution. \
Pair with masc_walph_loop which starts the loop. Broadcast '@walph STOP' is equivalent.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("command", `Assoc [
          ("type", `String "string");
          ("description", `String "Control command");
          ("enum", `List [`String "STOP"; `String "PAUSE"; `String "RESUME"; `String "STATUS"]);
        ]);
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent sending the command (for audit trail)");
        ]);
      ]);
      ("required", `List [`String "command"; `String "agent_name"]);
    ];
  };
  {
    name = "masc_walph_natural";
    description = "Interpret a natural-language message (Korean or English) and map it to a walph control action. \nUse when human input is informal (e.g. 'stop the loop'). \nCalls masc_walph_loop or masc_walph_control internally after intent classification.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("message", `Assoc [
          ("type", `String "string");
          ("description", `String "Natural language message to interpret (e.g., '커버리지 좀 올려줘', 'stop the loop', '지금 진행상황 알려줘')");
        ]);
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent sending the command (for audit trail)");
        ]);
      ]);
      ("required", `List [`String "message"; `String "agent_name"]);
    ];
  };
  {
    name = "masc_hat_wear";
    description = "Assign a role hat to an agent, specializing its behavior for a task domain. \nUse when switching focus: builder (code), reviewer, researcher, tester, architect, debugger, documenter. \nPair with masc_hat_status to check current hat. Broadcast shows as @agent:hat.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("hat", `Assoc [
          ("type", `String "string");
          ("description", `String "Hat to wear");
          ("enum", `List [
            `String "builder"; `String "reviewer"; `String "researcher";
            `String "tester"; `String "architect"; `String "debugger"; `String "documenter"
          ]);
          ("default", `String "builder");
        ]);
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent wearing the hat");
        ]);
      ]);
      ("required", `List [`String "agent_name"]);
    ];
  };
  {
    name = "masc_convo_start";
    description = "Open a new multi-agent conversation thread on a topic and get a thread_id. \
Use when agents need structured discussion (design decisions, reviews, disputes). \
After starting, use masc_convo_reply to add turns and masc_convo_conclude to close.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("topic", `Assoc [
          ("type", `String "string");
          ("description", `String "Conversation topic or question");
        ]);
        ("initiator", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent name starting the conversation");
        ]);
        ("initial_content", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional opening message");
        ]);
        ("max_turns", `Assoc [
          ("type", `String "integer");
          ("description", `String "Maximum turns allowed (default: 50)");
          ("default", `Int 50);
        ]);
        ("post_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Board post ID to link this thread to (bidirectional: thread.source_post_id ↔ post.thread_id)");
        ]);
      ]);
      ("required", `List [`String "topic"; `String "initiator"]);
    ];
  };
  {
    name = "masc_convo_reply";
    description = "Post a reply to an existing conversation thread. \
Use when contributing to an ongoing multi-agent discussion started by masc_convo_start. \
Built-in loop prevention blocks identical consecutive messages and enforces 2s cooldown per speaker.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("thread_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Thread ID from masc_convo_start");
        ]);
        ("speaker", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent name adding the reply");
        ]);
        ("content", `Assoc [
          ("type", `String "string");
          ("description", `String "Reply message content");
        ]);
        ("confidence", `Assoc [
          ("type", `String "number");
          ("description", `String "Speaker's confidence level (0.0-1.0)");
        ]);
        ("reply_to", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional turn ID being replied to");
        ]);
        ("mentions", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Agents @mentioned in this reply");
        ]);
      ]);
      ("required", `List [`String "thread_id"; `String "speaker"; `String "content"]);
    ];
  };
  {
    name = "masc_convo_conclude";
    description = "Close a conversation thread with a final summary or decision. \
Use when consensus is reached or discussion is complete. No further replies are allowed after this. \
Pair with masc_convo_start (open) and masc_convo_reply (discuss) to form the full lifecycle.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("thread_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Thread ID to conclude");
        ]);
        ("concluder", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent writing the conclusion");
        ]);
        ("conclusion", `Assoc [
          ("type", `String "string");
          ("description", `String "Final summary or decision text");
        ]);
      ]);
      ("required", `List [`String "thread_id"; `String "concluder"; `String "conclusion"]);
    ];
  };
  {
    name = "masc_convo_get";
    description = "Retrieve a conversation thread by ID, including all turns, participants, and current status. \
Use when you need to read the history of a discussion before replying or concluding. \
Pair with masc_convo_list to find thread IDs.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("thread_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Thread ID to retrieve");
        ]);
      ]);
      ("required", `List [`String "thread_id"]);
    ];
  };
  {
    name = "masc_convo_list";
    description = "List all active conversation threads in the current room. \
Use when checking what discussions are in progress before starting a new one. \
Pair with masc_convo_get to read a specific thread.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_gardener_health";
    description = "Return ecosystem health metrics: population stats, activity counts, homeostatic score, and recommendations. \
Use when deciding whether to spawn or retire agents. \
Pair with masc_gardener_propose_spawn or masc_gardener_retire_agent based on the score.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_gardener_config";
    description = "Return current Gardener configuration: population bounds, daily budgets, cooldowns, and circuit breaker state. \
Use when diagnosing why a spawn or retirement was rejected. \
Pair with masc_gardener_health for live ecosystem metrics.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_gardener_propose_spawn";
    description = "Evaluate whether a new agent should be spawned for a topic (approval/deferral/rejection). \nUse when a capability gap is detected and you want to check spawn eligibility before acting. \nDoes NOT create the agent. After approval, call masc_gardener_execute_spawn to proceed.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("topic", `Assoc [
          ("type", `String "string");
          ("description", `String "The role/topic for the new agent (e.g., 'security', 'UX', 'performance')");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Why this agent is needed");
        ]);
        ("urgency", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "low"; `String "medium"; `String "high"; `String "critical"]);
          ("description", `String "How urgent the need is (default: medium)");
          ("default", `String "medium");
        ]);
      ]);
      ("required", `List [`String "topic"]);
    ];
  };
  {
    name = "masc_library_list";
    description = "List all documents in the agent knowledge library with title, confidence, source, and tags. \
Use when browsing available knowledge before reading or adding a document. \
Pair with masc_library_read for full content or masc_library_search for keyword lookup.";
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
    description = "Read the full content of a library document by topic name or partial match. \
Use when you need detailed knowledge on a specific topic (e.g. 'eio-mutex'). \
Pair with masc_library_list to find available topics first.";
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
    description = "Add a new document to the agent knowledge library. Documents with confidence < 0.5 go to candidates/. \
Use when capturing a new learning, experiment result, or operational pattern for future reference. \
After adding a candidate, use masc_library_promote once verified.";
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
    description = "Promote a candidate document to the main library after verification (confidence must be >= 0.5). \
Use when a candidate document added via masc_library_add has been validated through testing or review. \
Pair with masc_library_list (include_candidates=true) to find promotable documents.";
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
    description = "Search library documents by content keywords or tags. \
Use when looking for specific knowledge without knowing the exact topic name. \
Pair with masc_library_read to get the full document once you find a match.";
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
    description = "Request verification of a completed task's output by another agent or automated check. \
Use when a task is done and needs quality review before marking it accepted. \
After requesting, the verifier calls masc_verify_submit with a pass/fail/partial verdict.";
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
Use when you are the assigned verifier and have reviewed the task output. \
Called after masc_verify_request creates the review. Check masc_verify_pending for your queue.";
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
    name = "masc_verify_pending";
    description = "List pending verification requests assigned to you or unassigned. \
Use when checking if any task outputs need your review. \
After identifying a request, call masc_verify_submit or masc_verify_auto to process it.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_verify_auto";
    description = "Run automated verification checks (tests, lint, build) for a pending verification request. \
Use when manual review is not needed and the verification criteria can be checked programmatically. \
Alternative to masc_verify_submit for cases where automated checks suffice.";
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
    name = "masc_code_search";
    description = "Search code using ripgrep with regex support, returning file path, line number, and matched content. \
Use when finding function definitions, patterns, or text across the codebase from within MASC. \
Pair with masc_code_symbols for a token-efficient overview or masc_code_read for targeted file reading.";
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
    description = "Extract symbol names (functions, types, classes) and line numbers from a file using heuristics. \
Use when you need a file overview without reading full content (saves ~70% tokens). \
Pair with masc_code_read to then read only the relevant line ranges you identified.";
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
Use when reading large files where full content would waste context. \
Pair with masc_code_symbols to find relevant line ranges, then read only those ranges.";
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
Data resets on server restart; telemetry.jsonl is the durable store.";
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
Use when you need to understand a tool's purpose, required params, or usage before calling it. \
Pair with masc_tool_stats for usage frequency or masc_tool_admin_snapshot for the full inventory.";
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
    description = "Return a unified admin snapshot: tool inventory, auth/RBAC config, mode gates, keeper policy, and command-plane surfaces. \
Use when diagnosing tool visibility issues or auditing system-wide access controls. \
Pair with masc_tool_admin_update to modify any of the surfaces returned.";
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
Use when changing tool visibility mode, toggling auth, or adjusting keeper autonomy level. \
Pair with masc_tool_admin_snapshot to inspect current state before making changes.";
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
  {
    name = "masc_keeper_tool_catalog";
    description = "List all visible masc_* tools alongside keeper-internal wrapper coverage, filterable by tier. \
Use when checking which tools keepers can proxy and which lack wrapper coverage. \
Pair with masc_tool_admin_snapshot for the broader admin view including auth and mode gates.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("tier", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional tier filter: essential, standard, full");
        ]);
        ("include_hidden", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Include hidden tools in the catalog");
        ]);
        ("include_deprecated", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Include deprecated tools in the catalog");
        ]);
      ]);
    ];
  };
]
