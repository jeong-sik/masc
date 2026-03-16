(** Tool_mitosis — Mitosis MCP tool handlers and dispatch.

    8 tools: mitosis_status, mitosis_all, mitosis_pool, mitosis_divide,
             mitosis_check, mitosis_record, mitosis_prepare, mitosis_handoff
    Plus: metrics_compare, metrics_record

    Context types, helpers, and spawn cascade are in:
    - Mitosis_helpers: types, verifier, episode/saga management
    - Mitosis_spawn: agent spawn cascade with circuit breaker

    Include chain: Mitosis_helpers -> Mitosis_spawn -> Tool_mitosis *)

include Mitosis_spawn
open Tool_args

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
        Printf.eprintf "[MITOSIS/ERROR] mitosis_divide spawn failed, state unchanged\n%!";
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
    Printf.eprintf "[MITOSIS/WARN] context_ratio is 0.0 - did you forget to estimate it?\n%!";

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

let contains_substring_ci ~haystack ~needle =
  let h = String.lowercase_ascii haystack in
  let n = String.lowercase_ascii needle in
  let lh = String.length h in
  let ln = String.length n in
  if ln = 0 then
    true
  else if ln > lh then
    false
  else
    let rec loop i =
      if i + ln > lh then false
      else if String.sub h i ln = n then true
      else loop (i + 1)
    in
    loop 0

(** DNA quality validation - BALTHASAR feedback (P1-7: enhanced semantic checks)
    Ensures extracted DNA contains meaningful, structured content.
    Checks: length, goal/task markers, whitespace ratio, structural markers. *)
let validate_dna dna =
  let min_length = 50 in
  let len = String.length dna in
  if len < min_length then
    Error (Printf.sprintf "DNA too short: %d chars (min: %d)" len min_length)
  else
    (* Check for goal/task markers (case-insensitive) *)
    let has_marker =
      List.exists (fun needle -> contains_substring_ci ~haystack:dna ~needle)
        ["goal"; "task"; "objective"; "context"]
    in
    if not has_marker then
      Error "DNA lacks goal/task markers (expected: goal, task, objective, or context)"
    else
      (* Check whitespace ratio < 0.5 *)
      let ws_count = String.fold_left (fun acc c ->
        if c = ' ' || c = '\t' || c = '\n' || c = '\r' then acc + 1 else acc
      ) 0 dna in
      let ws_ratio = Float.of_int ws_count /. Float.of_int len in
      if ws_ratio >= 0.5 then
        Error (Printf.sprintf "DNA is mostly whitespace: %.0f%% (max: 50%%)" (ws_ratio *. 100.0))
      else
        (* Check for structural markers: newline, bullet, colon, dash *)
        let has_structure =
          String.contains dna '\n' ||
          contains_substring_ci ~haystack:dna ~needle:"- " ||
          contains_substring_ci ~haystack:dna ~needle:": " ||
          contains_substring_ci ~haystack:dna ~needle:"* "
        in
        if not has_structure then
          Error "DNA lacks structure (expected: newlines, bullets, colons, or dashes)"
        else
          Ok dna

let normalize_for_overlap s =
  let b = Buffer.create (String.length s) in
  String.iter (fun c ->
    let lc = Char.lowercase_ascii c in
    if (lc >= 'a' && lc <= 'z') || (lc >= '0' && lc <= '9') then
      Buffer.add_char b lc
    else
      Buffer.add_char b ' '
  ) s;
  Buffer.contents b

let tokenize_overlap s =
  String.split_on_char ' ' (normalize_for_overlap s)
  |> List.filter (fun tok -> String.length tok >= 3)

let token_overlap_ratio ~source ~target =
  let source_tokens = tokenize_overlap source in
  match source_tokens with
  | [] -> 1.0
  | _ ->
      let matched =
        List.fold_left (fun acc tok ->
          if List.mem tok (tokenize_overlap target) then acc + 1 else acc
        ) 0 source_tokens
      in
      Float.of_int matched /. Float.of_int (List.length source_tokens)

let extract_prefixed_line ~prefix text =
  let p = String.lowercase_ascii prefix in
  let lp = String.length p in
  let rec loop = function
    | [] -> ""
    | line :: rest ->
        let trimmed = String.trim line in
        let lowered = String.lowercase_ascii trimmed in
        if String.length lowered >= lp && String.sub lowered 0 lp = p then
          String.trim (String.sub trimmed lp (String.length trimmed - lp))
        else
          loop rest
  in
  loop (String.split_on_char '\n' text)

let last_non_empty_line text =
  let rec loop last = function
    | [] -> last
    | line :: rest ->
        let trimmed = String.trim line in
        if trimmed = "" then loop last rest else loop trimmed rest
  in
  loop "" (String.split_on_char '\n' text)

let continuity_regression_check ~full_context ~compressed_context =
  let goal_hint = extract_prefixed_line ~prefix:"goal:" full_context in
  let task_hint = extract_prefixed_line ~prefix:"current task:" full_context in
  let recent_hint = last_non_empty_line full_context in
  let hints =
    List.filter (fun (_, v) -> String.trim v <> "") [
      ("goal", goal_hint);
      ("current_task", task_hint);
      ("recent_turn", recent_hint);
    ]
  in
  let details, passed =
    List.fold_left (fun (acc, pass_n) (name, hint) ->
      let overlap = token_overlap_ratio ~source:hint ~target:compressed_context in
      let retained =
        contains_substring_ci ~haystack:compressed_context ~needle:hint
        || overlap >= 0.6
      in
      let detail = `Assoc [
        ("name", `String name);
        ("hint", `String (Mitosis.safe_sub hint 0 120));
        ("overlap_ratio", `Float overlap);
        ("retained", `Bool retained);
      ] in
      (detail :: acc, if retained then pass_n + 1 else pass_n)
    ) ([], 0) hints
  in
  let total = List.length hints in
  let retention_score =
    if total = 0 then 1.0
    else Float.of_int passed /. Float.of_int total
  in
  `Assoc [
    ("assessed", `Bool (total > 0));
    ("checks_total", `Int total);
    ("checks_passed", `Int passed);
    ("retention_score", `Float retention_score);
    ("details", `List (List.rev details));
  ]

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
    - target_agent: string (optional) - "claude"|"gemini"|"codex"|"llama" (default: "claude")
    - prepare_threshold: float (optional) - when to prepare DNA (default: 0.5)
    - handoff_threshold: float (optional) - when to handoff (default: 0.8)
    - spawn_timeout: int (optional) - spawn timeout in seconds (default: 600)
    
    On spawn failure: Returns "fallback" with compaction suggestion instead of silent failure
*)
let run_sync_handoff ctx args : result =
  (* P2-2: Experiment flag — log when experimental mitosis path is active *)
  if Env_config.Mitosis.experiment_enabled then
    Printf.eprintf "[MITOSIS/EXPERIMENT] Experimental mitosis path active\n%!";
  (* P1-3: Handoff cooldown — prevent rapid repeated handoffs *)
  let cooldown = Env_config.Mitosis.handoff_cooldown_seconds in
  let now = Time_compat.now () in
  let elapsed = now -. !last_handoff_time in
  if !last_handoff_time > 0.0 && elapsed < cooldown then begin
    let remaining = cooldown -. elapsed in
    (* P2-3: Expose cooldown remaining to Prometheus *)
    Mitosis_metrics.set_cooldown_remaining remaining;
    let json = `Assoc [
      ("action", `String "cooldown");
      ("message", `String (Printf.sprintf "Handoff cooldown active. %.0fs remaining (cooldown: %.0fs)" remaining cooldown));
      ("cooldown_remaining_sec", `Float remaining);
      ("cooldown_total_sec", `Float cooldown);
    ] in
    (false, Yojson.Safe.pretty_to_string json)
  end else

  let raw_ratio = get_float args "context_ratio" 0.0 in
  let context_ratio = validate_context_ratio raw_ratio in
  let full_context = get_string args "full_context" "" in
  let target_agent = get_string args "target_agent" "claude" in
  match validate_target_agent_label target_agent with
  | Error msg ->
      let json = `Assoc [
        ("action", `String "error");
        ("error", `String msg);
        ("target_agent", `String target_agent);
      ] in
      (false, Yojson.Safe.pretty_to_string json)
  | Ok normalized_target_agent ->
      let spawn_timeout = int_of_float (get_float args "spawn_timeout" (Float.of_int Mitosis.Defaults.spawn_timeout_seconds)) in

      if raw_ratio = 0.0 then
        Printf.eprintf "[MITOSIS/WARN] context_ratio is 0.0 - did you forget to estimate it?\n%!";

      let room_name = Filename.basename ctx.config.Room_utils.base_path in
      let adaptive_enabled = Env_config.Mitosis.adaptive_thresholds_enabled in
      let effective = Adaptive_thresholds.get_effective_thresholds
        ~enabled:adaptive_enabled ~room:room_name in
      let prepare_threshold = get_float args "prepare_threshold" effective.Adaptive_thresholds.prepare in
      let handoff_threshold = get_float args "handoff_threshold" effective.Adaptive_thresholds.handoff in
      if adaptive_enabled then
        Printf.eprintf "[MITOSIS/ADAPTIVE] room=%s prepare=%.3f handoff=%.3f\n%!"
          room_name prepare_threshold handoff_threshold;

      let cell = !(Mcp_server.current_cell) in
      let config_mitosis = { Mitosis.default_config with
        prepare_threshold;
        handoff_threshold;
      } in
      let pool = !(Mcp_server.stem_pool) in

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
      let no_action_message =
        match cell.Mitosis.phase with
        | Mitosis.ReadyForHandoff _ ->
            "Already prepared. Continue working until handoff threshold."
        | Mitosis.Idle ->
            "Context ratio below prepare threshold. Continue working."
      in
      let warning = if raw_ratio = 0.0 then
        [("warning", `String "context_ratio is 0.0 - did you forget to provide it?")]
      else [] in
      let json = `Assoc ([
        ("action", `String "none");
        ("context_ratio", `Float context_ratio);
        ("phase", `String (Mitosis.phase_to_string cell.Mitosis.phase));
        ("message", `String no_action_message);
        ("threshold_prepare", `Float config_mitosis.Mitosis.prepare_threshold);
        ("threshold_handoff", `Float config_mitosis.Mitosis.handoff_threshold);
      ] @ warning) in
      (true, Yojson.Safe.pretty_to_string json)
      
  | Mitosis.Prepared prepared_cell ->
      let dna = Option.value ~default:"" prepared_cell.Mitosis.prepared_dna in
      let continuity =
        continuity_regression_check ~full_context ~compressed_context:dna
      in
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
        ("continuity_regression", continuity);
        ("threshold_handoff", `Float config_mitosis.Mitosis.handoff_threshold);
      ] in
      (true, Yojson.Safe.pretty_to_string json)
      
  | Mitosis.Handoff (spawn_result, new_cell, new_pool, handoff_dna) ->
      (* P0-5: Record handoff in generational metrics *)
      let dna_size = String.length handoff_dna in
      (try ignore (Generational_metrics.record_handoff
        ~from_generation:cell.Mitosis.generation
        ~to_generation:new_cell.Mitosis.generation
        ~dna_size
        ~context_ratio)
       with exn -> Printf.eprintf "[mitosis] record_handoff failed: %s\n%!" (Printexc.to_string exn));
      let effective_agent =
        if !selected_agent = "" then normalized_target_agent else !selected_agent
      in
      let attempts_json = spawn_attempts_to_json !spawn_attempts in
      let continuity =
        continuity_regression_check ~full_context ~compressed_context:handoff_dna
      in
      
      (* Check spawn success - BALTHASAR feedback: handle failures gracefully *)
      if not spawn_result.Spawn.success then begin
        (* P2-3: Record spawn failure metric *)
        Mitosis_metrics.inc_error ~reason:"spawn_failed" ();
        (* Spawn failed! Suggest fallback to compaction instead of losing context *)
        Printf.eprintf "[MITOSIS/ERROR] Spawn failed for %s, suggesting fallback\n%!" target_agent;
        let base_path = ctx.config.Room_utils.base_path in
        let session_id = get_session_id () in
        let fallback_ep = queue_episode
          ~base_path
          ~session_id
          ~agent_name:effective_agent
          ~generation:new_cell.Mitosis.generation
          ~event_type:"mitosis_handoff_fallback"
          ~summary:(Printf.sprintf "Mitosis handoff fallback: gen %d → gen %d (target: %s, context: %.0f%%)"
            cell.Mitosis.generation new_cell.Mitosis.generation target_agent (context_ratio *. 100.0))
          ~dna:handoff_dna
          () in
        let json = `Assoc [
          ("action", `String "fallback");
          ("success", `Bool false);
          ("context_ratio", `Float context_ratio);
          ("message", `String "Spawn failed! Consider using compaction instead. Context preserved.");
          ("target_agent", `String target_agent);
          ("selected_agent", `String effective_agent);
          ("spawn_attempts", attempts_json);
          ("spawn_error", `String spawn_result.Spawn.output);
          ("continuity_regression", continuity);
          ("episode_queued", match fallback_ep with Some id -> `String id | None -> `Null);
          ("suggestion", `String "Use /compact or masc_mitosis_divide with summary for graceful degradation");
        ] in
        (true, Yojson.Safe.pretty_to_string json)
      end else begin
        Mcp_server.current_cell := new_cell;
        Mcp_server.stem_pool := new_pool;
        Mitosis.write_status_with_backend ~room_config:ctx.config ~cell:new_cell ~config:config_mitosis;
        (* P1-3: Update cooldown timer after successful handoff *)
        last_handoff_time := Time_compat.now ();
        (* P2-3: Record handoff success metrics *)
        Mitosis_metrics.inc_handoff ();
        Mitosis_metrics.set_generation new_cell.Mitosis.generation;
        Mitosis_metrics.set_cooldown_remaining 0.0;
        let duration_sec = (float_of_int spawn_result.Spawn.elapsed_ms) /. 1000.0 in
        Mitosis_metrics.observe_handoff_duration duration_sec;

        (* P2-1: Adaptive threshold learning from handoff outcome *)
        if adaptive_enabled then begin
          let was_emergency = match cell.Mitosis.phase with
            | Mitosis.Idle -> true    (* handoff without Prepared state *)
            | Mitosis.ReadyForHandoff _ -> false
          in
          let outcome : Handoff_quality.handoff_outcome = {
            completion_rate = context_ratio;  (* approximate: higher ratio = more complete *)
            error_count = 0;  (* spawn succeeded, no errors *)
            was_emergency;
            duration_seconds = duration_sec;
            generation = cell.Mitosis.generation;
          } in
          let current_state = match Adaptive_thresholds.load_state ~room:room_name with
            | Some s -> s
            | None -> Adaptive_thresholds.initial_state ()
          in
          let new_state = Adaptive_thresholds.adapt current_state outcome in
          (try Adaptive_thresholds.save_state ~room:room_name new_state
           with exn ->
             Printf.eprintf "[MITOSIS/ADAPTIVE] save failed: %s\n%!" (Printexc.to_string exn));
          Printf.eprintf "[MITOSIS/ADAPTIVE] adapted room=%s prepare=%.3f->%.3f handoff=%.3f->%.3f\n%!"
            room_name
            current_state.thresholds.prepare new_state.thresholds.prepare
            current_state.thresholds.handoff new_state.thresholds.handoff
        end;

        (* Agent Being Protocol: Queue Episode for persistence *)
        let base_path = ctx.config.Room_utils.base_path in
        let session_id = get_session_id () in
        let summary = Printf.sprintf "Mitosis handoff: gen %d → gen %d (target: %s, context: %.0f%%)"
          cell.Mitosis.generation new_cell.Mitosis.generation target_agent (context_ratio *. 100.0) in
        let ep_id = queue_episode
          ~base_path
          ~session_id
          ~agent_name:effective_agent
          ~generation:new_cell.Mitosis.generation
          ~event_type:"mitosis_handoff"
          ~summary
          ~dna:handoff_dna
          () in

        let output_preview = Mitosis.safe_sub spawn_result.Spawn.output 0 500 in
        let adaptive_info = if adaptive_enabled then
          [("adaptive_thresholds_enabled", `Bool true);
           ("adaptive_thresholds",
            `Assoc [("prepare", `Float prepare_threshold);
                    ("handoff", `Float handoff_threshold)])]
        else [] in
        let json = `Assoc ([
          ("action", `String "handoff");
          ("success", `Bool true);
          ("context_ratio", `Float context_ratio);
          ("message", `String "Handoff complete! Successor agent spawned.");
          ("target_agent", `String target_agent);
          ("selected_agent", `String effective_agent);
          ("spawn_attempts", attempts_json);
          ("previous_generation", `Int cell.Mitosis.generation);
          ("new_generation", `Int new_cell.Mitosis.generation);
          ("successor_output", `String output_preview);
          ("elapsed_ms", `Int spawn_result.Spawn.elapsed_ms);
          ("continuity_regression", continuity);
          ("episode_queued", match ep_id with Some id -> `String id | None -> `Null);
        ] @ adaptive_info) in
        (true, Yojson.Safe.pretty_to_string json)
      end

let handle_mitosis_handoff ctx args : result =
  let async_mode = get_bool args "async" true in
  match async_mode, ctx.sw with
  | true, Some sw ->
      let base_path = ctx.config.Room_utils.base_path in
      let saga_id = generate_saga_id () in
      let args_sync = set_bool_arg args "async" false in
      let saga_timeout_sec =
        max 1.0 (get_float args_sync "verification_saga_timeout_sec" 180.0)
      in
      let status_file = write_saga_state
        ~base_path
        ~saga_id
        ~status:"queued"
        ~payload:(`Assoc [
          ("mode", `String "async");
          ("tool", `String "masc_mitosis_handoff");
        ])
      in
      Eio.Fiber.fork ~sw (fun () ->
        (try ignore (write_saga_state
          ~base_path
          ~saga_id
          ~status:"running"
          ~payload:(`Assoc [("message", `String "handoff saga running")]))
         with exn -> Printf.eprintf "[mitosis] write_saga_state(running) failed: %s\n%!" (Printexc.to_string exn));
        let started = Time_compat.now () in
        try
          let run_once () =
            let (ok, body) = run_sync_handoff ctx args_sync in
            let parsed =
              try Yojson.Safe.from_string body
              with Yojson.Json_error _ -> `String body
            in
            let (verification, gate_pass) =
              run_handoff_verifier ~ctx ~args:args_sync ~parsed_result:parsed
            in
            let final_ok = ok && gate_pass in
            (try ignore (write_saga_state
              ~base_path
              ~saga_id
              ~status:(if final_ok then "completed" else "failed")
              ~payload:(`Assoc [
                ("ok", `Bool final_ok);
                ("operation_ok", `Bool ok);
                ("verification_gate_passed", `Bool gate_pass);
                ("elapsed_sec", `Float (Time_compat.now () -. started));
                ("result", parsed);
                ("verification", match verification with Some v -> v | None -> `Null);
              ]))
             with exn -> Printf.eprintf "[mitosis] write_saga_state(result) failed: %s\n%!" (Printexc.to_string exn))
          in
          (match ctx.clock with
           | Some (Clock clock) ->
               (try
                  Eio.Time.with_timeout_exn clock saga_timeout_sec run_once
                with Eio.Time.Timeout ->
                  (try ignore (write_saga_state
                    ~base_path
                    ~saga_id
                    ~status:"failed"
                    ~payload:(`Assoc [
                      ("ok", `Bool false);
                      ("operation_ok", `Bool false);
                      ("verification_gate_passed", `Bool false);
                      ("elapsed_sec", `Float (Time_compat.now () -. started));
                      ("error", `String "verification_saga_timeout");
                      ("timeout_sec", `Float saga_timeout_sec);
                    ]))
                   with exn -> Printf.eprintf "[mitosis] write_saga_state(timeout) failed: %s\n%!" (Printexc.to_string exn)))
           | None ->
               run_once ())
        with exn ->
          (try ignore (write_saga_state
            ~base_path
            ~saga_id
            ~status:"error"
            ~payload:(`Assoc [
              ("error", `String (Printexc.to_string exn));
            ]))
           with exn2 -> Printf.eprintf "[mitosis] write_saga_state(error) failed: %s\n%!" (Printexc.to_string exn2)));
      let json = `Assoc [
        ("action", `String "accepted");
        ("async", `Bool true);
        ("saga_id", `String saga_id);
        ("status_file", match status_file with Some p -> `String p | None -> `Null);
        ("message", `String "Handoff saga accepted. Check saga file for completion.");
      ] in
      (true, Yojson.Safe.pretty_to_string json)
  | _ ->
      let args_sync = set_bool_arg args "async" false in
      let (ok, body) = run_sync_handoff ctx args_sync in
      let parsed =
        try Yojson.Safe.from_string body
        with Yojson.Json_error _ -> `String body
      in
      let (verification, gate_pass) = run_handoff_verifier ~ctx ~args:args_sync ~parsed_result:parsed in
      let final_ok = ok && gate_pass in
      let enriched =
        match parsed with
        | `Assoc fields ->
            `Assoc (
              ("verification", match verification with Some v -> v | None -> `Null)
              :: ("verification_gate_passed", `Bool gate_pass)
              :: ("operation_ok", `Bool ok)
              :: fields
            )
        | _ ->
            `Assoc [
              ("result", parsed);
              ("verification", match verification with Some v -> v | None -> `Null);
              ("verification_gate_passed", `Bool gate_pass);
              ("operation_ok", `Bool ok);
            ]
      in
      (final_ok, Yojson.Safe.pretty_to_string enriched)

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
