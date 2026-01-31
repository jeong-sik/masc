(** Mitosis Tool Handlers

    Extracted from mcp_server_eio.ml for testability.
    8 tools: mitosis_status, mitosis_all, mitosis_pool, mitosis_divide,
             mitosis_check, mitosis_record, mitosis_prepare, mitosis_handoff
    
    Key tool: masc_mitosis_handoff - 2-phase proactive context management
    - 50% threshold: DNA preparation (context summary extracted)
    - 80% threshold: Handoff execution (spawn successor agent)
*)

(** Tool handler context *)
type context = {
  config: Room.config;
}

(** Tool result type *)
type result = bool * string

(** {1 Argument Helpers} *)

let get_string args key default =
  match args with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`String s) -> s
       | _ -> default)
  | _ -> default

let get_float args key default =
  match args with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`Float f) -> f
       | Some (`Int i) -> Float.of_int i
       | _ -> default)
  | _ -> default

let get_bool args key default =
  match args with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`Bool b) -> b
       | _ -> default)
  | _ -> default

(** {1 Individual Handlers} *)

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
  let full_context =
    if current_task = "" then summary
    else Printf.sprintf "Summary: %s\n\nCurrent Task: %s" summary current_task
  in
  let cell = !(Mcp_server.current_cell) in
  let config_mitosis = Mitosis.default_config in
  let spawn_fn ~prompt =
    Spawn.spawn ~agent_name:"claude" ~prompt ~timeout_seconds:600 ()
  in
  let (spawn_result, new_cell, new_pool) =
    Mitosis.execute_mitosis ~config:config_mitosis ~pool:!(Mcp_server.stem_pool)
      ~parent:cell ~full_context ~spawn_fn
  in
  Mcp_server.current_cell := new_cell;
  Mcp_server.stem_pool := new_pool;
  Mitosis.write_status_with_backend ~room_config:ctx.config ~cell:new_cell ~config:config_mitosis;
  let json = `Assoc [
    ("success", `Bool spawn_result.Spawn.success);
    ("previous_generation", `Int cell.Mitosis.generation);
    ("new_generation", `Int new_cell.Mitosis.generation);
    ("successor_output", `String (String.sub spawn_result.Spawn.output 0 (min 500 (String.length spawn_result.Spawn.output))));
  ] in
  (true, Yojson.Safe.pretty_to_string json)

let handle_mitosis_check _ctx args : result =
  let context_ratio = get_float args "context_ratio" 0.0 in
  let cell = !(Mcp_server.current_cell) in
  let config_mitosis = Mitosis.default_config in
  let should_prepare = Mitosis.should_prepare ~config:config_mitosis ~cell ~context_ratio in
  let should_handoff = Mitosis.should_handoff ~config:config_mitosis ~cell ~context_ratio in
  let json = `Assoc [
    ("should_prepare", `Bool should_prepare);
    ("should_handoff", `Bool should_handoff);
    ("context_ratio", `Float context_ratio);
    ("threshold_prepare", `Float config_mitosis.Mitosis.prepare_threshold);
    ("threshold_handoff", `Float config_mitosis.Mitosis.handoff_threshold);
    ("phase", `String (Mitosis.phase_to_string cell.Mitosis.phase));
  ] in
  (true, Yojson.Safe.pretty_to_string json)

let handle_mitosis_record ctx _args : result =
  let task_done = get_bool _args "task_done" false in
  let tool_called = get_bool _args "tool_called" false in
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
  let cell = !(Mcp_server.current_cell) in
  let prepared = Mitosis.prepare_for_division ~config:Mitosis.default_config ~cell ~full_context in
  Mcp_server.current_cell := prepared;
  Mitosis.write_status_with_backend ~room_config:ctx.config ~cell:prepared ~config:Mitosis.default_config;
  let json = `Assoc [
    ("status", `String "prepared");
    ("phase", `String (Mitosis.phase_to_string prepared.Mitosis.phase));
    ("dna_length", `Int (String.length (Option.value ~default:"" prepared.Mitosis.prepared_dna)));
  ] in
  (true, Yojson.Safe.pretty_to_string json)

(** DNA quality validation - BALTHASAR feedback
    Ensures extracted DNA contains meaningful content *)
let validate_dna dna =
  let min_length = 50 in
  let len = String.length dna in
  if len < min_length then
    Error (Printf.sprintf "DNA too short: %d chars (min: %d)" len min_length)
  else
    Ok dna

(** Clamp context_ratio to valid range with warning - BALTHASAR feedback *)
let validate_context_ratio ratio =
  if ratio < 0.0 then begin
    Printf.eprintf "[MITOSIS/WARN] context_ratio < 0 (%.2f), clamping to 0.0\n%!" ratio;
    0.0
  end else if ratio > 1.0 then begin
    Printf.eprintf "[MITOSIS/WARN] context_ratio > 1 (%.2f), clamping to 1.0\n%!" ratio;
    1.0
  end else
    ratio

(** 2-Phase auto mitosis handoff - THE CORE TOOL (v2 with BALTHASAR feedback)

    IMPROVEMENTS from v1:
    - context_ratio validation with clamping
    - DNA quality check before handoff
    - Fallback to compaction if spawn fails
    - Better error messages
    
    Usage:
    - Call periodically with your estimated context_ratio
    - At 50%: DNA is prepared (returns "prepared")
    - At 80%: Handoff executes (spawns successor agent)
    - Below 50%: No action needed
    
    Arguments:
    - context_ratio: float (0.0-1.0) - estimated context usage
    - full_context: string - current context/summary to pass to successor
    - target_agent: string (optional) - "claude"|"gemini"|"codex"|"ollama" (default: "claude")
    - prepare_threshold: float (optional) - when to prepare DNA (default: 0.5)
    - handoff_threshold: float (optional) - when to handoff (default: 0.8)
    - spawn_timeout: int (optional) - spawn timeout in seconds (default: 600)
    
    On spawn failure: Returns "fallback" with compaction suggestion instead of silent failure
*)
let handle_mitosis_handoff ctx args : result =
  let raw_ratio = get_float args "context_ratio" 0.0 in
  let context_ratio = validate_context_ratio raw_ratio in
  let full_context = get_string args "full_context" "" in
  let target_agent = get_string args "target_agent" "claude" in
  (* P0-1: Configurable thresholds instead of hardcoded 0.5/0.8 *)
  let prepare_threshold = get_float args "prepare_threshold" 0.5 in
  let handoff_threshold = get_float args "handoff_threshold" 0.8 in
  let spawn_timeout = int_of_float (get_float args "spawn_timeout" 600.0) in
  
  (* Warn if context_ratio is default 0.0 - likely caller forgot to provide it *)
  if raw_ratio = 0.0 then
    Printf.eprintf "[MITOSIS/WARN] context_ratio is 0.0 - did you forget to estimate it?\n%!";
  
  let cell = !(Mcp_server.current_cell) in
  (* Override config with custom thresholds if provided *)
  let config_mitosis = { Mitosis.default_config with
    prepare_threshold;
    handoff_threshold;
  } in
  let pool = !(Mcp_server.stem_pool) in
  
  let spawn_fn ~prompt =
    Spawn.spawn ~agent_name:target_agent ~prompt ~timeout_seconds:spawn_timeout ()
  in
  
  let result = Mitosis.auto_mitosis_check_2phase
    ~config:config_mitosis
    ~pool
    ~cell
    ~context_ratio
    ~full_context
    ~spawn_fn
  in
  
  match result with
  | Mitosis.NoAction ->
      let json = `Assoc [
        ("action", `String "none");
        ("context_ratio", `Float context_ratio);
        ("message", `String "Context ratio below prepare threshold. Continue working.");
        ("threshold_prepare", `Float config_mitosis.Mitosis.prepare_threshold);
        ("threshold_handoff", `Float config_mitosis.Mitosis.handoff_threshold);
      ] in
      (true, Yojson.Safe.pretty_to_string json)
      
  | Mitosis.Prepared prepared_cell ->
      let dna = Option.value ~default:"" prepared_cell.Mitosis.prepared_dna in
      (* Validate DNA quality *)
      let dna_status = match validate_dna dna with
        | Ok _ -> "valid"
        | Error msg -> Printf.sprintf "warning: %s" msg
      in
      Mcp_server.current_cell := prepared_cell;
      Mitosis.write_status_with_backend ~room_config:ctx.config ~cell:prepared_cell ~config:config_mitosis;
      let json = `Assoc [
        ("action", `String "prepared");
        ("context_ratio", `Float context_ratio);
        ("message", `String "DNA extracted and ready. Continue working until 80% threshold.");
        ("phase", `String (Mitosis.phase_to_string prepared_cell.Mitosis.phase));
        ("dna_length", `Int (String.length dna));
        ("dna_quality", `String dna_status);
        ("threshold_handoff", `Float config_mitosis.Mitosis.handoff_threshold);
      ] in
      (true, Yojson.Safe.pretty_to_string json)
      
  | Mitosis.Handoff (spawn_result, new_cell, new_pool) ->
      (* P0-5: Record handoff in generational metrics *)
      let dna_size = String.length (Option.value ~default:"" cell.Mitosis.prepared_dna) in
      ignore (Generational_metrics.record_handoff
        ~from_generation:cell.Mitosis.generation
        ~to_generation:new_cell.Mitosis.generation
        ~dna_size
        ~context_ratio);
      
      (* Check spawn success - BALTHASAR feedback: handle failures gracefully *)
      if not spawn_result.Spawn.success then begin
        (* Spawn failed! Suggest fallback to compaction instead of losing context *)
        Printf.eprintf "[MITOSIS/ERROR] Spawn failed for %s, suggesting fallback\n%!" target_agent;
        let json = `Assoc [
          ("action", `String "fallback");
          ("success", `Bool false);
          ("context_ratio", `Float context_ratio);
          ("message", `String "Spawn failed! Consider using compaction instead. Context preserved.");
          ("target_agent", `String target_agent);
          ("spawn_error", `String spawn_result.Spawn.output);
          ("suggestion", `String "Use /compact or masc_mitosis_divide with summary for graceful degradation");
        ] in
        (true, Yojson.Safe.pretty_to_string json)
      end else begin
        Mcp_server.current_cell := new_cell;
        Mcp_server.stem_pool := new_pool;
        Mitosis.write_status_with_backend ~room_config:ctx.config ~cell:new_cell ~config:config_mitosis;
        let output_preview = 
          let len = String.length spawn_result.Spawn.output in
          if len > 500 then String.sub spawn_result.Spawn.output 0 500 ^ "..."
          else spawn_result.Spawn.output
        in
        let json = `Assoc [
          ("action", `String "handoff");
          ("success", `Bool true);
          ("context_ratio", `Float context_ratio);
          ("message", `String "Handoff complete! Successor agent spawned.");
          ("target_agent", `String target_agent);
          ("previous_generation", `Int cell.Mitosis.generation);
          ("new_generation", `Int new_cell.Mitosis.generation);
          ("successor_output", `String output_preview);
          ("elapsed_ms", `Int spawn_result.Spawn.elapsed_ms);
        ] in
        (true, Yojson.Safe.pretty_to_string json)
      end

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
  let task_id = get_string args "task_id" (Printf.sprintf "task-%d" (int_of_float (Unix.gettimeofday () *. 1000.0) mod 100000)) in
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
  | "masc_mitosis_handoff" -> Some (handle_mitosis_handoff ctx args)
  | "masc_metrics_compare" -> Some (handle_metrics_compare ctx args)
  | "masc_metrics_record" -> Some (handle_metrics_record ctx args)
  | _ -> None
