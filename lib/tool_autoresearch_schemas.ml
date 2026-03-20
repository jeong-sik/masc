(** Tool_autoresearch_schemas — 6 autoresearch tool schema definitions.

    Extracted from tool_autoresearch.ml to keep schema data separate from logic.

    @since 2.80.0 *)

let schemas : Types.tool_schema list = [
  {
    name = "masc_autoresearch_start";
    description = "Start an autonomous experiment loop (inspired by Karpathy's autoresearch). \
Each cycle: measure baseline -> apply change -> measure again -> keep if improved, discard if not. \
Changes are tracked via git commits. Results are logged to JSONL. \
Requires: goal (what to optimize), metric_fn (shell command that outputs a float on the last line).";
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
(e.g. 'python eval.py --metric accuracy'). Higher is better.");
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
          ("description", `String "MODEL model for code change generation (default: 'glm')");
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
    description = "Start an autoresearch loop and immediately wrap it in the canonical swarm-facing surfaces. \
Creates the raw loop, attempts a managed CPv2 research operation, starts a linked team session, seeds planned worker roles, \
and persists cross-links so team-session status/stop can surface the linked loop.";
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
          ("description", `String "MODEL model for code change generation (default: 'glm')");
        ]);
      ]);
      ("required", `List [`String "goal"; `String "metric_fn"; `String "target_file"]);
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
    description = "Run one experiment cycle of a Karpathy-style autoresearch loop. \
Steps: read target file -> MODEL generates modified code -> measure before -> write file -> \
git commit -> measure after -> keep if improved (update baseline), git reset --hard HEAD~1 if not. \
Call this repeatedly to drive the autonomous loop.";
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
