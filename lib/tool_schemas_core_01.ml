open Types

let schemas : tool_schema list = [
  {
    name = "masc_init";
    description = "Initialize a MASC room by creating the .masc/ folder in the current project root. \
Use when starting a new multi-agent session for the first time; if .masc/ already exists, you auto-join instead. \
Workflow: masc_init -> masc_join -> masc_add_task/masc_claim_next -> masc_leave. Call once per project.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent identity: 'claude' (Claude Code), 'gemini' (Gemini CLI), or 'codex' (Codex CLI)");
        ]);
      ]);
    ];
  };
  {
    name = "masc_transition";
    description = "Transition a task through its lifecycle states via a single entrypoint. Actions: claim, start, done, cancel, release. \
Use when moving a task forward after masc_add_task or masc_claim_next. Supports optimistic concurrency via expected_version (CAS guard). \
Pair with masc_add_task to create tasks, then masc_transition to advance them.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name");
        ]);
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID (e.g., 'task-001')");
        ]);
        ("action", `Assoc [
          ("type", `String "string");
          ("description", `String "Transition action: claim | start | done | cancel | release");
        ]);
        ("expected_version", `Assoc [
          ("type", `String "integer");
          ("description", `String "Optional CAS guard (current backlog.version). Transition fails if mismatched");
        ]);
        ("notes", `Assoc [
          ("type", `String "string");
          ("description", `String "Completion notes (used with action='done')");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Cancellation reason (used with action='cancel')");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "task_id"; `String "action"]);
    ];
  };
  {
    name = "masc_register_capabilities";
    description = "Register your capabilities so other agents can discover you by skill. \
Call when joining a room or when your capabilities change. Pair with masc_find_by_capability for the lookup side. \
Examples: ['typescript', 'code-review', 'testing', 'python', 'architecture']. Discovery category.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name");
        ]);
        ("capabilities", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "List of your capabilities (e.g., ['typescript', 'testing'])");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "capabilities"]);
    ];
  };
  {
    name = "masc_find_by_capability";
    description = "Find active agents that match a given capability (e.g., 'typescript', 'testing'). Only returns non-zombie agents. \
Use when you need help with a specific skill and want to discover who is available. \
Pair with masc_register_capabilities (write side) and masc_a2a_delegate to send work. Discovery category.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("capability", `Assoc [
          ("type", `String "string");
          ("description", `String "Capability to search for (e.g., 'typescript')");
        ]);
      ]);
      ("required", `List [`String "capability"]);
    ];
  };
  {
    name = "masc_route";
    description = "Route a query to the best-matching agents using MoE-style selection. Returns selected agents, estimated cost, and complexity score. \
Use when you have a task but do not know which agent should handle it. \
After routing, use masc_a2a_delegate or masc_spawn to dispatch work to the selected agents.";
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
    name = "masc_generate_key";
    description = "Generate a random 256-bit encryption key in hex or base64 format. \
Use when setting up encrypted communication between agents or securing cached data. \
Store the key securely; losing it means losing access to encrypted data. Pair with governance tools for full security setup.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("output", `Assoc [
          ("type", `String "string");
          ("description", `String "Output format: 'hex' (64 chars), 'base64' (44 chars)");
          ("default", `String "hex");
        ]);
      ]);
    ];
  };
  {
    name = "masc_switch_mode";
    description = "Switch the active MASC tool surface to control token usage. Modes: minimal (core+health), standard (core+comm+worktree+health), \
parallel (multi-agent: comm+portal+discovery+voting), full (everything), solo (single-agent: core+worktree), custom (pick categories). \
Call when starting a session or changing collaboration scope. Use masc_get_config to see current mode. Most-called MASC tool.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("mode", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "minimal"; `String "standard"; `String "parallel"; `String "full"; `String "solo"; `String "custom"]);
          ("description", `String "Mode preset: minimal, standard, parallel, full, solo, or custom");
        ]);
        ("categories", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "For 'custom' mode: list of categories to enable (core, comm, portal, worktree, health, discovery, voting, interrupt, cost, auth, ratelimit, encryption)");
        ]);
      ]);
      ("required", `List [`String "mode"]);
    ];
  };
  {
    name = "masc_get_config";
    description = "Show the current MASC mode configuration including enabled/disabled tool categories and available presets. \
Use when you need to verify which tools are active before calling them, or to debug 'tool not found' errors. \
Pair with masc_switch_mode to change the active tool surface.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_spawn";
    description = "Spawn an agent process (claude, gemini, codex, or llama) to execute a task in a subprocess. \
Use when orchestrating multi-agent work without manual terminal setup. For llama, the model parameter is required. \
After spawning, monitor progress via masc_dashboard or masc_observe_swarm. Pair with masc_route for agent selection.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent to spawn: 'claude', 'gemini', 'codex', or custom command");
        ]);
        ("model", `Assoc [
          ("type", `String "string");
          ("description", `String "Explicit model id. Required when agent_name='llama'.");
        ]);
        ("prompt", `Assoc [
          ("type", `String "string");
          ("description", `String "The task/prompt to send to the agent");
        ]);
        ("timeout_seconds", `Assoc [
          ("type", `String "integer");
          ("default", `Int 300);
          ("description", `String "Max execution time in seconds (default: 300)");
        ]);
        ("working_dir", `Assoc [
          ("type", `String "string");
          ("description", `String "Working directory for the agent (optional)");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "prompt"]);
    ];
  };
  {
    name = "masc_relay_checkpoint";
    description = "Save a checkpoint of current work state (summary, TODOs, relevant files) for smooth handoff. \
Call when completing a subtask, before starting a complex operation, or periodically in long sessions. \
Pair with masc_relay_now to trigger handoff using the saved checkpoint. Enables proactive relay with minimal context loss.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("summary", `Assoc [
          ("type", `String "string");
          ("description", `String "Brief summary of work done so far");
        ]);
        ("current_task", `Assoc [
          ("type", `String "string");
          ("description", `String "Current task being worked on (optional)");
        ]);
        ("todos", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "List of remaining TODO items");
        ]);
        ("pdca_state", `Assoc [
          ("type", `String "string");
          ("description", `String "Current PDCA cycle state (optional)");
        ]);
        ("relevant_files", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "List of files being worked on");
        ]);
      ]);
      ("required", `List [`String "summary"]);
    ];
  };
  {
    name = "masc_relay_now";
    description = "Trigger an immediate relay handoff to a new agent, passing compressed context for seamless continuation. \
Use when your context window is getting full or before a task that would exceed remaining capacity. \
After masc_relay_checkpoint saves state, call this to execute the handoff. The successor inherits your work.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("summary", `Assoc [
          ("type", `String "string");
          ("description", `String "Summary of work for handoff");
        ]);
        ("current_task", `Assoc [
          ("type", `String "string");
          ("description", `String "Task to continue (optional)");
        ]);
        ("target_agent", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent to relay to (default: claude)");
          ("default", `String "claude");
        ]);
        ("generation", `Assoc [
          ("type", `String "integer");
          ("description", `String "Current relay generation (default: 0)");
          ("default", `Int 0);
        ]);
      ]);
      ("required", `List [`String "summary"]);
    ];
  };
  {
    name = "masc_relay_smart_check";
    description = "Predict whether an upcoming task will overflow your context window and suggest relay before you start. \
Call when about to begin a large_file read, multi_file edit, long_running operation, or exploration. \
Pair with masc_relay_checkpoint to save state if relay is recommended. Prevents mid-task context exhaustion.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("messages", `Assoc [
          ("type", `String "integer");
          ("description", `String "Current message count");
        ]);
        ("tool_calls", `Assoc [
          ("type", `String "integer");
          ("description", `String "Current tool call count");
        ]);
        ("task_hint", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "large_file"; `String "multi_file"; `String "long_running"; `String "exploration"; `String "simple"]);
          ("description", `String "Hint about upcoming task complexity");
        ]);
        ("file_count", `Assoc [
          ("type", `String "integer");
          ("description", `String "For multi_file hint: number of files");
        ]);
      ]);
      ("required", `List [`String "task_hint"]);
    ];
  };
  {
    name = "masc_mitosis_all";
    description = "Get mitosis (context lifecycle) status of all agents in the cluster, including cross-machine peers. \
Use when coordinating handoffs or checking if another agent needs help due to context pressure. \
Pair with masc_mitosis_divide or masc_mitosis_handoff to assist agents approaching their limits.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_mitosis_pool";
    description = "View the stem cell pool of reserve agents pre-warmed for instant handoff. Shows warm cells, generation number, and readiness. \
Use when planning a handoff to check if a successor is already available, avoiding cold-start delay. \
Pair with masc_mitosis_divide to consume a warm cell, or masc_mitosis_handoff for automated lifecycle.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_mitosis_divide";
    description = "Manually trigger cell division: the current agent (parent) dies gracefully while a child agent inherits compressed context (DNA). \
Use when you want explicit control over the handoff moment rather than automatic threshold-based handoff. \
For automated lifecycle management, prefer masc_mitosis_handoff. Pair with masc_mitosis_prepare to extract DNA first.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("summary", `Assoc [
          ("type", `String "string");
          ("description", `String "Current context summary to compress into DNA");
        ]);
        ("current_task", `Assoc [
          ("type", `String "string");
          ("description", `String "The task to continue after division");
        ]);
      ]);
      ("required", `List [`String "summary"]);
    ];
  };
  {
    name = "masc_mitosis_check";
    description = "Check your current mitosis phase based on context_ratio. Phase 1 (50%): should_prepare=true, extract DNA. Phase 2 (80%): should_handoff=true, execute handoff. \
Call when you want to know your lifecycle phase without taking action. \
Pair with masc_mitosis_prepare at 50% and masc_mitosis_divide at 80%, or use masc_mitosis_handoff for the full automated flow.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("context_ratio", `Assoc [
          ("type", `String "number");
          ("description", `String "Current context usage ratio (0.0-1.0)");
        ]);
      ]);
    ];
  };
  {
    name = "masc_mitosis_record";
    description = "Record an activity event (task completion or tool call) to update mitosis trigger counters. \
Call when you finish a task or make a tool call so that mitosis thresholds stay accurate. \
Pair with masc_mitosis_check to read the counters and determine if handoff preparation is needed.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_done", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Whether a task was completed");
        ]);
        ("tool_called", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Whether a tool was called");
        ]);
      ]);
    ];
  };
  {
    name = "masc_mitosis_prepare";
    description = "Phase 1 of mitosis: extract compressed DNA from your full context and mark yourself as ready for division. Does NOT handoff yet. \
Call when masc_mitosis_check reports should_prepare=true (around 50% context). \
After preparation, masc_mitosis_divide or masc_mitosis_handoff executes the actual handoff at 80%.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("full_context", `Assoc [
          ("type", `String "string");
          ("description", `String "Full context to extract DNA from (will be compressed)");
        ]);
      ]);
      ("required", `List [`String "full_context"]);
    ];
  };
  {
    name = "masc_mitosis_handoff";
    description = "Automated 2-phase context lifecycle manager. Call periodically with your estimated context_ratio. \
<50%: returns 'none' (keep working). 50-80%: returns 'prepared' (DNA extracted). >80%: returns 'handoff' (spawns successor). \
Use when you want hands-off lifecycle management instead of manual masc_mitosis_check/prepare/divide steps. \
Supports async saga, LLM verification, and configurable pass consensus. The primary mitosis tool for most agents.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("context_ratio", `Assoc [
          ("type", `String "number");
          ("description", `String "Estimated context usage (0.0-1.0). E.g., 0.5 = 50%");
        ]);
        ("full_context", `Assoc [
          ("type", `String "string");
          ("description", `String "Current context/summary to pass to successor (required for prepare/handoff)");
        ]);
        ("target_agent", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent to spawn: 'claude'|'gemini'|'codex'|'llama' (default: claude). Prefer 'default' in model fields for adapter-managed selection; explicit provider:model labels remain available as overrides.");
        ]);
        ("async", `Assoc [
          ("type", `String "boolean");
          ("description", `String "If true (default), return immediately and run handoff as background saga.");
          ("default", `Bool true);
        ]);
        ("verify", `Assoc [
          ("type", `String "boolean");
          ("description", `String "If true (default), run LLM verifier on handoff result and store it in saga payload.");
          ("default", `Bool true);
        ]);
        ("verifier_models", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Verifier model list. Prefer 'default' or 'default:<model>' for normal use; explicit provider:model labels remain valid as overrides.");
        ]);
        ("verifier_perspectives", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Optional perspective labels matched by index to verifier_models.");
        ]);
        ("verifier_profile", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "abc_neutral"; `String "abc_strict"; `String "abc_lenient"]);
          ("description", `String "Use fixed A/B/C perspective templates when verifier_perspectives is omitted.");
          ("default", `String "abc_neutral");
        ]);
        ("verifier_goal", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional verifier goal prompt override.");
        ]);
        ("verification_policy", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "advisory"; `String "gate"]);
          ("description", `String "advisory: never block handoff result. gate: require verifier consensus.");
          ("default", `String "advisory");
        ]);
        ("verification_min_judges", `Assoc [
          ("type", `String "integer");
          ("description", `String "Minimum number of verifier checks required for gate pass (default: 3, clamped to available verifier_models count).");
          ("default", `Int 3);
        ]);
        ("verification_pass_ratio", `Assoc [
          ("type", `String "number");
          ("description", `String "Required pass ratio for consensus (default: 2/3 ~= 0.6667).");
          ("default", `Float 0.6666666666666666);
        ]);
        ("verification_min_agreement", `Assoc [
          ("type", `String "number");
          ("description", `String "Required inter-judge agreement ratio for consensus (default: 2/3 ~= 0.6667).");
          ("default", `Float 0.6666666666666666);
        ]);
        ("verification_judge_timeout_sec", `Assoc [
          ("type", `String "number");
          ("description", `String "Per-judge verifier timeout in seconds (default: 60). Timeout verdict becomes WARN.");
          ("default", `Float 60.0);
        ]);
        ("verification_saga_timeout_sec", `Assoc [
          ("type", `String "number");
          ("description", `String "Async handoff saga max wall-time in seconds (default: 180). On timeout saga fails.");
          ("default", `Float 180.0);
        ]);
      ]);
      ("required", `List [`String "context_ratio"]);
    ];
  };
  {
    name = "masc_metrics_compare";
    description = "Compare performance metrics between two agent generations (completion rate, error rate, duration, token efficiency). \
Returns a verdict: improved, degraded, or neutral. \
Use when evaluating whether mitosis succession is producing better agents over time. \
Pair with masc_metrics_record to populate the data that this tool analyzes.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("gen_a", `Assoc [
          ("type", `String "integer");
          ("description", `String "First generation to compare (older)");
        ]);
        ("gen_b", `Assoc [
          ("type", `String "integer");
          ("description", `String "Second generation to compare (newer)");
        ]);
      ]);
      ("required", `List [`String "gen_a"; `String "gen_b"]);
    ];
  };
  {
    name = "masc_metrics_record";
    description = "Record a task completion event (duration, errors, tokens) for generational performance tracking. \
Call when you finish a task to feed data into the metrics system. \
Pair with masc_metrics_compare to analyze trends across generations.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Unique task identifier");
        ]);
        ("completed", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Whether task was completed successfully");
        ]);
        ("duration_ms", `Assoc [
          ("type", `String "integer");
          ("description", `String "Task duration in milliseconds");
        ]);
        ("error_count", `Assoc [
          ("type", `String "integer");
          ("description", `String "Number of errors encountered");
        ]);
        ("input_tokens", `Assoc [
          ("type", `String "integer");
          ("description", `String "Input tokens used");
        ]);
        ("output_tokens", `Assoc [
          ("type", `String "integer");
          ("description", `String "Output tokens generated");
        ]);
      ]);
      ("required", `List [`String "task_id"; `String "completed"]);
    ];
  };
  {
    name = "masc_memento_mori";
    description = "All-in-one context health check combining mitosis check + prepare + divide in a single call. \
<50%: continue. 50-80%: auto-prepares DNA. >80%: auto-divides and spawns successor. \
Call when you want a simple periodic lifecycle check without managing individual mitosis steps. \
Similar to masc_mitosis_handoff but with a simpler interface. Use either one, not both.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("context_ratio", `Assoc [
          ("type", `String "number");
          ("description", `String "Current context usage ratio (0.0-1.0). Estimate based on messages/tool calls.");
        ]);
        ("full_context", `Assoc [
          ("type", `String "string");
          ("description", `String "Current conversation context for DNA extraction (required if context_ratio > 0.5)");
        ]);
        ("summary", `Assoc [
          ("type", `String "string");
          ("description", `String "Brief summary of current work for handoff (optional, defaults to auto-generated)");
        ]);
        ("current_task", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID being worked on (optional)");
        ]);
        ("target_agent", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent to spawn as successor (default: claude)");
        ]);
      ]);
      ("required", `List [`String "context_ratio"]);
    ];
  };
  {
    name = "masc_episode_flush";
    description = "Flush locally queued episodes to Neo4j (graph) and PostgreSQL (relational) persistent storage. \
Use when episodes have accumulated during mitosis handoffs and need to be persisted. Returns flushed/failed/pending counts. \
Call periodically or after handoff events. Pair with masc_episode_list to verify persisted episodes.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description", `String "Max episodes to flush per call (default: 10)");
        ]);
        ("dry_run", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Preview without saving to DB (default: false)");
        ]);
      ]);
    ];
  };
  {
    name = "masc_episode_list";
    description = "List recent agent episodes from PostgreSQL with optional filters by agent_name and generation. \
Use when debugging agent lineage, reviewing past handoffs, or understanding what a previous generation accomplished. \
Pair with masc_episode_flush to ensure local episodes are persisted before querying.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Filter by agent name (optional)");
        ]);
        ("generation", `Assoc [
          ("type", `String "integer");
          ("description", `String "Filter by generation number (optional)");
        ]);
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description", `String "Max results (default: 20)");
        ]);
      ]);
    ];
  };
  {
    name = "masc_self_introspect";
    description = "Return your current lifecycle state: generation number, context usage, sibling agents, parent episode, and estimated remaining lifespan. \
Use when you need self-awareness about your position in the agent lineage or to decide if mitosis preparation is needed. \
Pair with masc_mitosis_check for threshold-based decisions or masc_episode_list for historical context. Discovery category.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_recall_search";
    description = "Search agent episodic memories using semantic relevance scoring. Returns matched memories sorted by relevance. \
Use when you need to recall past experiences, decisions, or context from previous generations or sessions. \
Pair with masc_episode_list for structured episode queries, or masc_self_introspect for current lifecycle state.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("query", `Assoc [
          ("type", `String "string");
          ("description", `String "Natural language query for semantic search");
        ]);
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description", `String "Max results to return (default: 5)");
        ]);
      ]);
      ("required", `List [`String "query"]);
    ];
  };
  {
    name = "masc_discover_tools";
    description = "Search the full MASC tool catalog by keyword. The default tools/list shows only tools for the current mode. Use this to find specialized tools (TRPG, gardener, perpetual, governance, etc.) that are not in the default list but still callable via tools/call.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("query", `Assoc [
          ("type", `String "string");
          ("description", `String "Search keyword (matches tool name and description). Examples: 'trpg', 'gardener', 'perpetual', 'vote', 'encrypt'");
        ]);
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description", `String "Max results (default: 20)");
        ]);
      ]);
      ("required", `List [`String "query"]);
    ];
  };
]
