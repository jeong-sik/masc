(** Mitosis_handoff — Core handoff logic: run_sync_handoff and
    handle_mitosis_handoff (sync + async saga).

    Extracted from Tool_mitosis. Depends on Mitosis_spawn (for spawn
    cascade and context types) and Mitosis_continuity (for DNA validation
    and continuity regression).

    @since 2.122.0 *)

include Mitosis_spawn
open Tool_args

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
  (* P2-2: Experiment flag -- log when experimental mitosis path is active *)
  if Env_config.Mitosis.experiment_enabled then
    Log.Mitosis_log.info "Experimental mitosis path active";
  (* P1-3: Handoff cooldown -- prevent rapid repeated handoffs *)
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
        Log.Mitosis_log.warn "context_ratio is 0.0 - did you forget to estimate it?";

      let room_name = Filename.basename ctx.config.Room_utils.base_path in
      let adaptive_enabled = Env_config.Mitosis.adaptive_thresholds_enabled in
      let effective = Adaptive_thresholds.get_effective_thresholds
        ~enabled:adaptive_enabled ~room:room_name in
      let prepare_threshold = get_float args "prepare_threshold" effective.Adaptive_thresholds.prepare in
      let handoff_threshold = get_float args "handoff_threshold" effective.Adaptive_thresholds.handoff in
      if adaptive_enabled then
        Log.Mitosis_log.info "adaptive room=%s prepare=%.3f handoff=%.3f"
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
        Mitosis_continuity.continuity_regression_check ~full_context ~compressed_context:dna
      in
      (* Validate DNA quality *)
      let dna_status = match Mitosis_continuity.validate_dna dna with
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
       with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Mitosis_log.error "record_handoff failed: %s" (Printexc.to_string exn));
      let effective_agent =
        if !selected_agent = "" then normalized_target_agent else !selected_agent
      in
      let attempts_json = spawn_attempts_to_json !spawn_attempts in
      let continuity =
        Mitosis_continuity.continuity_regression_check ~full_context ~compressed_context:handoff_dna
      in

      (* Check spawn success - BALTHASAR feedback: handle failures gracefully *)
      if not spawn_result.Spawn.success then begin
        (* P2-3: Record spawn failure metric *)
        Mitosis_metrics.inc_error ~reason:"spawn_failed" ();
        (* Spawn failed! Suggest fallback to compaction instead of losing context *)
        Log.Mitosis_log.error "Spawn failed for %s, suggesting fallback" target_agent;
        let base_path = ctx.config.Room_utils.base_path in
        let session_id = get_session_id () in
        let fallback_ep = queue_episode
          ~base_path
          ~session_id
          ~agent_name:effective_agent
          ~generation:new_cell.Mitosis.generation
          ~event_type:"mitosis_handoff_fallback"
          ~summary:(Printf.sprintf "Mitosis handoff fallback: gen %d -> gen %d (target: %s, context: %.0f%%)"
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
           with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
             Log.Mitosis_log.error "adaptive save failed: %s" (Printexc.to_string exn));
          Log.Mitosis_log.info "adaptive adapted room=%s prepare=%.3f->%.3f handoff=%.3f->%.3f"
            room_name
            current_state.thresholds.prepare new_state.thresholds.prepare
            current_state.thresholds.handoff new_state.thresholds.handoff
        end;

        (* Agent Being Protocol: Queue Episode for persistence *)
        let base_path = ctx.config.Room_utils.base_path in
        let session_id = get_session_id () in
        let summary = Printf.sprintf "Mitosis handoff: gen %d -> gen %d (target: %s, context: %.0f%%)"
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
         with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Mitosis_log.error "write_saga_state(running) failed: %s" (Printexc.to_string exn));
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
             with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Mitosis_log.error "write_saga_state(result) failed: %s" (Printexc.to_string exn))
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
                   with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Mitosis_log.error "write_saga_state(timeout) failed: %s" (Printexc.to_string exn)))
           | None ->
               run_once ())
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          (try ignore (write_saga_state
            ~base_path
            ~saga_id
            ~status:"error"
            ~payload:(`Assoc [
              ("error", `String (Printexc.to_string exn));
            ]))
           with Eio.Cancel.Cancelled _ as e -> raise e | exn2 -> Log.Mitosis_log.error "write_saga_state(error) failed: %s" (Printexc.to_string exn2)));
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
