(** Tool_mdal schemas and state helpers. *)

(** Tool_mdal — MCP tool schemas for the Metric-Driven Agent Loop.

    Provides 4 MCP tools:
    - masc_mdal_start    — Start a measured improvement loop
    - masc_mdal_status   — Get current loop state and iteration history
    - masc_mdal_iterate  — Execute one improvement iteration
    - masc_mdal_stop     — Stop a running loop

    @since 2.70.0 *)

(* ================================================================ *)
(* Tool Schemas                                                     *)
(* ================================================================ *)

let schemas : Types.tool_schema list = [
  {
    name = "masc_mdal_start";
    description = "Start a strict metric-driven improvement loop for a deterministic numeric goal with auditable tool use and re-measurement. \
Use when you have a measurable target (e.g., coverage >= 0.95, lint errors <= 0) and want automated iterations. \
Pair with masc_mdal_iterate to advance iterations and masc_mdal_stop to end the loop.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("profile", `Assoc [
          ("type", `String "string");
          ("description", `String "Built-in profile name (ssim, coverage, lint, review, docs) \
or 'custom' for a custom metric loop");
        ]);
        ("metric_fn", `Assoc [
          ("type", `String "string");
          ("description", `String "Shell command that outputs a single float metric. \
Required for custom profiles and for all built-in profiles in this build.");
        ]);
        ("goal", `Assoc [
          ("type", `String "string");
          ("description", `String "Goal expression, e.g. 'metric >= 0.95' or 'errors <= 0'. \
Operators: >=, <=, >, <, ==, !=. Required for custom profiles.");
        ]);
        ("target", `Assoc [
          ("type", `String "string");
          ("description", `String "Human-readable target description");
        ]);
        ("reference", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional reference file or directory recorded in loop metadata and included in worker context. \
MDAL itself does not read or score this path.");
        ]);
        ("agent", `Assoc [
          ("type", `String "string");
          ("description", `String "Worker alias or provider:model string for the strict worker runtime");
        ]);
        ("worker_model", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional explicit provider:model worker runtime. Overrides agent alias resolution.");
        ]);
        ("max_iterations", `Assoc [
          ("type", `String "integer");
          ("description", `String "Maximum number of iterations (default: profile-dependent)");
        ]);
        ("max_time_seconds", `Assoc [
          ("type", `String "number");
          ("description", `String "Maximum wall-clock time in seconds (default: profile-dependent)");
        ]);
        ("heuristics", `Assoc [
          ("type", `String "string");
          ("description", `String "Worker guidance text only. Loop stop/continue decisions are based on measured metric results, not this hint.");
        ]);
        ("tools_allow", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Auditable MDAL tool allowlist. Unknown or unsupported tools are ignored before strict runtime validation.");
        ]);
        ("tools_deny", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Auditable MDAL tool denylist applied after tools_allow/default catalog selection.");
        ]);
      ]);
      ("required", `List [`String "profile"]);
    ];
  };

  {
    name = "masc_mdal_status";
    description = "Get the current MDAL loop state, metric history, and persistence metadata. \
Use when checking loop progress or diagnosing an interrupted loop after restart. \
Pair with masc_mdal_iterate to continue or masc_mdal_stop to end.";
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
    name = "masc_mdal_iterate";
    description = "Advance one strict MDAL iteration: the worker uses auditable tools, then MDAL re-measures the metric. \
Use when the loop is running/interrupted and you want to make progress toward the goal. \
After masc_mdal_start; check masc_mdal_status to see if the goal was met.";
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
    name = "masc_mdal_stop";
    description = "Stop a running MDAL loop, persisting the final state and stop reason. \
Use when the goal is met, the metric plateaus, or the loop is no longer worth continuing. \
After masc_mdal_iterate; pair with masc_mdal_status to review final metrics.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("loop_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Loop ID (optional, stops latest)");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Reason for stopping");
        ]);
      ]);
    ];
  };
  {
    name = "masc_mdal_swarm_start";
    description = "Start N parallel MDAL workers, each targeting a different metric, with aggregate progress tracking. \
Use when multiple metrics need simultaneous improvement (e.g., coverage + lint + docs). \
Pair with masc_mdal_status per worker to check individual progress.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("swarm_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Unique swarm identifier");
        ]);
        ("title", `Assoc [
          ("type", `String "string");
          ("description", `String "Human-readable swarm title");
        ]);
        ("workers", `Assoc [
          ("type", `String "array");
          ("description", `String "Array of worker specs: {worker_id, label, metric_fn, goal_expr, agent, max_iterations}");
          ("items", `Assoc [
            ("type", `String "object");
            ("properties", `Assoc [
              ("worker_id", `Assoc [("type", `String "string")]);
              ("label", `Assoc [("type", `String "string")]);
              ("metric_fn", `Assoc [("type", `String "string"); ("description", `String "Shell command outputting float")]);
              ("goal_expr", `Assoc [("type", `String "string"); ("description", `String "e.g. 'metric >= 0.95'")]);
              ("agent", `Assoc [("type", `String "string")]);
              ("max_iterations", `Assoc [("type", `String "integer")]);
            ]);
          ]);
        ]);
        ("aggregate_strategy", `Assoc [
          ("type", `String "string");
          ("description", `String "all | any | average (default: average)");
        ]);
        ("aggregate_goal_expr", `Assoc [
          ("type", `String "string");
          ("description", `String "Aggregate goal expression, e.g. 'metric >= 0.95'");
        ]);
        ("max_wall_time_sec", `Assoc [
          ("type", `String "number");
          ("description", `String "Optional wall-time limit in seconds");
        ]);
      ]);
      ("required", `List [`String "swarm_id"; `String "title"; `String "workers"; `String "aggregate_goal_expr"]);
    ];
  };
]

(* ================================================================ *)
(* Context & State                                                  *)
(* ================================================================ *)

type context = {
  agent_name : string;
  config : Room.config option;
  sw : Eio.Switch.t option;
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option;
  worker_runner : Mdal_worker.runner option;
  clock : float Eio.Time.clock_ty Eio.Resource.t option;
}

(** Write-through runtime cache of active/persisted MDAL loops. *)
let active_loops : (string, Mdal.loop_state) Hashtbl.t =
  Hashtbl.create 4

let latest_loop_id : string option ref = ref None

(** In-memory store for async swarm results. *)
let active_swarms : (string, Mdal_swarm.swarm_result option ref) Hashtbl.t =
  Hashtbl.create 4

(* ================================================================ *)
(* Helpers                                                          *)
(* ================================================================ *)

(** Wrap a Yojson.Safe.t result into (success, json_string). *)
let wrap_result json =
  let s = Yojson.Safe.to_string json in
  let is_error = match json with
    | `Assoc fields -> List.mem_assoc "error" fields
    | _ -> false
  in
  (not is_error, s)
