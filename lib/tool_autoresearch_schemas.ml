(** Tool_autoresearch_schemas — autoresearch + swarm-facing synthesis schema definitions.

    Extracted from tool_autoresearch.ml to keep schema data separate from logic.

    @since 2.80.0 *)

let schemas : Types.tool_schema list = [
  {
    name = "masc_autoresearch_start";
    description = "Start a solo experiment loop: iteratively modify a target file to optimize \
a metric. Each cycle: read file -> LLM generates change -> measure -> keep if improved, \
discard if not. Runs autonomously until max_cycles or stopped. Returns loop_id. \
For team-coordinated research with multiple workers, use masc_autoresearch_swarm_start. \
Requires: goal, metric_fn (shell command outputting a float), target_file. \
Set lower_is_better=true for metrics where lower values are better (e.g., loss, BPB).";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("goal", `Assoc [
          ("type", `String "string");
          ("description", `String "What to optimize (e.g. 'Reduce inference latency')");
        ]);
        ("metric_fn", `Assoc [
          ("type", `String "string");
          ("description", `String "Shell command that outputs a single float on its last line \
(e.g. 'python eval.py --metric accuracy'). Higher is better by default; set lower_is_better=true to invert.");
        ]);
        ("workdir", `Assoc [
          ("type", `String "string");
          ("description", `String "Working directory for git operations and metric_fn \
(default: MASC base path)");
        ]);
        ("max_cycles", `Assoc [
          ("type", `String "integer");
          ("description", `String "Maximum number of experiment cycles (default: 100)");
        ]);
        ("cycle_timeout_s", `Assoc [
          ("type", `String "number");
          ("description", `String "Timeout per cycle in seconds (default: 300 = 5min)");
        ]);
        ("baseline", `Assoc [
          ("type", `String "number");
          ("description", `String "Initial baseline score. If omitted, measured by running metric_fn once.");
        ]);
        ("model_model", `Assoc [
          ("type", `String "string");
          ("description", `String "Model label for code change generation (uses cascade default)");
        ]);
        ("lower_is_better", `Assoc [
          ("type", `String "boolean");
          ("description", `String "When true, lower metric values are better (e.g., loss, BPB). Default: false (higher is better).");
        ]);
        ("target_file", `Assoc [
          ("type", `String "string");
          ("description", `String "File that the MODEL will read and modify (relative to workdir). \
The MODEL receives the full file, generates a modified version, and writes it back.");
        ]);
      ]);
      ("required", `List [`String "goal"; `String "metric_fn"; `String "target_file"]);
    ];
  };

  {
    name = "masc_autoresearch_swarm_start";
    description = "Start an experiment loop with team coordination. Same experiment logic \
as masc_autoresearch_start but also creates an execution session, seeds worker roles, and \
links loop status to the team. Use when multiple agents should collaborate on the \
research. Returns loop_id. Other agents can monitor via session \
runtime tools. Note: team session engine has been removed; this tool returns an error.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("goal", `Assoc [
          ("type", `String "string");
          ("description", `String "What to optimize.");
        ]);
        ("metric_fn", `Assoc [
          ("type", `String "string");
          ("description", `String "Shell command that outputs a single float on its last line. Higher is better.");
        ]);
        ("target_file", `Assoc [
          ("type", `String "string");
          ("description", `String "Relative file path that the loop edits.");
        ]);
        ("workdir", `Assoc [
          ("type", `String "string");
          ("description", `String "Working directory for git operations and metric_fn (default: MASC base path)");
        ]);
        ("program_note", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional human-owned instruction note, analogous to program.md.");
        ]);
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional task ID to link this autoresearch loop back into deterministic task gates.");
        ]);
        ("max_cycles", `Assoc [
          ("type", `String "integer");
          ("description", `String "Maximum number of experiment cycles (default: 100)");
        ]);
        ("cycle_timeout_s", `Assoc [
          ("type", `String "number");
          ("description", `String "Timeout per cycle in seconds (default: 300)");
        ]);
        ("baseline", `Assoc [
          ("type", `String "number");
          ("description", `String "Initial baseline score. If omitted, measured by running metric_fn once.");
        ]);
        ("model_model", `Assoc [
          ("type", `String "string");
          ("description", `String "Model label for code change generation (uses cascade default)");
        ]);
        ("lower_is_better", `Assoc [
          ("type", `String "boolean");
          ("description", `String "When true, lower metric values are better (e.g., loss, BPB). Default: false.");
        ]);
      ]);
      ("required", `List [`String "goal"; `String "metric_fn"; `String "target_file"]);
    ];
  };

  {
    name = "masc_repo_synthesis_swarm_start";
    description = "Start a repository-scoped code synthesis task with team coordination. \
Use for questions about a codebase (e.g. 'Generate a DB schema from these requirements'). \
Creates an execution session and seeds workers to answer the question collaboratively. \
Unlike autoresearch (metric-driven loops), this is question-driven with artifact output. \
Returns synthesis_id. Note: team session engine has been removed; this tool returns an error.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("goal", `Assoc [
          ("type", `String "string");
          ("description", `String "Human goal for the synthesis run.");
        ]);
        ("question", `Assoc [
          ("type", `String "string");
          ("description", `String "Repo question or synthesis prompt to answer.");
        ]);
        ("repo_root", `Assoc [
          ("type", `String "string");
          ("description", `String "Repo root path for benchmark metadata and question-set lookup.");
        ]);
        ("question_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional dataset question id from benchmark/repo_synthesis_question_set.json.");
        ]);
        ("artifact_scope", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Optional repo-relative paths that narrow synthesis scope.");
        ]);
        ("program_note", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional human-owned benchmark note.");
        ]);
        ("model", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional model label recorded into benchmark metadata.");
        ]);
        ("time_budget_sec", `Assoc [
          ("type", `String "integer");
          ("description", `String "Time budget recorded for fairness comparisons (default: 900).");
        ]);
        ("max_workers", `Assoc [
          ("type", `String "integer");
          ("description", `String "Maximum planned worker count to seed into the attached execution session (default: 6).");
        ]);
        ("baseline_label", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional baseline label for paired benchmark comparisons.");
        ]);
      ]);
      ("required", `List [`String "goal"; `String "question"; `String "repo_root"]);
    ];
  };

  {
    name = "masc_autoresearch_status";
    description = "Get the current status of an autoresearch loop. \
Returns: loop_id, cycle count, baseline, best score, keep/discard counts, recent history.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("loop_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Loop ID (optional, uses latest if omitted)");
        ]);
      ]);
    ];
  };

  {
    name = "masc_autoresearch_stop";
    description = "Stop a running autoresearch loop. \
The loop will finish its current cycle and save final state.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("loop_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Loop ID (optional, stops latest)");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Reason for stopping (for logging)");
        ]);
      ]);
    ];
  };

  {
    name = "masc_autoresearch_inject";
    description = "Inject a specific hypothesis into a running autoresearch loop. \
The next cycle will test this hypothesis instead of generating one via MODEL. \
Useful for directing the research based on human insight.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("loop_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Loop ID (optional, uses latest)");
        ]);
        ("hypothesis", `Assoc [
          ("type", `String "string");
          ("description", `String "The hypothesis to test in the next cycle");
        ]);
      ]);
      ("required", `List [`String "hypothesis"]);
    ];
  };

  {
    name = "masc_autoresearch_cycle";
    description = "Run one experiment cycle of an active loop. Reads target file, LLM generates \
a modification, measures before/after, keeps change if metric improved. Returns cycle_number, \
before_score, after_score, kept (bool). Requires an active loop from masc_autoresearch_start. \
Normally the loop runs autonomously; use this for manual single-step control.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("loop_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Loop ID (optional, uses latest)");
        ]);
        ("hypothesis", `Assoc [
          ("type", `String "string");
          ("description", `String "Hypothesis to test (optional, auto-generates via MODEL if omitted)");
        ]);
      ]);
    ];
  };

]
