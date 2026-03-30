(** Tool_mdal — Metric-Driven Agent Loop tool implementations. *)

include Tool_mdal_handlers

let handle_start (ctx : context) args =
  let open Yojson.Safe.Util in
  try
    let profile_name = Safe_ops.json_string "profile" args in
    let worker_model_arg = resolve_worker_model_arg args in
    (* Build profile: start from built-in or create custom *)
    let base_profile =
      if profile_name = "custom" then
        let metric_fn = Safe_ops.json_string_opt "metric_fn" args in
        let goal_str = Safe_ops.json_string_opt "goal" args in
        match metric_fn, goal_str with
        | Some mfn, Some gs ->
          let goal = Mdal.parse_goal gs in
          { Mdal.name = "custom";
            metric_fn = mfn;
            goal;
            target = Safe_ops.json_string ~default:gs "target" args;
            reference = Safe_ops.json_string_opt "reference" args;
            agent = Safe_ops.json_string ~default:Mdal.default_mdal_agent "agent" args;
            max_iterations = Safe_ops.json_int ~default:20 "max_iterations" args;
            max_time_seconds = Safe_ops.json_float_opt "max_time_seconds" args;
            stagnation_threshold = 0.005;
            stagnation_count = 3;
            heuristics = Safe_ops.json_string ~default:"" "heuristics" args;
            tools_allow = Safe_ops.json_string_list "tools_allow" args;
            tools_deny = Safe_ops.json_string_list "tools_deny" args;
          }
        | None, _ ->
          invalid_arg "Custom profile requires 'metric_fn'"
        | _, None ->
          invalid_arg "Custom profile requires 'goal'"
      else
        Mdal.builtin_profile profile_name
    in

    if not (runtime_worker_available ctx) then
      invalid_arg
        "MDAL strict worker runtime is unavailable in this context. Start MDAL from the live MCP server or use a test worker runner."
    else ();

    let metric_fn =
      match resolve_metric_fn ~profile_name ~base_profile args with
      | Ok metric_fn -> metric_fn
      | Error msg -> invalid_arg msg
    in

    (* Apply optional overrides *)
    let profile = {
      base_profile with
      metric_fn;
      agent = (args |> member "agent" |> to_string_option
               |> Option.value ~default:base_profile.agent);
      max_iterations = (args |> member "max_iterations" |> to_int_option
                        |> Option.value ~default:base_profile.max_iterations);
      max_time_seconds = (match args |> member "max_time_seconds" |> to_number_option with
                          | Some t -> Some t
                          | None -> base_profile.max_time_seconds);
      heuristics = (args |> member "heuristics" |> to_string_option
                    |> Option.value ~default:base_profile.heuristics);
      reference = (match args |> member "reference" |> to_string_option with
                   | Some r -> Some r
                   | None -> base_profile.reference);
    } in
    let runtime_tools =
      match
        Mdal_worker.resolve_allowed_tools ~tools_allow:profile.tools_allow
          ~tools_deny:profile.tools_deny
      with
      | Ok tools -> tools
      | Error msg -> invalid_arg msg
    in
    let resolved_worker_model =
      match
        Mdal_worker.resolve_model_label ~agent:profile.agent
          ~worker_model:worker_model_arg
      with
      | Ok label -> label
      | Error msg -> invalid_arg msg
    in
    let profile = { profile with tools_allow = runtime_tools } in

    (* Measure baseline metric *)
    match Mdal.measure_metric profile.metric_fn with
    | Error e ->
      `Assoc [("error", `String (Printf.sprintf "Failed to measure baseline: %s" e))]
    | Ok baseline -> (
      match require_config ctx with
      | Error msg -> `Assoc [ ("error", `String msg) ]
      | Ok config ->
      let loop_id = Mdal.generate_loop_id () in

      (* Create initial board post *)
      let state_post_id =
        match Board_dispatch.create_post
                ~author:ctx.agent_name
                ~content:(Printf.sprintf "[MDAL_STATE] %s starting. Profile: %s, Baseline: %.4f, Target: %s"
                            loop_id profile.name baseline profile.target)
                ~post_kind:Board.System_post
                ~meta_json:(`Assoc [ ("source", `String "mdal_state_start") ])
                ~visibility:Board.Internal
                ~ttl_hours:24
                ~hearth:(Mdal.state_hearth loop_id)
                ()
        with
        | Ok post -> Board.Post_id.to_string post.Board.id
        | Error _ -> "unknown"
      in

      let started_at = Time_compat.now () in
      let state : Mdal.loop_state = {
        loop_id;
        profile;
        strict_mode = true;
        status = `Running;
        error_message = None;
        stop_reason = None;
        current_iteration = 0;
        history = [];
        stagnation_streak = 0;
        baseline_metric = baseline;
        start_time = started_at;
        updated_at = started_at;
        stopped_at = None;
        state_post_id;
        execution_mode = `Worker_spawn;
        worker_engine = Some `Api_tool_loop;
        worker_model = Some resolved_worker_model;
      } in
      persist_loop config state;

      (* Broadcast via SSE *)
      (try Sse.broadcast (`Assoc [
         ("type", `String "mdal_started");
         ("loop_id", `String loop_id);
         ("profile", `String profile.name);
         ("baseline", `Float baseline);
         ("target", `String profile.target);
         ("strict_mode", `Bool true);
         ("worker_engine", `String "api_tool_loop");
         ("worker_model", `String resolved_worker_model);
         ("evidence_policy", `String "hard");
         ("execution_mode", `String (Mdal.execution_mode_to_string state.execution_mode));
         ("persistence_backend", `String (config_persistence_backend config));
       ]) with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Misc.warn "tool_mdal: mdal_started SSE failed: %s" (Printexc.to_string exn));

      assoc_with_fields (state_to_json ~config state)
        [ ("worker_prompt", `String (Mdal.render_worker_prompt profile [] baseline)) ])
  with
  | Invalid_argument msg ->
      `Assoc [("error", `String msg)]

let handle_status (ctx : context) args =
  let loop_id = resolve_loop_id ctx args in
  match loop_id with
  | None -> `Assoc [("error", `String "No MDAL loop running")]
  | Some id ->
    match find_loop ?config:ctx.config id with
    | None -> `Assoc [("error", `String (Printf.sprintf "Loop %s not found" id))]
    | Some state -> state_to_json ?config:ctx.config state

let handle_iterate (ctx : context) args =
  try
    (match validate_strict_iterate_args args with
     | Ok () -> ()
     | Error msg -> invalid_arg msg);
    let loop_id = resolve_loop_id ctx args in
    match loop_id with
    | None -> `Assoc [("error", `String "No MDAL loop running")]
    | Some id -> (
      match require_config ctx with
      | Error msg -> `Assoc [ ("error", `String msg) ]
      | Ok config ->
      match find_loop ~config id with
      | None -> `Assoc [("error", `String (Printf.sprintf "Loop %s not found" id))]
      | Some state ->
        let () =
          if not state.strict_mode then
            let message =
              Printf.sprintf
                "Loop %s predates strict MDAL worker mode and cannot iterate. Start a new loop instead."
                id
            in
            raise
              (Invalid_argument
                 (Yojson.Safe.to_string
                    (reject_iteration ~config state ~message)))
          else
            match state.status with
            | `Running -> ()
            | `Interrupted -> set_non_terminal_state state `Running
            | `Completed ->
                let message =
                  Printf.sprintf "Loop %s is already completed. Start a new loop to continue." id
                in
                raise
                  (Invalid_argument
                     (Yojson.Safe.to_string
                        (reject_iteration ~config state ~message)))
            | `Stopped ->
                let message =
                  Printf.sprintf "Loop %s is stopped and cannot resume. Start a new loop instead." id
                in
                raise
                  (Invalid_argument
                     (Yojson.Safe.to_string
                        (reject_iteration ~config state ~message)))
            | `Error ->
                let message =
                  Printf.sprintf "Loop %s is in error state and cannot iterate again." id
                in
                raise
                  (Invalid_argument
                     (Yojson.Safe.to_string
                        (reject_iteration ~config state ~message)))
        in
        if state.current_iteration >= state.profile.max_iterations then
          stop_for_reason config state ~reason:"max_iterations_reached"
            ~message:"Max iterations reached"
        else if Mdal.time_exceeded state state.profile then
          stop_for_reason config state ~reason:"time_limit_exceeded"
            ~message:"Time limit exceeded"
        else if Mdal.stagnation_exceeded state then
          stop_for_reason config state ~reason:"stagnation_limit_reached"
            ~message:"Stagnation limit reached"
        else begin
        let iter_start = Time_compat.now () in

        (* Measure current metric *)
        match Mdal.measure_metric state.profile.metric_fn with
        | Error e ->
          fail_loop config state ~reason:"metric_measurement_failed"
            ~message:(Printf.sprintf "Metric measurement failed: %s" e)
        | Ok metric_before ->
          (match run_worker_iteration ctx config state metric_before with
           | Error (Mdal_worker.Worker_unavailable msg) ->
               fail_loop config state ~reason:"worker_unavailable" ~message:msg
           | Error (Mdal_worker.Worker_failed msg) ->
               fail_loop config state ~reason:"worker_execution_failed" ~message:msg
           | Error (Mdal_worker.Output_unparseable msg) ->
               fail_loop config state ~reason:"worker_output_unparseable"
                 ~message:msg
           | Error (Mdal_worker.Evidence_missing missing) ->
               let message =
                 Printf.sprintf
                   "Strict MDAL worker produced no auditable tool evidence. Use at least one allowed tool before returning JSON."
               in
               let base_response =
                 interrupt_loop config state ~reason:"worker_evidence_missing"
                   ~message
               in
               assoc_with_fields base_response
                 [
                   ("worker_prompt_used", `String missing.prompt);
                   ("worker_raw_output",
                    `String (truncate_preview ~limit:320 missing.raw_output));
                   ("worker_model", `String missing.model_used);
                   ("tool_call_count", `Int missing.tool_call_count);
                   ("tool_names",
                    `List
                      (List.map (fun item -> `String item) missing.tool_names));
                   ("session_id", `String missing.session_id);
                 ]
           | Ok worker_run ->
               match Mdal.measure_metric state.profile.metric_fn with
               | Error e ->
                   let msg =
                     Printf.sprintf "Post-iteration measurement failed: %s" e
                   in
                   fail_loop config state ~reason:"post_measurement_failed"
                     ~message:msg
               | Ok metric_after ->
                   let elapsed_ms =
                     int_of_float ((Time_compat.now () -. iter_start) *. 1000.0)
                   in
                   let iter_num = state.current_iteration + 1 in
                   let delta = metric_after -. metric_before in

                   let record : Mdal.iteration_record = {
                     iteration = iter_num;
                     metric_before;
                     metric_after;
                     delta;
                     changes = worker_run.report.changes;
                     failed_attempts = worker_run.report.failed_attempts;
                     next_suggestion = worker_run.report.next_suggestion;
                     elapsed_ms;
                     cost_usd = worker_run.cost_usd;
                     evidence = Some worker_run.evidence;
                   } in

                   (* Update state *)
                   state.current_iteration <- iter_num;
                   state.history <- record :: state.history;
                   Mdal.update_stagnation state record;

                   (* Post iteration to board *)
                   (try
                      ignore (Board_dispatch.create_post
                                ~author:"mdal"
                                ~content:(Mdal.format_iter_post record)
                                ~post_kind:Board.System_post
                                ~meta_json:(`Assoc [ ("source", `String "mdal_iteration") ])
                                ~visibility:Board.Internal
                                ~ttl_hours:24
                                ~hearth:(Mdal.iter_hearth state.loop_id)
                                ())
                    with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Misc.warn "tool_mdal: iter board post failed: %s" (Printexc.to_string exn));

                   (* Broadcast via SSE *)
                   (try Sse.broadcast (`Assoc [
                      ("type", `String "mdal_iteration");
                      ("loop_id", `String state.loop_id);
                      ("iteration", `Int iter_num);
                      ("metric_before", `Float metric_before);
                      ("metric_after", `Float metric_after);
                      ("delta", `Float delta);
                    ]) with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Misc.warn "tool_mdal: iter SSE broadcast failed: %s" (Printexc.to_string exn));

                   (* Check if goal is met *)
                   let evaluation = Mdal.evaluate_iteration record in
                   let eval_str = match evaluation with
                     | `Improved -> "improved"
                     | `Flat -> "flat"
                     | `Regressed -> "regressed"
                   in
                   let goal_met =
                     let metric_fields =
                       if state.profile.goal.path = "metric" then
                         [("metric", `Float metric_after)]
                       else
                         [
                           ("metric", `Float metric_after);
                           (state.profile.goal.path, `Float metric_after);
                         ]
                     in
                     let result = `Assoc metric_fields in
                     Bounded.check_goal result state.profile.goal
                   in

                   if goal_met then begin
                     set_terminal_state state ~status:`Completed ~reason:"goal_met"
                       ~error_message:None;
                     persist_loop config state;
                     post_final_summary state;
                     emit_completed_event ~loop_id:state.loop_id
                       ~final_metric:metric_after ~iterations:iter_num;
                     assoc_with_fields (state_to_json ~config state)
                       [
                         ("goal_met", `Bool true);
                         ("iteration", iter_record_to_json record);
                         ("total_iterations", `Int iter_num);
                         ("final_metric", `Float metric_after);
                         ("assessment", `String eval_str);
                         ("assessment_basis", `String "measured_delta");
                         ("iteration_mode", `String "strict_worker");
                         ("worker_engine",
                          `String
                            (Mdal.worker_engine_to_string worker_run.evidence.engine));
                         ("worker_model", `String worker_run.evidence.model_used);
                         ("tool_call_count", `Int worker_run.evidence.tool_call_count);
                         ("tool_names",
                          `List
                            (List.map (fun item -> `String item)
                               worker_run.evidence.tool_names));
                         ("session_id", `String worker_run.evidence.session_id);
                       ]
                   end
                   else begin
                     set_non_terminal_state state `Running;
                     persist_loop config state;
                     let next_prompt = Mdal.render_worker_prompt
                         state.profile state.history metric_after in
                     assoc_with_fields (state_to_json ~config state)
                       [
                         ("goal_met", `Bool false);
                         ("iteration", iter_record_to_json record);
                         ("assessment", `String eval_str);
                         ("assessment_basis", `String "measured_delta");
                         ("remaining_iterations", `Int (state.profile.max_iterations - iter_num));
                         ("iteration_mode", `String "strict_worker");
                         ("worker_engine",
                          `String
                            (Mdal.worker_engine_to_string worker_run.evidence.engine));
                         ("worker_model", `String worker_run.evidence.model_used);
                         ("tool_call_count", `Int worker_run.evidence.tool_call_count);
                         ("tool_names",
                          `List
                            (List.map (fun item -> `String item)
                               worker_run.evidence.tool_names));
                         ("session_id", `String worker_run.evidence.session_id);
                         ("worker_prompt", `String next_prompt);
                         ("worker_prompt_used", `String worker_run.prompt);
                       ]
                   end)
        end)
  with
  | Invalid_argument body -> (
      try Yojson.Safe.from_string body with Yojson.Json_error _ -> `Assoc [ ("error", `String body) ])

let handle_stop (ctx : context) args =
  let loop_id = resolve_loop_id ctx args in
  let reason = args |> Yojson.Safe.Util.member "reason" |> Yojson.Safe.Util.to_string_option
               |> Option.value ~default:"manual stop" in
  match loop_id with
  | None -> `Assoc [("error", `String "No MDAL loop running")]
  | Some id -> (
    match require_config ctx with
    | Error msg -> `Assoc [ ("error", `String msg) ]
    | Ok config ->
    match find_loop ~config id with
    | None -> `Assoc [("error", `String (Printf.sprintf "Loop %s not found" id))]
    | Some state ->
      set_terminal_state state ~status:`Stopped ~reason ~error_message:None;
      persist_loop config state;
      post_final_summary state;

      (* Broadcast via SSE *)
      emit_stop_event state ~reason;

      assoc_with_fields (state_to_json ~config state)
        [
          ("reason", `String reason);
          ("total_iterations", `Int state.current_iteration);
          ("final_metric", `Float (current_metric_of_state state));
          ("total_delta", `Float (total_delta_of_state state));
          ("final_state", `String (Mdal.format_final_post state));
        ])

(* ================================================================ *)
(* MDAL Swarm handler                                               *)
(* ================================================================ *)

let handle_swarm_start (ctx : context) args =
  let open Yojson.Safe.Util in
  match ctx.clock, ctx.sw with
  | None, _ -> `Assoc [("error", `String "Clock not available (swarm requires Eio runtime)")]
  | _, None -> `Assoc [("error", `String "Switch not available (swarm requires Eio runtime)")]
  | Some clock, Some sw ->
    let swarm_id = Safe_ops.json_string "swarm_id" args in
    let title = Safe_ops.json_string ~default:swarm_id "title" args in
    let workers_json = args |> member "workers" |> to_list in
    match parse_all_workers workers_json with
    | Error e -> `Assoc [("error", `String e)]
    | Ok [] -> `Assoc [("error", `String "workers must not be empty")]
    | Ok workers ->
    let aggregate_strategy =
      Safe_ops.json_string ~default:"average" "aggregate_strategy" args
      |> parse_aggregate_strategy
    in
    let aggregate_goal_expr = Safe_ops.json_string "aggregate_goal_expr" args in
    let max_wall_time_sec = Safe_ops.json_float_opt "max_wall_time_sec" args in
    let config : Mdal_swarm.swarm_config = {
      swarm_id;
      title;
      workers;
      aggregate_strategy;
      aggregate_goal_expr;
      max_wall_time_sec;
    } in
    let result_ref = ref None in
    Hashtbl.replace active_swarms swarm_id result_ref;
    Eio.Fiber.fork_daemon ~sw (fun () ->
      let result = Mdal_swarm.run ~clock config in
      result_ref := Some result;
      `Stop_daemon
    );
    `Assoc [
      ("status", `String "started");
      ("swarm_id", `String swarm_id);
      ("worker_count", `Int (List.length workers));
    ]

let handle_swarm_status _ctx args =
  let open Yojson.Safe.Util in
  let swarm_id = args |> member "swarm_id" |> to_string in
  match Hashtbl.find_opt active_swarms swarm_id with
  | None -> `Assoc [("error", `String (Printf.sprintf "Unknown swarm: %s" swarm_id))]
  | Some result_ref ->
    match !result_ref with
    | None -> `Assoc [("status", `String "running"); ("swarm_id", `String swarm_id)]
    | Some result -> Mdal_swarm.result_to_json result

(* ================================================================ *)
(* Dispatch                                                         *)
(* ================================================================ *)

type result = bool * string

(** Dispatch an MDAL tool call (standard MCP pattern). *)
let dispatch (ctx : context) ~name ~args : result option =
  match name with
  | "masc_mdal_start" -> Some (wrap_result (handle_start ctx args))
  | "masc_mdal_status" -> Some (wrap_result (handle_status ctx args))
  | "masc_mdal_iterate" -> Some (wrap_result (handle_iterate ctx args))
  | "masc_mdal_stop" -> Some (wrap_result (handle_stop ctx args))
  | "masc_mdal_swarm_start" -> Some (wrap_result (handle_swarm_start ctx args))
  | "masc_mdal_swarm_status" -> Some (wrap_result (handle_swarm_status ctx args))
  | _ -> None
