(** Split chunk from tools.ml; private schema registry. *)

open Types

let schemas : tool_schema list = [
  {
    name = "masc_governance_report";
    description = "Generate a governance summary report from the audit trail, aggregating per-agent action counts, cost, tokens, and failure rates. \
Use when reviewing room costs, auditing agent behavior, or preparing periodic governance summaries. \
Pair with masc_governance_set to configure audit policies, or masc_governance_status for a compact overview.";
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
    description = "Configure governance policies for the room including audit logging, anomaly detection, and agent isolation levels. \
Use when setting up a new room for production or tightening security after an incident. \
Pair with masc_governance_report to verify policy effects and masc_governance_status for current state.";
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
    description = "Start an automated claim-work-done loop that keeps claiming and completing tasks until a stop condition is met. \
Use when you want to drain a task backlog or run a preset feedback loop (coverage, refactor, docs, figma, drain). \
Control with masc_walph_control (STOP/PAUSE/RESUME/STATUS) or via broadcast '@walph STOP'.";
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
    description = "Send a control command (STOP, PAUSE, RESUME, STATUS) to a running walph loop. \
Use when you need to halt, pause, or inspect a walph loop mid-execution. \
After masc_walph_loop starts a loop; also triggerable via broadcast '@walph STOP'.";
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
    description = "Control a walph loop using natural language in Korean or English (e.g., 'stop the loop', 'coverage up'). \
Use when sending free-form instructions instead of explicit STOP/PAUSE/RESUME commands. \
Translates intent into masc_walph_control commands; falls back to LLM for ambiguous messages.";
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
    description = "Return detailed runtime status for your walph loop: iterations, claimed/done counts, errors, backoff, and stop reason. \
Use when checking loop progress or diagnosing why a loop stopped. \
After masc_walph_loop starts; pair with masc_walph_control STATUS for a lighter check.";
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
    description = "Assign a role hat (builder, reviewer, researcher, tester, architect, debugger, documenter) to specialize your behavior. \
Use when switching focus, e.g., from coding to reviewing. \
Pair with masc_hat_status to see all agents' current hats.";
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
    description = "Show which role hat each agent is currently wearing. \
Use when coordinating team roles or checking if a hat is already taken. \
Pair with masc_hat_wear to assign or change hats.";
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
    description = "Run a multi-agent round-robin loop with formal termination, token budget, cost, and time constraints. \
Use when orchestrating autonomous agent collaboration that needs guaranteed termination and budget control. \
Pair with masc_team_session_start for supervised sessions or masc_mdal_start for metric-driven loops.";
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
    description = "Start a persistent conversation thread on a topic and return a thread_id for subsequent replies. \
Use when agents need structured multi-turn discussion on a decision or design question. \
Follow up with masc_convo_reply to add turns; end with masc_convo_conclude.";
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
    description = "Add a reply to an existing conversation thread with built-in loop prevention (blocks repeated messages and cooldown violations). \
Use when contributing to an ongoing multi-agent discussion. \
After masc_convo_start creates a thread; before masc_convo_conclude closes it.";
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
    description = "Close a conversation thread with a final summary or decision, marking it as Concluded (no further replies allowed). \
Use when the discussion has reached consensus or a decision point. \
After masc_convo_reply turns are complete; pair with masc_convo_get to review the full thread.";
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
    description = "Retrieve a conversation thread by ID with all turns, participants, and status. \
Use when reviewing discussion history or checking thread state before replying. \
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
Use when looking for ongoing discussions to join or finding a thread_id. \
Pair with masc_convo_get to read a specific thread.";
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
    description = "Return ecosystem health metrics: agent population, activity counts, homeostatic score, and intervention recommendations. \
Use when checking whether the agent ecosystem needs spawning or retirement. \
Pair with masc_gardener_propose_spawn or masc_gardener_retire_agent based on the health assessment.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_gardener_config";
    description = "Return current Gardener configuration: population bounds, daily budgets, cooldowns, and circuit breaker state. \
Use when diagnosing why a spawn or retirement was rejected, or verifying environment settings. \
Pair with masc_gardener_health for runtime metrics and masc_gardener_reset_circuit to clear a tripped breaker.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_gardener_status";
    description = "Return the gardener background loop runtime status: liveness, last tick, last action, errors, and circuit state. \
Use when checking whether the gardener loop is alive and what it last decided. \
Pair with masc_gardener_config for settings and masc_gardener_health for ecosystem metrics.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_gardener_propose_spawn";
    description = "Evaluate whether a new agent should be spawned for a given topic, returning approval/deferral/rejection with reasons. \
Use when a gap in ecosystem coverage is detected (e.g., no security agent). \
Before masc_gardener_execute_spawn which performs the actual creation.";
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
    description = "Evaluate whether an idle agent should be retired, checking population minimums and recent contributions. \
Use when an agent appears inactive and the ecosystem may be overpopulated. \
Before masc_gardener_execute_retire which initiates the grace period.";
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
