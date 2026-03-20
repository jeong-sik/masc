(** Tool_mdal — Metric-Driven Agent Loop tool implementations. *)

include Tool_mdal_schemas


let assoc_with_fields json fields =
  match json with
  | `Assoc base -> `Assoc (base @ fields)
  | other -> other

let config_persistence_backend config =
  Mdal_store.persistence_backend config

let config_durability config =
  Mdal_store.durability config

let remember_loop (state : Mdal.loop_state) =
  Hashtbl.replace active_loops state.loop_id state;
  latest_loop_id := Some state.loop_id

let persist_loop config (state : Mdal.loop_state) =
  state.updated_at <- Time_compat.now ();
  Mdal_store.save_loop config state;
  Mdal_store.save_latest_loop_id config state.loop_id;
  remember_loop state

let resolve_loop_id (ctx : context) args =
  let open Yojson.Safe.Util in
  match args |> member "loop_id" |> to_string_option with
  | Some id -> Some id
  | None -> (
      match !latest_loop_id with
      | Some id -> Some id
      | None -> (
          match ctx.config with
          | Some config -> Mdal_store.load_latest_loop_id config
          | None -> None))

let iter_record_to_json (r : Mdal.iteration_record) : Yojson.Safe.t =
  let evidence_json =
    match r.evidence with
    | None -> `Null
    | Some evidence ->
        `Assoc
          [
            ("worker_engine", `String (Mdal.worker_engine_to_string evidence.engine));
            ("worker_model", `String evidence.model_used);
            ("tool_call_count", `Int evidence.tool_call_count);
            ("tool_names", `List (List.map (fun item -> `String item) evidence.tool_names));
            ("session_id", `String evidence.session_id);
            ("evidence_status", `String (Mdal.evidence_status_to_string evidence.status));
          ]
  in
  `Assoc [
    ("iteration", `Int r.iteration);
    ("metric_before", `Float r.metric_before);
    ("metric_after", `Float r.metric_after);
    ("delta", `Float r.delta);
    ("changes", `String r.changes);
    ("failed_attempts", `String r.failed_attempts);
    ("next_suggestion", `String r.next_suggestion);
    ("elapsed_ms", `Int r.elapsed_ms);
    ("cost_usd", match r.cost_usd with Some c -> `Float c | None -> `Null);
    ("evidence", evidence_json);
  ]

let runtime_worker_available (ctx : context) =
  match ctx.worker_runner with
  | Some _ -> true
  | None -> Mdal_worker.runtime_available ~sw:ctx.sw ~config:ctx.config

let truncate_preview ?(limit = 240) text =
  let trimmed = String.trim text in
  if String.length trimmed <= limit then
    trimmed
  else
    String.sub trimmed 0 limit ^ "..."

let missing_metric_message profile_name =
  let profile_hint =
    match profile_name with
    | "ssim" ->
        "Example: a script that compares a reference image and prints SSIM as a single float."
    | "coverage" ->
        "Example: a coverage command that prints one numeric percentage such as `make coverage-summary | ...`."
    | "lint" ->
        "Example: a lint command that prints one numeric error count."
    | "review" ->
        "Provide a deterministic review scoring command or evaluator that prints a single float."
    | "docs" ->
        "Provide a deterministic documentation coverage command or evaluator that prints a single float."
    | other ->
        Printf.sprintf "Provide metric_fn explicitly for profile `%s`." other
  in
  Printf.sprintf
    "Profile `%s` has no trustworthy built-in metric command in this workspace. Pass `metric_fn` explicitly. %s"
    profile_name profile_hint

let resolve_metric_fn ~profile_name ~base_profile args =
  let open Yojson.Safe.Util in
  match args |> member "metric_fn" |> to_string_option |> Option.map String.trim with
  | Some metric_fn when metric_fn <> "" -> Ok metric_fn
  | _ ->
      let inherited = String.trim base_profile.Mdal.metric_fn in
      if inherited <> "" then Ok inherited
      else Error (missing_metric_message profile_name)

let resolve_worker_model_arg args =
  match args |> Yojson.Safe.Util.member "worker_model"
        |> Yojson.Safe.Util.to_string_option with
  | Some value ->
      let trimmed = String.trim value in
      if trimmed = "" then None else Some trimmed
  | None -> None

let validate_strict_iterate_args args =
  let open Yojson.Safe.Util in
  let manual_fields =
    [ "changes"; "failed_attempts"; "next_suggestion" ]
    |> List.filter (fun field ->
           match args |> member field with
           | `Null -> false
           | _ -> true)
  in
  match manual_fields with
  | [] -> Ok ()
  | fields ->
      Error
        (Printf.sprintf
           "Strict MDAL does not accept manual iteration fields (%s). Start a new strict loop and let the worker produce auditable tool evidence."
           (String.concat ", " fields))

let current_metric_of_state (state : Mdal.loop_state) =
  Mdal.current_metric state

let total_delta_of_state (state : Mdal.loop_state) =
  Mdal.total_delta state

let hydrate_loaded_loop config (state : Mdal.loop_state) =
  match state.status with
  | `Running ->
      state.status <- `Interrupted;
      state.stop_reason <- Some "server_restart";
      state.error_message <- None;
      state.stopped_at <- None;
      persist_loop config state;
      state
  | _ ->
      remember_loop state;
      state

let find_loop ?config loop_id =
  match Hashtbl.find_opt active_loops loop_id with
  | Some state -> Some state
  | None -> (
      match config with
      | Some cfg -> (
          match Mdal_store.load_loop cfg loop_id with
          | Some state -> Some (hydrate_loaded_loop cfg state)
          | None -> None)
      | None -> None)

let list_loops ?config () =
  match config with
  | None ->
      Hashtbl.fold (fun _ state acc -> state :: acc) active_loops []
  | Some cfg ->
      let ids =
        Mdal_store.list_loop_ids cfg
        @ Hashtbl.fold (fun id _ acc -> id :: acc) active_loops []
        |> List.sort_uniq String.compare
      in
      List.filter_map (find_loop ~config:cfg) ids

let state_to_json ?config (state : Mdal.loop_state) =
  let persistence_backend, durability =
    match config with
    | Some cfg -> (config_persistence_backend cfg, config_durability cfg)
    | None -> ("memory", "memory_only")
  in
  let latest_evidence = Mdal.latest_evidence state in
  let latest_tool_call_count, latest_tool_names, latest_session_id, evidence_status =
    match latest_evidence with
    | Some evidence ->
        ( evidence.tool_call_count,
          evidence.tool_names,
          Some evidence.session_id,
          Some evidence.status )
    | None ->
        ( 0,
          [],
          None,
          Mdal.current_evidence_status state )
  in
  let stopped_at =
    match state.stopped_at with
    | Some ts -> `Float ts
    | None -> `Null
  in
  `Assoc
    [
      ("loop_id", `String state.loop_id);
      ("status", `String (Mdal.status_to_string state.status));
      ("strict_mode", `Bool state.strict_mode);
      ("error_message", match state.error_message with Some msg -> `String msg | None -> `Null);
      ("error_reason", match state.error_message with Some msg -> `String msg | None -> `Null);
      ("stop_reason", match state.stop_reason with Some reason -> `String reason | None -> `Null);
      ("profile", `String state.profile.name);
      ("current_iteration", `Int state.current_iteration);
      ("max_iterations", `Int state.profile.max_iterations);
      ("baseline_metric", `Float state.baseline_metric);
      ("current_metric", `Float (current_metric_of_state state));
      ("target", `String state.profile.target);
      ("stagnation_streak", `Int state.stagnation_streak);
      ("stagnation_limit", `Int state.profile.stagnation_count);
      ("elapsed_seconds", `Float (Time_compat.now () -. state.start_time));
      ("start_time", `Float state.start_time);
      ("updated_at", `Float state.updated_at);
      ("stopped_at", stopped_at);
      ("execution_mode", `String (Mdal.execution_mode_to_string state.execution_mode));
      ("worker_engine",
       match state.worker_engine with
       | Some engine -> `String (Mdal.worker_engine_to_string engine)
       | None -> `Null);
      ("worker_model",
       match state.worker_model with
       | Some model -> `String model
       | None -> `Null);
      ("evidence_policy", if state.strict_mode then `String "hard" else `String "legacy");
      ("latest_tool_call_count", `Int latest_tool_call_count);
      ("latest_tool_names", `List (List.map (fun item -> `String item) latest_tool_names));
      ("session_id",
       match latest_session_id with
       | Some value -> `String value
       | None -> `Null);
      ("evidence_status",
       match evidence_status with
       | Some status -> `String (Mdal.evidence_status_to_string status)
       | None -> `Null);
      ("durability", `String durability);
      ("persistence_backend", `String persistence_backend);
      ("recoverable", `Bool (Mdal.recoverable state));
      ("history", `List (List.map iter_record_to_json state.history));
    ]

let post_final_summary (state : Mdal.loop_state) =
  try
    ignore
      (Board_dispatch.create_post
         ~author:"mdal"
         ~content:(Mdal.format_final_post state)
         ~visibility:Board.Internal
         ~ttl_hours:24
         ~hearth:(Mdal.state_hearth state.loop_id)
         ())
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Log.Misc.warn "tool_mdal: final board post failed: %s" (Printexc.to_string exn)

let terminal_response ?config (state : Mdal.loop_state) ~reason ~error_message =
  assoc_with_fields (state_to_json ?config state)
    [
      ("error", `String error_message);
      ("reason", `String reason);
      ("total_iterations", `Int state.current_iteration);
      ("final_metric", `Float (current_metric_of_state state));
      ("total_delta", `Float (total_delta_of_state state));
      ("final_state", `String (Mdal.format_final_post state));
    ]

let emit_stop_event (state : Mdal.loop_state) ~reason =
  let final_metric = current_metric_of_state state in
  try
    Sse.broadcast
      (`Assoc
        [
          ("type", `String "mdal_stopped");
          ("loop_id", `String state.loop_id);
          ("status", `String (Mdal.status_to_string state.status));
          ("reason", `String reason);
          ("final_metric", `Float final_metric);
          ("iterations", `Int state.current_iteration);
        ])
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Log.Misc.warn "tool_mdal: emit_stop_event SSE failed: %s" (Printexc.to_string exn)

let emit_completed_event ~loop_id ~final_metric ~iterations =
  try
    Sse.broadcast
      (`Assoc
        [
          ("type", `String "mdal_completed");
          ("loop_id", `String loop_id);
          ("final_metric", `Float final_metric);
          ("iterations", `Int iterations);
        ])
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Log.Misc.warn "tool_mdal: emit_completed_event SSE failed: %s" (Printexc.to_string exn)

let run_worker_iteration (ctx : context) (config : Room.config)
    (state : Mdal.loop_state) current_metric =
  match ctx.worker_runner with
  | Some runner -> runner ~config state ~current_metric
  | None -> (
      match ctx.sw with
      | None ->
          Error
            (Mdal_worker.Worker_unavailable
               "Strict MDAL worker runtime requires an active Eio switch.")
      | Some sw -> Mdal_worker.run ~sw ~config state ~current_metric)

let require_config ctx =
  match ctx.config with
  | Some config -> Ok config
  | None -> Error "MDAL requires room config for backend-backed persistence"

let set_non_terminal_state (state : Mdal.loop_state) status =
  state.status <- status;
  state.error_message <- None;
  state.stop_reason <- None;
  state.stopped_at <- None

let set_interrupted_state (state : Mdal.loop_state) ~reason ~error_message =
  let now = Time_compat.now () in
  state.status <- `Interrupted;
  state.stop_reason <- Some reason;
  state.error_message <- error_message;
  state.updated_at <- now;
  state.stopped_at <- Some now

let set_terminal_state (state : Mdal.loop_state) ~status ~reason ~error_message =
  let now = Time_compat.now () in
  state.status <- status;
  state.stop_reason <- Some reason;
  state.error_message <- error_message;
  state.updated_at <- now;
  state.stopped_at <- Some now

let stop_for_reason config (state : Mdal.loop_state) ~reason ~message =
  set_terminal_state state ~status:`Stopped ~reason ~error_message:None;
  persist_loop config state;
  post_final_summary state;
  emit_stop_event state ~reason;
  terminal_response ~config state ~reason ~error_message:message

let fail_loop config (state : Mdal.loop_state) ~reason ~message =
  set_terminal_state state ~status:`Error ~reason ~error_message:(Some message);
  persist_loop config state;
  post_final_summary state;
  emit_stop_event state ~reason;
  terminal_response ~config state ~reason ~error_message:message

let interrupt_loop config (state : Mdal.loop_state) ~reason ~message =
  set_interrupted_state state ~reason ~error_message:(Some message);
  persist_loop config state;
  post_final_summary state;
  emit_stop_event state ~reason;
  terminal_response ~config state ~reason ~error_message:message

let reject_iteration ?config (state : Mdal.loop_state) ~message =
  assoc_with_fields (state_to_json ?config state) [ ("error", `String message) ]

(* ================================================================ *)
(* Handlers                                                         *)
(* ================================================================ *)

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
            agent = Safe_ops.json_string ~default:"claude" "agent" args;
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
        Mdal_worker.resolve_model_spec ~agent:profile.agent
          ~worker_model:worker_model_arg
      with
      | Ok (_spec, label) -> label
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

let parse_aggregate_strategy s =
  match String.lowercase_ascii s with
  | "all" -> Mdal_swarm.All
  | "any" -> Mdal_swarm.Any
  | _ -> Mdal_swarm.Average

let parse_worker_spec (json : Yojson.Safe.t) : (Mdal_swarm.worker_spec, string) result =
  try
    let open Yojson.Safe.Util in
    Ok {
      worker_id = json |> member "worker_id" |> to_string;
      label = json |> member "label" |> to_string_option |> Option.value ~default:"";
      metric_fn = json |> member "metric_fn" |> to_string;
      goal_expr = json |> member "goal_expr" |> to_string;
      agent = json |> member "agent" |> to_string_option |> Option.value ~default:"default";
      max_iterations = json |> member "max_iterations" |> to_int_option |> Option.value ~default:10;
    }
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Error (Printf.sprintf "Invalid worker spec: %s" (Printexc.to_string exn))

let parse_all_workers workers_json =
  let rec aux acc = function
    | [] -> Ok (List.rev acc)
    | json :: rest ->
        match parse_worker_spec json with
        | Ok w -> aux (w :: acc) rest
        | Error e -> Error e
  in
  aux [] workers_json

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
