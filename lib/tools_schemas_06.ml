(** Split chunk from tools.ml; private schema registry. *)

open Types

let schemas : tool_schema list = [
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

  (* ============================================ *)
  (* Agent Being Protocol - Episode Storage      *)
  (* ============================================ *)

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

  (* ============================================ *)
  (* A2A MCP Tools (A2A Protocol via MCP)        *)
  (* ============================================ *)

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
]
