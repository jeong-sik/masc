(** Tool_mitosis -- Mitosis MCP tool handlers and dispatch.

    8 tools: mitosis_status, mitosis_all, mitosis_pool, mitosis_divide,
             mitosis_check, mitosis_record, mitosis_prepare, mitosis_handoff
    Plus: metrics_compare, metrics_record

    Context types, helpers, and spawn cascade are in:
    - Mitosis_helpers: types, verifier, episode/saga management
    - Mitosis_spawn: agent spawn cascade with circuit breaker
    - Mitosis_continuity: DNA validation and continuity regression
    - Mitosis_handoff: run_sync_handoff and handle_mitosis_handoff

    Include chain: Mitosis_helpers -> Mitosis_spawn -> Mitosis_handoff -> Tool_mitosis

    @since 0.3.0 *)

include Mitosis_handoff
open Tool_args

(** Re-export from {!Mitosis_continuity} for .mli compatibility. *)
let validate_dna = Mitosis_continuity.validate_dna

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
          ~summary:(Printf.sprintf "Manual mitosis divide: gen %d -> gen %d"
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

(** {1 Metrics Handlers} *)

(** P1-4: Compare generational metrics *)
let handle_metrics_compare _ctx args : result =
  let gen_a = int_of_float (get_float args "gen_a" 0.0) in
  let gen_b = int_of_float (get_float args "gen_b" 1.0) in
  match Generational_metrics.compare_generations gen_a gen_b with
  | None ->
      let json = `Assoc [
        ("error", `String "Not enough data for comparison");
        ("gen_a", `Int gen_a);
        ("gen_b", `Int gen_b);
        ("hint", `String "Need task records for both generations");
      ] in
      (false, Yojson.Safe.pretty_to_string json)
  | Some comp ->
      let json = `Assoc [
        ("gen_a", `Int comp.gen_a);
        ("gen_b", `Int comp.gen_b);
        ("completion_delta", `Float comp.completion_delta);
        ("error_delta", `Float comp.error_delta);
        ("duration_delta", `Float comp.duration_delta);
        ("token_delta", `Float comp.token_delta);
        ("retention_b", match comp.retention_b with Some r -> `Float r | None -> `Null);
        ("verdict", `String comp.verdict);
        ("formatted", `String (Generational_metrics.format_comparison comp));
      ] in
      (true, Yojson.Safe.pretty_to_string json)

(** P1-4: Record task completion *)
let handle_metrics_record _ctx args : result =
  let task_id = get_string args "task_id" (Printf.sprintf "task-%d" (int_of_float (Time_compat.now () *. 1000.0) mod 100000)) in
  let completed = match args with
    | `Assoc pairs -> (
        match List.assoc_opt "completed" pairs with
        | Some (`Bool b) -> b
        | _ -> true
      )
    | _ -> true
  in
  let duration_ms = int_of_float (get_float args "duration_ms" 0.0) in
  let error_count = int_of_float (get_float args "error_count" 0.0) in
  let input_tokens = int_of_float (get_float args "input_tokens" 0.0) in
  let output_tokens = int_of_float (get_float args "output_tokens" 0.0) in
  let cell = !(Mcp_server.current_cell) in
  let generation = cell.Mitosis.generation in
  let record = Generational_metrics.record_task
    ~generation ~task_id ~completed ~duration_ms ~error_count
    ~input_tokens ~output_tokens
  in
  let json = `Assoc [
    ("action", `String "task_recorded");
    ("generation", `Int record.generation);
    ("task_id", `String record.task_id);
    ("completed", `Bool record.completed);
  ] in
  (true, Yojson.Safe.pretty_to_string json)

(** {1 Schemas and Dispatcher} *)

let schemas = Tool_mitosis_schemas.schemas

let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_mitosis_status" -> Some (handle_mitosis_status ctx args)
  | "masc_mitosis_all" -> Some (handle_mitosis_all ctx args)
  | "masc_mitosis_pool" -> Some (handle_mitosis_pool ctx args)
  | "masc_mitosis_divide" -> Some (handle_mitosis_divide ctx args)
  | "masc_mitosis_check" -> Some (handle_mitosis_check ctx args)
  | "masc_mitosis_record" -> Some (handle_mitosis_record ctx args)
  | "masc_mitosis_prepare" -> Some (handle_mitosis_prepare ctx args)
  | "masc_mitosis_handoff" -> Some (handle_mitosis_handoff ctx args)
  | "masc_metrics_compare" -> Some (handle_metrics_compare ctx args)
  | "masc_metrics_record" -> Some (handle_metrics_record ctx args)
  | _ -> None
