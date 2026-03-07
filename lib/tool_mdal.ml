(** Tool_mdal — MCP tool schemas for the Metric-Driven Agent Loop.

    Provides 4 MCP tools:
    - masc_mdal_start    — Start a metric-driven improvement loop
    - masc_mdal_status   — Get current loop state and iteration history
    - masc_mdal_iterate  — Execute one improvement iteration manually
    - masc_mdal_stop     — Stop a running loop

    @since 2.70.0 *)

(* ================================================================ *)
(* Tool Schemas                                                     *)
(* ================================================================ *)

let schemas : Types.tool_schema list = [
  {
    name = "masc_mdal_start";
    description = "Start a metric-driven agent loop (MDAL). \
The loop repeatedly measures a metric, spawns a worker to improve it, \
and tracks progress until the goal is met or limits are reached. \
Use a built-in profile (ssim, coverage, lint, review, docs) or provide custom settings.";
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
          ("description", `String "Shell command that outputs a single float (the metric value). \
Required for custom profiles, optional override for built-in profiles.");
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
          ("description", `String "Optional reference file or directory for comparison");
        ]);
        ("agent", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent to spawn for each iteration (default: 'claude')");
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
          ("description", `String "Domain-specific hints for the worker agent");
        ]);
        ("tools_allow", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Tools the worker may use (empty = all allowed)");
        ]);
        ("tools_deny", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Tools the worker must NOT use");
        ]);
      ]);
      ("required", `List [`String "profile"]);
    ];
  };

  {
    name = "masc_mdal_status";
    description = "Get the current status of a running MDAL loop. \
Returns: loop_id, status, iteration count, metric history, stagnation info.";
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
    description = "Execute one improvement iteration of an MDAL loop. \
Measures the metric, reports the current value, and optionally applies changes. \
Use this for manual step-by-step control instead of automatic looping.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("loop_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Loop ID (optional, uses latest if omitted)");
        ]);
        ("changes", `Assoc [
          ("type", `String "string");
          ("description", `String "Description of changes made in this iteration");
        ]);
        ("failed_attempts", `Assoc [
          ("type", `String "string");
          ("description", `String "What was tried but didn't work");
        ]);
        ("next_suggestion", `Assoc [
          ("type", `String "string");
          ("description", `String "Suggestion for the next iteration");
        ]);
      ]);
    ];
  };

  {
    name = "masc_mdal_stop";
    description = "Stop a running MDAL loop. \
Records the final state and posts a summary to the board.";
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
]

(* ================================================================ *)
(* Context & State                                                  *)
(* ================================================================ *)

type context = {
  agent_name : string;
}

(** Global registry of active MDAL loops. *)
let active_loops : (string, Mdal.loop_state) Hashtbl.t =
  Hashtbl.create 4

let latest_loop_id : string option ref = ref None

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

let resolve_loop_id args =
  let open Yojson.Safe.Util in
  match args |> member "loop_id" |> to_string_option with
  | Some id -> Some id
  | None -> !latest_loop_id

let iter_record_to_json (r : Mdal.iteration_record) : Yojson.Safe.t =
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
  ]

(* ================================================================ *)
(* Handlers                                                         *)
(* ================================================================ *)

let handle_start (_ctx : context) args =
  let open Yojson.Safe.Util in
  let profile_name = args |> member "profile" |> to_string in

  (* Build profile: start from built-in or create custom *)
  let base_profile =
    if profile_name = "custom" then
      let metric_fn = args |> member "metric_fn" |> to_string_option in
      let goal_str = args |> member "goal" |> to_string_option in
      match metric_fn, goal_str with
      | Some mfn, Some gs ->
        let goal = Mdal.parse_goal gs in
        { Mdal.name = "custom";
          metric_fn = mfn;
          goal;
          target = (args |> member "target" |> to_string_option
                    |> Option.value ~default:gs);
          reference = args |> member "reference" |> to_string_option;
          agent = (args |> member "agent" |> to_string_option
                   |> Option.value ~default:"claude");
          max_iterations = (args |> member "max_iterations" |> to_int_option
                            |> Option.value ~default:20);
          max_time_seconds = args |> member "max_time_seconds" |> to_number_option;
          stagnation_threshold = 0.005;
          stagnation_count = 3;
          heuristics = (args |> member "heuristics" |> to_string_option
                        |> Option.value ~default:"");
          tools_allow = (args |> member "tools_allow" |> to_option (fun j ->
            to_list j |> List.map to_string) |> Option.value ~default:[]);
          tools_deny = (args |> member "tools_deny" |> to_option (fun j ->
            to_list j |> List.map to_string) |> Option.value ~default:[]);
        }
      | None, _ ->
        invalid_arg "Custom profile requires 'metric_fn'"
      | _, None ->
        invalid_arg "Custom profile requires 'goal'"
    else
      Mdal.builtin_profile profile_name
  in

  (* Apply optional overrides *)
  let profile = {
    base_profile with
    metric_fn = (args |> member "metric_fn" |> to_string_option
                 |> Option.value ~default:base_profile.metric_fn);
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

  (* Measure baseline metric *)
  match Mdal.measure_metric profile.metric_fn with
  | Error e ->
    `Assoc [("error", `String (Printf.sprintf "Failed to measure baseline: %s" e))]
  | Ok baseline ->
    let loop_id = Mdal.generate_loop_id () in

    let state : Mdal.loop_state = {
      loop_id;
      profile;
      status = `Running;
      current_iteration = 0;
      history = [];
      stagnation_streak = 0;
      baseline_metric = baseline;
      start_time = Time_compat.now ();
    } in
    Hashtbl.replace active_loops loop_id state;
    latest_loop_id := Some loop_id;

    (* Broadcast via SSE *)
    (try Sse.broadcast (`Assoc [
       ("type", `String "mdal_started");
       ("loop_id", `String loop_id);
       ("profile", `String profile.name);
       ("baseline", `Float baseline);
       ("target", `String profile.target);
     ]) with _ -> ());

    `Assoc [
      ("loop_id", `String loop_id);
      ("status", `String "running");
      ("profile", `String profile.name);
      ("baseline_metric", `Float baseline);
      ("target", `String profile.target);
      ("max_iterations", `Int profile.max_iterations);
      ("worker_prompt", `String (Mdal.render_worker_prompt profile [] baseline));
    ]

let handle_status args =
  let loop_id = resolve_loop_id args in
  match loop_id with
  | None -> `Assoc [("error", `String "No MDAL loop running")]
  | Some id ->
    match Hashtbl.find_opt active_loops id with
    | None -> `Assoc [("error", `String (Printf.sprintf "Loop %s not found" id))]
    | Some state ->
      let status_str = match state.status with
        | `Running -> "running"
        | `Completed -> "completed"
        | `Stopped -> "stopped"
        | `Error e -> Printf.sprintf "error: %s" e
      in
      let elapsed = Time_compat.now () -. state.start_time in
      let current_metric = match state.history with
        | r :: _ -> r.Mdal.metric_after
        | [] -> state.baseline_metric
      in
      `Assoc [
        ("loop_id", `String state.loop_id);
        ("status", `String status_str);
        ("profile", `String state.profile.name);
        ("iteration", `Int state.current_iteration);
        ("max_iterations", `Int state.profile.max_iterations);
        ("baseline_metric", `Float state.baseline_metric);
        ("current_metric", `Float current_metric);
        ("target", `String state.profile.target);
        ("stagnation_streak", `Int state.stagnation_streak);
        ("stagnation_limit", `Int state.profile.stagnation_count);
        ("elapsed_seconds", `Float elapsed);
        ("history", `List (List.map iter_record_to_json state.history));
      ]

let handle_iterate args =
  let open Yojson.Safe.Util in
  let loop_id = resolve_loop_id args in
  match loop_id with
  | None -> `Assoc [("error", `String "No MDAL loop running")]
  | Some id ->
    match Hashtbl.find_opt active_loops id with
    | None -> `Assoc [("error", `String (Printf.sprintf "Loop %s not found" id))]
    | Some state ->
      (* Check if loop is still running *)
      (match state.status with
       | `Running -> ()
       | `Completed -> ()  (* Allow iterate on completed for re-check *)
       | `Stopped ->
         state.status <- `Running  (* Resume *)
       | `Error _ -> ());

      (* Check limits *)
      if state.current_iteration >= state.profile.max_iterations then begin
        state.status <- `Completed;
        `Assoc [("error", `String "Max iterations reached");
                ("final_state", `String (Mdal.format_final_post state))]
      end
      else if Mdal.time_exceeded state state.profile then begin
        state.status <- `Completed;
        `Assoc [("error", `String "Time limit exceeded");
                ("final_state", `String (Mdal.format_final_post state))]
      end
      else if Mdal.stagnation_exceeded state then begin
        state.status <- `Completed;
        `Assoc [("error", `String "Stagnation limit reached");
                ("final_state", `String (Mdal.format_final_post state))]
      end
      else begin
        let iter_start = Time_compat.now () in

        (* Measure current metric *)
        match Mdal.measure_metric state.profile.metric_fn with
        | Error e ->
          `Assoc [("error", `String (Printf.sprintf "Metric measurement failed: %s" e))]
        | Ok metric_before ->
          let changes = args |> member "changes" |> to_string_option
                        |> Option.value ~default:"" in
          let failed_attempts = args |> member "failed_attempts" |> to_string_option
                                |> Option.value ~default:"" in
          let next_suggestion = args |> member "next_suggestion" |> to_string_option
                                |> Option.value ~default:"" in

          (* Re-measure after changes (if any were reported) *)
          let metric_after =
            if changes <> "" then
              match Mdal.measure_metric state.profile.metric_fn with
              | Ok v -> v
              | Error _ -> metric_before
            else
              metric_before
          in

          let elapsed_ms = int_of_float ((Time_compat.now () -. iter_start) *. 1000.0) in
          let iter_num = state.current_iteration + 1 in
          let delta = metric_after -. metric_before in

          let record : Mdal.iteration_record = {
            iteration = iter_num;
            metric_before;
            metric_after;
            delta;
            changes;
            failed_attempts;
            next_suggestion;
            elapsed_ms;
            cost_usd = None;
          } in

          (* Update state *)
          state.current_iteration <- iter_num;
          state.history <- record :: state.history;
          Mdal.update_stagnation state record;

          (* Broadcast iteration via SSE (no Board post — telemetry, not announcement) *)
          (try Sse.broadcast (`Assoc [
             ("type", `String "mdal_iteration");
             ("loop_id", `String state.loop_id);
             ("iteration", `Int iter_num);
             ("metric_before", `Float metric_before);
             ("metric_after", `Float metric_after);
             ("delta", `Float delta);
           ]) with _ -> ());

          (* Check if goal is met *)
          let goal_met =
            let result = `Assoc [("metric", `Float metric_after)] in
            Bounded.check_goal result state.profile.goal
          in

          if goal_met then begin
            state.status <- `Completed;
            (* Post concise final result to Board (signal, not telemetry) *)
            (try
               ignore (Board_dispatch.create_post
                         ~author:"mdal"
                         ~content:(Mdal.format_final_board state)
                         ~hearth:(Mdal.state_hearth state.loop_id)
                         ())
             with _ -> ());
            `Assoc [
              ("loop_id", `String state.loop_id);
              ("status", `String "completed");
              ("goal_met", `Bool true);
              ("iteration", iter_record_to_json record);
              ("total_iterations", `Int iter_num);
              ("final_metric", `Float metric_after);
              ("baseline_metric", `Float state.baseline_metric);
            ]
          end
          else begin
            let evaluation = Mdal.evaluate_iteration record in
            let eval_str = match evaluation with
              | `Continue_same_strategy -> "continue_same_strategy"
              | `Switch_area -> "switch_area"
              | `Revert_and_switch -> "revert_and_switch"
              | `Stagnation -> "stagnation"
            in
            let next_prompt = Mdal.render_worker_prompt
                state.profile state.history metric_after in
            `Assoc [
              ("loop_id", `String state.loop_id);
              ("status", `String "running");
              ("goal_met", `Bool false);
              ("iteration", iter_record_to_json record);
              ("evaluation", `String eval_str);
              ("stagnation_streak", `Int state.stagnation_streak);
              ("remaining_iterations", `Int (state.profile.max_iterations - iter_num));
              ("worker_prompt", `String next_prompt);
            ]
          end
      end

let handle_stop args =
  let open Yojson.Safe.Util in
  let loop_id = resolve_loop_id args in
  let reason = args |> member "reason" |> to_string_option
               |> Option.value ~default:"manual stop" in
  match loop_id with
  | None -> `Assoc [("error", `String "No MDAL loop running")]
  | Some id ->
    match Hashtbl.find_opt active_loops id with
    | None -> `Assoc [("error", `String (Printf.sprintf "Loop %s not found" id))]
    | Some state ->
      state.status <- `Stopped;

      (* Post concise final result to Board *)
      (try
         ignore (Board_dispatch.create_post
                   ~author:"mdal"
                   ~content:(Mdal.format_final_board state)
                   ~hearth:(Mdal.state_hearth state.loop_id)
                   ())
       with _ -> ());

      (* Broadcast via SSE *)
      (try Sse.broadcast (`Assoc [
         ("type", `String "mdal_stopped");
         ("loop_id", `String id);
         ("reason", `String reason);
       ]) with _ -> ());

      let final_metric = match state.history with
        | r :: _ -> r.Mdal.metric_after
        | [] -> state.baseline_metric
      in
      `Assoc [
        ("loop_id", `String id);
        ("status", `String "stopped");
        ("reason", `String reason);
        ("total_iterations", `Int state.current_iteration);
        ("baseline_metric", `Float state.baseline_metric);
        ("final_metric", `Float final_metric);
        ("total_delta", `Float (final_metric -. state.baseline_metric));
        ("elapsed_seconds", `Float (Time_compat.now () -. state.start_time));
        ("final_state", `String (Mdal.format_final_post state));
      ]

(* ================================================================ *)
(* Dispatch                                                         *)
(* ================================================================ *)

type result = bool * string

(** Dispatch an MDAL tool call (standard MCP pattern). *)
let dispatch (ctx : context) ~name ~args : result option =
  match name with
  | "masc_mdal_start" -> Some (wrap_result (handle_start ctx args))
  | "masc_mdal_status" -> Some (wrap_result (handle_status args))
  | "masc_mdal_iterate" -> Some (wrap_result (handle_iterate args))
  | "masc_mdal_stop" -> Some (wrap_result (handle_stop args))
  | _ -> None
