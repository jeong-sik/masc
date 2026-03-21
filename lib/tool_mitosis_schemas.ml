(** Tool_mitosis_schemas -- Types.tool_schema definitions for mitosis
    and metrics tools.

    Extracted from Tool_mitosis to reduce file size.

    @since 2.122.0 *)

let schemas : Types.tool_schema list = [
  {
    name = "masc_mitosis_status";
    description = "Get current agent cell status and stem pool state. Shows generation, task count, tool calls, and available reserve cells. Use to monitor lifecycle state.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  (* masc_mitosis_all *)
  {
    name = "masc_mitosis_all";
    description = "Get mitosis status of ALL agents in the cluster (cross-machine). \
Use when checking if any agent is under context pressure and needs handoff help. \
Pair with masc_mitosis_divide to assist an agent approaching threshold.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  (* masc_mitosis_pool *)
  {
    name = "masc_mitosis_pool";
    description = "View the stem cell pool: reserve agents ready for instant handoff. \
Use when checking if warm cells are available before triggering mitosis. \
Pair with masc_mitosis_divide for manual division, or masc_memento_mori for auto-lifecycle.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  (* masc_mitosis_divide *)
  {
    name = "masc_mitosis_divide";
    description = "Manually trigger cell division (mitosis): parent cell dies, child inherits compressed context DNA. \
Use when you decide to hand off proactively rather than waiting for auto-threshold. \
Pair with masc_mitosis_prepare to extract DNA first, or use masc_memento_mori for auto mode.";
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

  (* masc_mitosis_check *)
  {
    name = "masc_mitosis_check";
    description = "2-phase mitosis check: Phase 1 (50%) should_prepare, Phase 2 (80%) should_handoff. \
Use when periodically checking context health. Returns current phase and thresholds. \
After should_prepare: call masc_mitosis_prepare. After should_handoff: call masc_mitosis_divide.";
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

  (* masc_mitosis_record *)
  {
    name = "masc_mitosis_record";
    description = "Record an activity event (task completion or tool call) to update mitosis trigger counters. \
Use when completing a task or making a significant tool call to keep lifecycle tracking accurate. \
Pair with masc_mitosis_check to see if the counters have triggered a threshold.";
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

  (* masc_mitosis_prepare *)
  {
    name = "masc_mitosis_prepare";
    description = "Phase 1: Extract DNA from current context and mark cell as ready for division. Does NOT hand off yet. \
Use when masc_mitosis_check returns should_prepare=true (context ~50%). \
Actual handoff happens at 80% via masc_mitosis_divide or masc_memento_mori.";
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

  (* masc_mitosis_handoff *)
  {
    name = "masc_mitosis_handoff";
    description = "Automated 2-phase context lifecycle manager. Call periodically with your estimated context_ratio. \
<50%: continue, 50-80%: DNA extracted (prepared), >80%: spawns successor (handoff). \
Use when you want automatic lifecycle management instead of manual masc_mitosis_check + prepare + divide. \
Pair with masc_memento_mori for the all-in-one convenience wrapper.";
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
          ("description", `String "If true (default), run MODEL verifier on handoff result and store it in saga payload.");
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

  (* masc_metrics_compare *)
  {
    name = "masc_metrics_compare";
    description = "Compare performance metrics between two agent generations (completion rate, errors, speed, tokens). \
Use when evaluating whether successor agents are improving over predecessors. \
Returns verdict: improved/degraded/neutral. Pair with masc_metrics_record to collect data first.";
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

  (* masc_metrics_record *)
  {
    name = "masc_metrics_record";
    description = "Record a task completion event (duration, errors, tokens) for generational performance tracking. \
Use when finishing a task to feed data into the metrics system. \
Pair with masc_metrics_compare to evaluate generational improvement.";
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
]
