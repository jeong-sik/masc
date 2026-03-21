(** Tool_mitosis — Mitosis MCP tool handlers and dispatch.

    8 tools: mitosis_status, mitosis_all, mitosis_pool, mitosis_divide,
             mitosis_check, mitosis_record, mitosis_prepare, mitosis_handoff
    Plus: metrics_compare, metrics_record

    Context types, helpers, and spawn cascade are in:
    - Mitosis_helpers: types, verifier, episode/saga management
    - Mitosis_spawn: agent spawn cascade with circuit breaker

    Include chain: Mitosis_helpers -> Mitosis_spawn -> Tool_mitosis

    Split modules:
    - Tool_mitosis_utils: string matching, DNA validation, overlap analysis
    - Tool_mitosis_handoff: run_sync_handoff, handle_mitosis_handoff, metrics handlers *)

include Mitosis_spawn
open Tool_args

(** Re-export for external callers and .mli contract *)
let validate_dna = Tool_mitosis_utils.validate_dna
let handle_mitosis_handoff = Tool_mitosis_handoff.handle_mitosis_handoff
let run_sync_handoff = Tool_mitosis_handoff.run_sync_handoff
let continuity_regression_check = Tool_mitosis_utils.continuity_regression_check

let handle_mitosis_status _ctx _args : result =
  let cell = !(Mcp_server.current_cell) in
  let pool = !(Mcp_server.stem_pool) in
  let json = `Assoc [
    ("cell", Mitosis.cell_to_json cell);
    ("pool", Mitosis.pool_to_json pool);
    ("config", Mitosis.config_to_json Mitosis.default_config);
  ] in
  (true, Yojson.Safe.pretty_to_string json)

let handle_mitosis_all ctx _args : result =
  let statuses = Mitosis.get_all_statuses ~room_config:ctx.config in
  let json =
    `List (List.map (fun (node_id, status, ratio) ->
      `Assoc [
        ("node_id", `String node_id);
        ("status", `String status);
        ("estimated_ratio", `Float ratio);
      ]) statuses)
  in
  (true, Yojson.Safe.pretty_to_string json)

let handle_mitosis_pool _ctx _args : result =
  let pool = !(Mcp_server.stem_pool) in
  (true, Yojson.Safe.pretty_to_string (Mitosis.pool_to_json pool))

let handle_mitosis_divide ctx args : result =
  let summary = get_string args "summary" "" in
  let current_task = get_string args "current_task" "" in
  let target_agent = get_string args "target_agent" "claude" in
  match validate_target_agent_label target_agent with
  | Error msg ->
      let json =
        `Assoc
          [
            ("success", `Bool false);
            ("error", `String msg);
            ("target_agent", `String target_agent);
          ]
      in
      (false, Yojson.Safe.pretty_to_string json)
  | Ok normalized_target_agent ->
      let spawn_timeout =
        int_of_float
          (get_float args "spawn_timeout"
             (Float.of_int Mitosis.Defaults.spawn_timeout_seconds))
      in
      let full_context =
        if current_task = "" then summary
        else Printf.sprintf "Summary: %s\n\nCurrent Task: %s" summary current_task
      in
      let cell = !(Mcp_server.current_cell) in
      let config_mitosis = Mitosis.default_config in
      let selected_agent = ref normalized_target_agent in
      let spawn_attempts = ref [] in
      let spawn_fn ~prompt =
        let (result, actual_agent, attempts) =
          spawn_with_cascade
            ~ctx
            ~preferred_agent:target_agent
            ~total_timeout_seconds:spawn_timeout
            ~prompt
        in
        selected_agent := actual_agent;
        spawn_attempts := attempts;
        result
      in
      let (spawn_result, new_cell, new_pool, handoff_dna) =
        Mitosis.execute_mitosis ~config:config_mitosis ~pool:!(Mcp_server.stem_pool)
          ~parent:cell ~full_context ~spawn_fn
      in
      let effective_agent =
        if !selected_agent = "" then normalized_target_agent else !selected_agent
      in
      let attempts_json = spawn_attempts_to_json !spawn_attempts in
      if spawn_result.Spawn.success then begin
        Mcp_server.current_cell := new_cell;
        Mcp_server.stem_pool := new_pool;
        Mitosis.write_status_with_backend ~room_config:ctx.config ~cell:new_cell ~config:config_mitosis;

        let base_path = ctx.config.Room_utils.base_path in
        let session_id = get_session_id () in
        let ep_id = queue_episode
          ~base_path
          ~session_id
          ~agent_name:effective_agent
          ~generation:new_cell.Mitosis.generation
          ~event_type:"mitosis_divide"
          ~summary:(Printf.sprintf "Manual mitosis divide: gen %d → gen %d"
            cell.Mitosis.generation new_cell.Mitosis.generation)
          ~dna:handoff_dna
          () in

        let output_preview = Mitosis.safe_sub spawn_result.Spawn.output 0 500 in
        let json = `Assoc [
          ("success", `Bool true);
          ("previous_generation", `Int cell.Mitosis.generation);
          ("new_generation", `Int new_cell.Mitosis.generation);
          ("target_agent", `String target_agent);
          ("selected_agent", `String effective_agent);
          ("spawn_attempts", attempts_json);
          ("successor_output", `String output_preview);
          ("episode_queued", match ep_id with Some id -> `String id | None -> `Null);
        ] in
        (true, Yojson.Safe.pretty_to_string json)
      end else begin
        Log.Mitosis_log.error "mitosis_divide spawn failed, state unchanged";
        let json = `Assoc [
          ("success", `Bool false);
          ("error", `String "Spawn failed");
          ("target_agent", `String target_agent);
          ("selected_agent", `String effective_agent);
          ("spawn_attempts", attempts_json);
          ("spawn_output", `String spawn_result.Spawn.output);
          ("suggestion", `String "Check agent availability and try again, or use masc_mitosis_handoff for graceful fallback");
        ] in
        (false, Yojson.Safe.pretty_to_string json)
      end

let handle_mitosis_check _ctx args : result =
  let raw_ratio = get_float args "context_ratio" 0.0 in
  let context_ratio = validate_context_ratio raw_ratio in

  (* P0-2: Warn if context_ratio is default 0.0 *)
  if raw_ratio = 0.0 then
    Log.Mitosis_log.warn "context_ratio is 0.0 - did you forget to estimate it?";

  (* P0-1: Configurable thresholds *)
  let prepare_threshold = get_float args "prepare_threshold" 0.5 in
  let handoff_threshold = get_float args "handoff_threshold" 0.8 in

  let cell = !(Mcp_server.current_cell) in
  (* Override config with custom thresholds *)
  let config_mitosis = { Mitosis.default_config with
    prepare_threshold;
    handoff_threshold;
  } in

  let should_prepare = Mitosis.should_prepare ~config:config_mitosis ~cell ~context_ratio in
  let should_handoff = Mitosis.should_handoff ~config:config_mitosis ~cell ~context_ratio in
  let warning = if raw_ratio = 0.0 then
    [("warning", `String "context_ratio is 0.0 - did you forget to provide it?")]
  else [] in
  let json = `Assoc ([
    ("should_prepare", `Bool should_prepare);
    ("should_handoff", `Bool should_handoff);
    ("context_ratio", `Float context_ratio);
    ("threshold_prepare", `Float config_mitosis.Mitosis.prepare_threshold);
    ("threshold_handoff", `Float config_mitosis.Mitosis.handoff_threshold);
    ("phase", `String (Mitosis.phase_to_string cell.Mitosis.phase));
  ] @ warning) in
  (true, Yojson.Safe.pretty_to_string json)

let handle_mitosis_record ctx args : result =
  let task_done = get_bool args "task_done" false in
  let tool_called = get_bool args "tool_called" false in
  let cell = !(Mcp_server.current_cell) in
  let updated = Mitosis.record_activity ~cell ~task_done ~tool_called in
  Mcp_server.current_cell := updated;
  Mitosis.write_status_with_backend ~room_config:ctx.config ~cell:updated ~config:Mitosis.default_config;
  let json = `Assoc [
    ("task_count", `Int updated.Mitosis.task_count);
    ("tool_call_count", `Int updated.Mitosis.tool_call_count);
    ("last_activity", `Float updated.Mitosis.last_activity);
  ] in
  (true, Yojson.Safe.pretty_to_string json)

let handle_mitosis_prepare ctx args : result =
  let full_context = get_string args "full_context" "" in

  (* P0-3: Configurable DNA compression ratio *)
  let dna_compression_ratio = get_float args "dna_compression_ratio" 0.1 in
  let config_mitosis = { Mitosis.default_config with
    dna_compression_ratio;
  } in

  let cell = !(Mcp_server.current_cell) in
  let prepared = Mitosis.prepare_for_division ~config:config_mitosis ~cell ~full_context in
  Mcp_server.current_cell := prepared;
  Mitosis.write_status_with_backend ~room_config:ctx.config ~cell:prepared ~config:config_mitosis;
  (* P2-3: Record prepare metric *)
  Mitosis_metrics.inc_prepare ();
  let json = `Assoc [
    ("status", `String "prepared");
    ("phase", `String (Mitosis.phase_to_string prepared.Mitosis.phase));
    ("dna_length", `Int (String.length (Option.value ~default:"" prepared.Mitosis.prepared_dna)));
    ("compression_ratio", `Float config_mitosis.Mitosis.dna_compression_ratio);
  ] in
  (true, Yojson.Safe.pretty_to_string json)

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

(** {1 Dispatcher} *)

let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_mitosis_status" -> Some (handle_mitosis_status ctx args)
  | "masc_mitosis_all" -> Some (handle_mitosis_all ctx args)
  | "masc_mitosis_pool" -> Some (handle_mitosis_pool ctx args)
  | "masc_mitosis_divide" -> Some (handle_mitosis_divide ctx args)
  | "masc_mitosis_check" -> Some (handle_mitosis_check ctx args)
  | "masc_mitosis_record" -> Some (handle_mitosis_record ctx args)
  | "masc_mitosis_prepare" -> Some (handle_mitosis_prepare ctx args)
  | "masc_mitosis_handoff" -> Some (Tool_mitosis_handoff.handle_mitosis_handoff ctx args)
  | "masc_metrics_compare" -> Some (Tool_mitosis_handoff.handle_metrics_compare ctx args)
  | "masc_metrics_record" -> Some (Tool_mitosis_handoff.handle_metrics_record ctx args)
  | _ -> None
