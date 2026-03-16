open Types

let schemas : tool_schema list = [
  {
    name = "masc_init";
    description = "Initialize MASC room for multi-agent collaboration. Creates .masc/ folder in current project. Call this ONCE at the start of a multi-agent session. If .masc/ already exists, you'll auto-join. Workflow: init → join → (claim tasks / broadcast / portal) → leave";
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
    description = "Unified task state transition (single entrypoint). Actions: claim, start, done, cancel, release. Supports CAS via expected_version (backlog.version). Use notes for done, reason for cancel.";
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
    description = "Register your capabilities for agent discovery. Other agents can then find you by capability. Examples: ['typescript', 'code-review', 'testing', 'python', 'architecture'].";
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
    description = "Find agents by capability. Use this to discover who can help with specific tasks. Only returns non-zombie agents.";
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
    description = "Route a query to appropriate agents using MoE-style selection. \
Returns: selected agents, estimated cost, complexity score.";
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
    description = "Generate a new random 256-bit encryption key. Returns the key in hex format. Store this securely - losing the key means losing access to encrypted data.";
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
    description = "Switch MASC mode to reduce token usage. Available modes: 'minimal' (core+health), 'standard' (core+comm+worktree+health), 'parallel' (multi-agent heavy: comm+portal+discovery+voting+interrupt), 'full' (all features), 'solo' (single-agent: core+worktree). Use 'custom' with categories parameter for fine-grained control.";
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
    description = "Get current MASC mode configuration. Shows enabled categories, disabled categories, and available mode presets.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_spawn";
    description = "Spawn an agent to execute a task. Use this to orchestrate multi-agent collaboration without manual terminal setup. When agent_name='llama', you must provide model explicitly.";
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
    description = "Save a checkpoint of current state for smooth handoff. Call at key moments (after completing subtasks, before complex operations). Checkpoints enable proactive relay with minimal context loss.";
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
    description = "Trigger immediate relay to a new agent. Use when context is getting full or before a complex task. The new agent will receive compressed context and continue seamlessly.";
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
    description = "Proactive relay check with task hint. Predicts if upcoming task will overflow context and suggests relay BEFORE starting the task. Key for smooth transitions.";
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
    description = "Get mitosis status of ALL agents in the cluster (cross-machine). Shows each agent's context pressure so you can see if another agent needs handoff help. Use for collaboration awareness.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_mitosis_pool";
    description = "View the stem cell pool - reserve agents ready for instant handoff. Shows warm cells, their generation, and readiness state.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_mitosis_divide";
    description = "Manually trigger cell division (mitosis). Parent cell dies gracefully (apoptosis) while child cell inherits compressed DNA (context). Use for proactive handoff.";
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
    description = "2-Phase mitosis check. Phase 1 (50%): should_prepare=true → extract DNA. Phase 2 (80%): should_handoff=true → execute handoff. Returns current phase and thresholds.";
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
    description = "Record activity for mitosis trigger tracking. Call after completing tasks or tool calls to update counters.";
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
    description = "Phase 1: Prepare for division - extract DNA and mark cell as ready. Does NOT handoff yet. Call this at 50% context to prepare early, actual handoff happens at 80%.";
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
    description = {|2-Phase Proactive Context Management - THE CORE MITOSIS TOOL

Call this periodically with your estimated context_ratio. It handles the full lifecycle:
- <50%: Returns "none" - continue working normally
- 50-80%: Returns "prepared" - DNA extracted, ready for handoff
- >80%: Returns "handoff" - spawns successor agent with DNA

Unlike masc_mitosis_divide (manual), this auto-detects phase and takes appropriate action.
Embodies proactive mitosis: prepare early at 50%, handoff at 80%.|};
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
    description = {|Compare generational performance metrics.

Evidence for "Are successors better than predecessors?"
Compares two generations across:
- Task completion rate
- Error rate
- Duration (speed)
- Token efficiency

Returns verdict: "improved" / "degraded" / "neutral"|};
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
    description = {|Record a task completion for generational metrics.

Call after completing a task to track performance across generations.|};
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
    description = {|Memento Mori - Agent self-awareness of mortality.
A convenience tool combining mitosis check + prepare + divide in one call.
Call this periodically to check your context health and auto-handle lifecycle:
- <50%: Returns "continue" - keep working
- 50-80%: Auto-prepares DNA, returns "prepared" - ready for handoff when needed
- >80%: Auto-divides and spawns successor, returns handoff result

This embodies the philosophical concept of "memento mori" - agents should be aware
of their context limits and gracefully hand over work to successors.|};
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
    description = {|Flush pending episodes to Neo4j and PostgreSQL.

Episodes are queued locally during mitosis handoff (file-based queue for reliability).
This tool flushes them to persistent storage (Neo4j for graph relationships, PostgreSQL for queries).

Part of the Agent Being Protocol - agents are "beings" with memory continuity across generations.

Returns:
- flushed: Number of episodes successfully saved to DB
- failed: Number of episodes that failed (kept in queue for retry)
- pending: Remaining episodes in queue|};
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
    description = {|List recent episodes from PostgreSQL.

Query agent episodes with optional filters. Returns episode metadata for debugging
and understanding agent lineage.

Part of the Agent Being Protocol - agents can reflect on their history.|};
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
    description = {|Agent self-awareness introspection.

Returns the agent's current lifecycle state:
- generation: Current generation number (how many mitosis events in lineage)
- context_used: Estimated context usage percentage
- siblings: Other agents of the same generation in the room
- parent_episode: Episode ID of the parent (if known)
- estimated_lifespan: Tokens/turns remaining before mitosis needed

Part of the Agent Being Protocol - agents should know their place in the lifecycle.|};
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_recall_search";
    description = {|Semantic memory search using local memory sources.

Searches the agent's episodic memories using relevance scoring.
Part of the Agent Being Protocol - agents can recall relevant past experiences.

Returns matched memories with relevance scores, sorted by relevance.|};
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
]
