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
  {
    name = "masc_a2a_discover";
    description = "Discover available A2A agents. Returns agent cards with capabilities, skills, and protocol bindings. Use for local room discovery or remote endpoint fetching.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("endpoint", `Assoc [
          ("type", `String "string");
          ("description", `String "Remote endpoint URL (optional, defaults to local room)");
        ]);
        ("capability", `Assoc [
          ("type", `String "string");
          ("description", `String "Filter by capability (e.g., 'typescript', 'code-review')");
        ]);
      ]);
    ];
  };
  {
    name = "masc_a2a_query_skill";
    description = "Query detailed information about an agent's skill, including input/output modes and examples. Use to understand what a skill can do before delegating.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Target agent name");
        ]);
        ("skill_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Skill ID to query (e.g., 'task-management', 'git-worktree')");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "skill_id"]);
    ];
  };
  {
    name = "masc_a2a_delegate";
    description = "Delegate a task to another A2A agent. Opens portal, sends task, returns task ID. Use sync for waiting, async for fire-and-forget, stream for real-time updates.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("target_agent", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent to delegate to");
        ]);
        ("task_type", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "sync"; `String "async"; `String "stream"]);
          ("default", `String "async");
          ("description", `String "Type: 'sync' (wait), 'async' (fire-and-forget), 'stream' (real-time)");
        ]);
        ("message", `Assoc [
          ("type", `String "string");
          ("description", `String "Task description or prompt to send");
        ]);
        ("artifacts", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [
            ("type", `String "object");
            ("properties", `Assoc [
              ("name", `Assoc [("type", `String "string")]);
              ("mime_type", `Assoc [("type", `String "string")]);
              ("data", `Assoc [("type", `String "string")]);
            ]);
          ]);
          ("description", `String "Optional input artifacts (files, data)");
        ]);
        ("timeout", `Assoc [
          ("type", `String "integer");
          ("default", `Int 300);
          ("description", `String "Timeout in seconds (default: 300)");
        ]);
      ]);
      ("required", `List [`String "target_agent"; `String "message"]);
    ];
  };
  {
    name = "masc_a2a_subscribe";
    description = "Subscribe to events from agents (task updates, broadcasts, completions). Connect to SSE endpoint to receive events.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent to subscribe to (or '*' for all agents)");
        ]);
        ("events", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [
            ("type", `String "string");
            ("enum", `List [`String "task_update"; `String "broadcast"; `String "completion"; `String "error"]);
          ]);
          ("description", `String "Event types to subscribe to");
        ]);
      ]);
      ("required", `List [`String "events"]);
    ];
  };
  {
    name = "masc_a2a_unsubscribe";
    description = "Stop receiving events from a background subscription. \
Call when: (1) done monitoring, (2) switching to different events, (3) cleanup before leave. \
Frees server resources - always unsubscribe when done. \
Get subscription_id from masc_a2a_subscribe response. \
Example: masc_a2a_unsubscribe({subscription_id: 'sub-abc123'})";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("subscription_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Subscription ID to remove");
        ]);
      ]);
      ("required", `List [`String "subscription_id"]);
    ];
  };
  {
    name = "masc_poll_events";
    description = "Poll buffered events for a subscription. Use this for background subscription workflow: subscribe → do work → poll_events periodically. Returns and clears buffered events.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("subscription_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Subscription ID to poll events from");
        ]);
        ("clear", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Clear buffer after reading (default: true)");
          ("default", `Bool true);
        ]);
      ]);
      ("required", `List [`String "subscription_id"]);
    ];
  };
  {
    name = "masc_tempo";
    description = "Get or set cluster tempo (pace control). Use to slow down for careful work or speed up for simple tasks.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("action", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "get"; `String "set"]);
          ("description", `String "Get current tempo or set new tempo");
        ]);
        ("mode", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "normal"; `String "slow"; `String "fast"; `String "paused"]);
          ("description", `String "Tempo mode (only for set action)");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Why changing tempo");
        ]);
      ]);
      ("required", `List [`String "action"]);
    ];
  };
  {
    name = "masc_mcp_session";
    description = "Manage MCP sessions (Mcp-Session-Id; legacy X-MCP-Session-ID also accepted). Sessions track client context across requests.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("action", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "get"; `String "create"; `String "list"; `String "cleanup"; `String "remove"]);
          ("description", `String "Session action");
        ]);
        ("session_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Session ID (for get/remove)");
        ]);
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent name (for create)");
        ]);
      ]);
      ("required", `List [`String "action"]);
    ];
  };
  {
    name = "masc_cancellation";
    description = "Manage cancellation tokens for long-running operations. Check tokens to abort work gracefully.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("action", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "create"; `String "cancel"; `String "check"; `String "list"; `String "cleanup"]);
          ("description", `String "Cancellation action");
        ]);
        ("token_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Token ID (for cancel/check)");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Cancellation reason");
        ]);
      ]);
      ("required", `List [`String "action"]);
    ];
  };
  {
    name = "masc_subscription";
    description = "Subscribe to resource changes (tasks, agents, messages, votes). Receive notifications via polling or SSE.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("action", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "subscribe"; `String "unsubscribe"; `String "list"; `String "poll"]);
          ("description", `String "Subscription action");
        ]);
        ("subscriber", `Assoc [
          ("type", `String "string");
          ("description", `String "Subscriber ID (agent_name or session_id)");
        ]);
        ("resource", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "tasks"; `String "agents"; `String "messages"; `String "votes"]);
          ("description", `String "Resource type");
        ]);
        ("filter", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional filter (specific ID or '*')");
        ]);
        ("subscription_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Subscription ID (for unsubscribe/poll)");
        ]);
      ]);
      ("required", `List [`String "action"]);
    ];
  };
  {
    name = "masc_progress";
    description = "Send progress notifications for long-running tasks. Broadcasts via SSE using MCP notifications/progress format.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("action", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "start"; `String "update"; `String "step"; `String "complete"; `String "stop"]);
          ("description", `String "Progress action: start tracking, update progress, step forward, complete, or stop tracking");
        ]);
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task identifier for progress tracking");
        ]);
        ("progress", `Assoc [
          ("type", `String "number");
          ("description", `String "Progress value (0.0 to 1.0, for 'update' action)");
        ]);
        ("message", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional progress message");
        ]);
        ("total_steps", `Assoc [
          ("type", `String "integer");
          ("description", `String "Total steps (for 'start' action, default: 100)");
        ]);
      ]);
      ("required", `List [`String "action"; `String "task_id"]);
    ];
  };
  {
    name = "masc_handover_create";
    description = "Create a handover record (agent's 'last will') before context limit or session end. Contains goal, progress, decisions, warnings for the next agent. Inspired by Stanford Generative Agents memory stream + Erlang 'let it crash' supervisor pattern.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name (the dying agent)");
        ]);
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task being worked on");
        ]);
        ("session_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Current session identifier");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "context_limit"; `String "timeout"; `String "explicit"; `String "error"; `String "complete"]);
          ("description", `String "Why handover is triggered");
        ]);
        ("goal", `Assoc [
          ("type", `String "string");
          ("description", `String "Current goal being pursued");
        ]);
        ("progress", `Assoc [
          ("type", `String "string");
          ("description", `String "Summary of progress made");
        ]);
        ("completed_steps", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Steps already completed");
        ]);
        ("pending_steps", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Steps remaining to do");
        ]);
        ("decisions", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Key decisions made and why (implicit knowledge transfer)");
        ]);
        ("assumptions", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "What we're assuming is true");
        ]);
        ("warnings", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Gotchas and things to watch out for");
        ]);
        ("errors", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Unresolved errors from PDCA loop");
        ]);
        ("files", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Files modified during this session");
        ]);
        ("context_pct", `Assoc [
          ("type", `String "integer");
          ("description", `String "Context usage percentage when handover triggered");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "task_id"; `String "reason"; `String "goal"]);
    ];
  };
  {
    name = "masc_handover_list";
    description = "List all handover records, optionally filtering by pending (unclaimed) ones. Use to see what work is waiting to be picked up.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("pending_only", `Assoc [
          ("type", `String "boolean");
          ("description", `String "If true, only show unclaimed handovers");
          ("default", `Bool false);
        ]);
      ]);
    ];
  };
  {
    name = "masc_handover_get";
    description = "Get full details of a handover record as formatted markdown. Use to understand context before claiming.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("handover_id", `Assoc [
          ("type", `String "string");
          ("description", `String "ID of the handover to retrieve");
        ]);
      ]);
      ("required", `List [`String "handover_id"]);
    ];
  };
  {
    name = "masc_cache_set";
    description = "Set a cache entry for sharing context between agents. Useful for caching file contents, API responses, or expensive computations.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("key", `Assoc [
          ("type", `String "string");
          ("description", `String "Cache key (e.g., 'file:src/main.ts', 'jira:PK-123')");
        ]);
        ("value", `Assoc [
          ("type", `String "string");
          ("description", `String "Value to cache");
        ]);
        ("ttl_seconds", `Assoc [
          ("type", `String "integer");
          ("description", `String "Time-to-live in seconds. Omit for no expiry.");
        ]);
        ("tags", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Tags for filtering (e.g., ['file', 'typescript'])");
        ]);
      ]);
      ("required", `List [`String "key"; `String "value"]);
    ];
  };
  {
    name = "masc_cache_get";
    description = "Get a cached entry by key. Returns null if not found or expired.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("key", `Assoc [
          ("type", `String "string");
          ("description", `String "Cache key to retrieve");
        ]);
      ]);
      ("required", `List [`String "key"]);
    ];
  };
  {
    name = "masc_cache_delete";
    description = "Delete a specific cache entry. \
Use when: invalidating stale data, clearing specific key, freeing memory. \
No error if key doesn't exist. Use masc_cache_list to find keys.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("key", `Assoc [
          ("type", `String "string");
          ("description", `String "Cache key to delete");
        ]);
      ]);
      ("required", `List [`String "key"]);
    ];
  };
  {
    name = "masc_cache_list";
    description = "List cache entries with keys, TTL remaining, and tags. \
Filter by tag to find related entries. Shows creation time and expiry. \
Use before: cache cleanup, debugging stale data, finding specific entries. \
Example: masc_cache_list({tag: 'api'}) → [{key: 'user_123', ttl: 3600, tags: ['api']}]";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("tag", `Assoc [
          ("type", `String "string");
          ("description", `String "Filter by tag (optional)");
        ]);
      ]);
    ];
  };
  {
    name = "masc_cache_clear";
    description = "Delete ALL cache entries. DESTRUCTIVE - cannot be undone. \
Use only when: resetting room state, debugging cache issues, fresh start. \
Consider masc_cache_delete for targeted cleanup instead.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_cache_stats";
    description = "Get cache usage statistics. \
Shows: total entries, memory size, oldest/newest entry age, hit/miss ratio. \
Use to: monitor cache health, decide when to clear, debug performance.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_tempo_get";
    description = "Get current orchestrator tempo (check interval). Shows adaptive tempo status.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_tempo_set";
    description = "Set orchestrator tempo manually. Interval is clamped between 60s (fast) and 600s (slow).";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("interval_seconds", `Assoc [
          ("type", `String "number");
          ("description", `String "Check interval in seconds (60-600)");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Reason for tempo change");
        ]);
      ]);
      ("required", `List [`String "interval_seconds"]);
    ];
  };
  {
    name = "masc_tempo_adjust";
    description = "Automatically adjust tempo based on pending task urgency. Fast for urgent tasks, slow when idle.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_dashboard";
    description = "Show the MASC dashboard. By default it summarizes all rooms, and you can filter to the current room with scope='current'. Use with 'watch -n 1' for real-time updates.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("compact", `Assoc [
          ("type", `String "boolean");
          ("description", `String "If true, show compact single-line summary instead of full dashboard");
        ]);
        ("scope", `Assoc [
          ("type", `String "string");
          ("description", `String "Dashboard scope: 'all' (default) or 'current'");
          ("default", `String "all");
        ]);
      ]);
    ];
  };
  {
    name = "masc_collaboration_graph";
    description = "View the Hebbian collaboration graph showing learned agent relationships. Stronger connections indicate successful collaboration patterns.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("format", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "text"; `String "json"]);
          ("description", `String "Output format (default: text)");
          ("default", `String "text");
        ]);
      ]);
    ];
  };
  {
    name = "masc_consolidate_learning";
    description = "Trigger Hebbian consolidation - apply decay to old collaboration patterns and prune weak connections. Mimics memory consolidation during sleep.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("decay_after_days", `Assoc [
          ("type", `String "integer");
          ("description", `String "Apply decay to connections older than this (default: 7)");
          ("default", `Int 7);
        ]);
      ]);
    ];
  };
  {
    name = "masc_verify_handoff";
    description = "Verify handoff context integrity. Compares original and received context to detect semantic drift, information loss, or distortion. Threshold: 0.85 similarity.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("original", `Assoc [
          ("type", `String "string");
          ("description", `String "Original context before handoff");
        ]);
        ("received", `Assoc [
          ("type", `String "string");
          ("description", `String "Received context after handoff");
        ]);
        ("threshold", `Assoc [
          ("type", `String "number");
          ("description", `String "Similarity threshold (default: 0.85)");
          ("default", `Float 0.85);
        ]);
      ]);
      ("required", `List [`String "original"; `String "received"]);
    ];
  };
  {
    name = "masc_get_metrics";
    description = "Get raw performance metrics for an agent. Returns task completion data, timing, error rates, and collaboration history.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent name to get metrics for");
        ]);
        ("days", `Assoc [
          ("type", `String "integer");
          ("description", `String "Number of days of history (default: 7)");
          ("default", `Int 7);
        ]);
      ]);
      ("required", `List [`String "agent_name"]);
    ];
  };
  {
    name = "masc_audit_query";
    description = "Query audit logs to inspect agent actions and security events. Returns recent security events: auth success/failure, anomalies, violations. Use for trust verification and debugging collaboration issues.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent", `Assoc [
          ("type", `String "string");
          ("description", `String "Filter by agent name (optional)");
        ]);
        ("event_type", `Assoc [
          ("type", `String "string");
          ("enum", `List [
            `String "auth_success";
            `String "auth_failure";
            `String "anomaly_detected";
            `String "security_violation";
            `String "tool_call";
            `String "all"
          ]);
          ("description", `String "Filter by event type (default: all)");
          ("default", `String "all");
        ]);
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description", `String "Maximum events to return (default: 50)");
          ("default", `Int 50);
        ]);
        ("since_hours", `Assoc [
          ("type", `String "number");
          ("description", `String "Only show events from last N hours (default: 24)");
          ("default", `Float 24.0);
        ]);
      ]);
    ];
  };
  {
    name = "masc_audit_stats";
    description = "Get security statistics and trust metrics for agents. Shows auth success rate, anomaly count, task completion rate per agent. Use to evaluate agent reliability before delegation.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent", `Assoc [
          ("type", `String "string");
          ("description", `String "Specific agent to analyze (optional, shows all if omitted)");
        ]);
      ]);
    ];
  };
  {
    name = "masc_governance_report";
    description = "Generate a governance summary report from the audit trail. Aggregates per-agent action counts, cost estimates, token usage, and failure rates over a time period. Use for periodic governance review and cost tracking.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("since", `Assoc [
          ("type", `String "string");
          ("description", `String "Start of period as Unix timestamp string (optional, defaults to all time)");
        ]);
        ("until", `Assoc [
          ("type", `String "string");
          ("description", `String "End of period as Unix timestamp string (optional, defaults to now)");
        ]);
      ]);
    ];
  };
  {
    name = "masc_governance_set";
    description = "Configure governance policies for the room. Enables audit logging, anomaly detection, and agent isolation. Enterprise security for production use.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("level", `Assoc [
          ("type", `String "string");
          ("enum", `List [
            `String "development";
            `String "production";
            `String "enterprise";
            `String "paranoid"
          ]);
          ("description", `String "Security level: development (permissive), production (basic), enterprise (audit+encryption), paranoid (max isolation)");
          ("default", `String "production");
        ]);
        ("audit_enabled", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Enable audit logging (default: true for production+)");
          ("default", `Bool true);
        ]);
        ("anomaly_detection", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Enable anomaly detection (auth spikes, low success rate)");
          ("default", `Bool false);
        ]);
      ]);
    ];
  };
  {
    name = "masc_walph_loop";
    description = "Walph pattern: Keep claiming and completing tasks until stop condition. Iterates claim_next → work → done cycle. Control via @walph in broadcast: START <preset>, STOP, PAUSE, RESUME, STATUS. Presets: coverage → test coverage FeedbackLoop, refactor → lint FeedbackLoop, docs → doc coverage FeedbackLoop, review → PR review pipeline, figma → SSIM visual fidelity loop, drain → simple claim loop.";
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
    description = "Control a running @walph loop. Commands: STOP (end loop after current iteration), PAUSE (suspend loop), RESUME (continue paused loop), STATUS (get current state). Can also be triggered via broadcast: '@walph STOP', '@walph PAUSE', etc.";
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
    description = "Control Walph loop using natural language. Heuristic-based intent classification (Korean/English). Examples: '커버리지 올려줘' → START coverage, '그만' → STOP, '잠깐 멈춰' → PAUSE, '다시 시작' → RESUME, '지금 뭐해?' → STATUS. Uses direct LLM calls for ambiguous message classification.";
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
    description = "Wear a hat (role) to specialize agent behavior. Hats: builder (🔨 code), reviewer (🔍 review), researcher (🔬 explore), tester (🧪 tests), architect (📐 design), debugger (🐛 fix), documenter (📝 docs). Broadcast format: @agent:hat (e.g., @claude:builder).";
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
    description = "Start a new conversation thread on a topic. Returns thread_id for subsequent replies. Conversations persist to file and Neo4j for queryability. Loop prevention: max 50 turns by default.";
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
        ("mentions", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Agents @mentioned in the opening message");
        ]);
      ]);
      ("required", `List [`String "topic"; `String "initiator"]);
    ];
  };
  {
    name = "masc_convo_reply";
    description = "Add a reply to an existing conversation thread. Includes loop prevention: blocks identical consecutive messages (3x) and cooldown violations (2s between same speaker). Returns updated thread.";
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
    description = "Conclude a conversation with a summary/decision. Marks thread as Concluded and adds final turn. No more replies allowed after this.";
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
    description = "Get a conversation thread by ID. Returns full thread with all turns, participants, and status.";
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
    description = "List all active conversation threads in the current room.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_gardener_health";
    description = "Get comprehensive ecosystem health metrics. Returns agent population stats (total, active, idle), activity metrics (posts, comments, unanswered questions), homeostatic score, and intervention recommendations. Use this to understand if the ecosystem needs spawning or retirement.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_gardener_config";
    description = "Get current Gardener configuration from environment variables. Shows population bounds (min/max/target), daily budgets, cooldowns, and circuit breaker status.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_gardener_propose_spawn";
    description = "Evaluate whether a new agent should be spawned for a given topic. Uses LLM decision (if enabled) or rule-based logic. Returns approval/deferral/rejection with reasons. Does NOT actually create the agent — use masc_gardener_execute_spawn for that.";
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
  {
    name = "masc_keeper_tool_catalog";
    description = "List visible server-side masc_* tools alongside keeper-internal wrapper coverage.";
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
