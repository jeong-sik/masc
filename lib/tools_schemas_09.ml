(** Split chunk from tools.ml; private schema registry. *)

open Types

let schemas : tool_schema list = [
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

  (* Walph Pattern: Iterative Task Loop
     Presets with direct LLM execution:
     - preset="coverage" → FeedbackLoop for test coverage (direct LLM)
     - preset="refactor" → FeedbackLoop for lint errors (direct LLM)
     - preset="docs" → FeedbackLoop for documentation (direct LLM)
     - preset="figma" → Vision-first visual fidelity loop (direct LLM)
     - preset="drain" → simple task claiming without LLM execution *)
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

  (* Walph Control: STOP, PAUSE, RESUME, STATUS *)
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

  (* Walph Natural Language: Control walph via natural language *)
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

  (* Walph status: detailed per-agent runtime counters *)
  {
    name = "masc_walph_status";
    description = "Get detailed status for the current agent's Walph loop, including iterations, claimed/done counts, error counters, backoff settings, and last stop reason.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent requesting the status");
        ]);
      ]);
      ("required", `List [`String "agent_name"]);
    ];
  };

  (* Hat System: Role-based hats for agents *)
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
    name = "masc_hat_status";
    description = "Show current hat status for all agents. Displays which role each agent is currently using.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent requesting status");
        ]);
      ]);
      ("required", `List [`String "agent_name"]);
    ];
  };

  (* Bounded Autonomy: Constrained multi-agent execution with formal guarantees *)
  {
    name = "masc_bounded_run";
    description = "Run multi-agent loop with formal constraints. Guarantees: termination (hard_max_iterations), safety (post-check prevents silent violations), predictive limits (token_buffer). Use for autonomous agent collaboration with budget control.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agents", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "List of agents to use in round-robin: ['gemini', 'codex', 'claude']");
        ]);
        ("prompt", `Assoc [
          ("type", `String "string");
          ("description", `String "Initial prompt for agents");
        ]);
        ("constraints", `Assoc [
          ("type", `String "object");
          ("description", `String "Execution limits");
          ("properties", `Assoc [
            ("max_turns", `Assoc [
              ("type", `String "integer");
              ("description", `String "Maximum agent turns (default: 10)");
            ]);
            ("max_tokens", `Assoc [
              ("type", `String "integer");
              ("description", `String "Maximum total tokens (default: 100000)");
            ]);
            ("max_cost_usd", `Assoc [
              ("type", `String "number");
              ("description", `String "Maximum cost in USD (default: 1.0)");
            ]);
            ("max_time_seconds", `Assoc [
              ("type", `String "number");
              ("description", `String "Maximum wall-clock time (default: 300)");
            ]);
            ("token_buffer", `Assoc [
              ("type", `String "integer");
              ("description", `String "Buffer for predictive token limit (default: 5000)");
            ]);
            ("hard_max_iterations", `Assoc [
              ("type", `String "integer");
              ("description", `String "Absolute failsafe iteration limit (default: 100)");
            ]);
          ]);
        ]);
        ("goal", `Assoc [
          ("type", `String "object");
          ("description", `String "Termination condition");
          ("properties", `Assoc [
            ("path", `Assoc [
              ("type", `String "string");
              ("description", `String "JSONPath to check in agent output, e.g., '$.status' or '$.result.done'");
            ]);
            ("condition", `Assoc [
              ("type", `String "object");
              ("description", `String "Comparison: {eq: value}, {gte: 0.95}, {lt: 5}, {in: ['done', 'success']}");
            ]);
          ]);
          ("required", `List [`String "path"; `String "condition"]);
        ]);
      ]);
      ("required", `List [`String "agents"; `String "prompt"; `String "goal"]);
    ];
  };

  (* ============================================ *)
  (* Conversation Tools - Persistent Agent Dialogue *)
  (* ============================================ *)

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

  (* ============================================ *)
  (* Gardener Tools - Self-Organizing Ecosystem *)
  (* ============================================ *)

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
    name = "masc_gardener_status";
    description = "Get truth-only gardener loop runtime status. Returns liveness, last tick timestamps, last decision source, last action, last error, cooldown/circuit state, and the last observed health summary.";
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
    name = "masc_gardener_retire_agent";
    description = "Evaluate whether an agent should be retired. Checks population minimums, idle thresholds, and recent contributions. Returns approval/deferral/rejection with reasons. Does NOT actually retire — use masc_gardener_execute_retire for that.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Name of the agent to consider for retirement");
        ]);
      ]);
      ("required", `List [`String "agent_name"]);
    ];
  };
]
