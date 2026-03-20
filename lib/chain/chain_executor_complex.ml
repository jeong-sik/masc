(** Chain Executor - Complex nodes (cascade, goal-driven, feedback loop, stream merge) *)

include Chain_executor_leaf
open Chain_types

let execute_cascade ctx ~sw ~clock ~(exec_fn : exec_fn) ~(execute_node : execute_node_fn) ~tool_exec (node : node)
    tiers ~confidence_prompt max_escalations context_mode task_hint =
  record_start ctx node.id ~node_type:"cascade";
  let start = Time_compat.now () in
  let sorted_tiers = List.sort (fun a b -> compare a.Chain_types.tier_index b.Chain_types.tier_index) tiers in
  let confidence_system = build_confidence_system_prompt ~confidence_prompt task_hint in
  let rec try_tier remaining escalations hard_failures prev_context =
    match remaining with
    | [] ->
      (* All tiers exhausted -- return last tier's output or error *)
      let last_output = match prev_context with Some c -> c | None -> "All cascade tiers exhausted" in
      Hashtbl.replace ctx.outputs "cascade_tier" "exhausted";
      Hashtbl.replace ctx.outputs "cascade_escalations" (string_of_int escalations);
      Hashtbl.replace ctx.outputs "cascade_hard_failures" (string_of_int hard_failures);
      Chain_stats.track_cascade ~resolved_tier:(List.length sorted_tiers - 1) ~escalations ~hard_failures;
      let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
      record_complete ctx node.id ~duration_ms ~success:true ~node_type:"cascade";
      store_node_output ctx node last_output;
      Ok last_output
    | tier :: rest ->
      if escalations >= max_escalations then begin
        let output = match prev_context with Some c -> c | None -> "Max escalations reached" in
        Hashtbl.replace ctx.outputs "cascade_tier" (string_of_int tier.Chain_types.tier_index);
        Hashtbl.replace ctx.outputs "cascade_escalations" (string_of_int escalations);
        Hashtbl.replace ctx.outputs "cascade_hard_failures" (string_of_int hard_failures);
        Chain_stats.track_cascade ~resolved_tier:tier.tier_index ~escalations ~hard_failures;
        let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
        record_complete ctx node.id ~duration_ms ~success:true ~node_type:"cascade";
        store_node_output ctx node output;
        Ok output
      end else begin
        (* Inject confidence prompt into tier's MODEL system instruction *)
        let tier_node = match tier.tier_node.node_type with
          | Model model_config ->
            let augmented_system = match model_config.system with
              | Some s -> Some (s ^ "\n\n" ^ confidence_system)
              | None -> Some confidence_system
            in
            { tier.tier_node with node_type = Model { model_config with system = augmented_system } }
          | _ -> tier.tier_node
        in
        (* Add context from previous tier if applicable *)
        let tier_node = match context_mode, prev_context with
          | Chain_types.CM_None, _ | _, None -> tier_node
          | CM_Summary, Some prev ->
            let summary = summarize_for_context prev in
            (match tier_node.node_type with
             | Model model_config ->
               let new_prompt = Printf.sprintf "Previous attempt (summarized): %s\n\n%s" summary model_config.prompt in
               { tier_node with node_type = Model { model_config with prompt = new_prompt } }
             | _ -> tier_node)
          | CM_Full, Some prev ->
            (match tier_node.node_type with
             | Model model_config ->
               let new_prompt = Printf.sprintf "Previous attempt (full): %s\n\n%s" prev model_config.prompt in
               { tier_node with node_type = Model { model_config with prompt = new_prompt } }
             | _ -> tier_node)
        in
        try
          match execute_node ctx ~sw ~clock ~exec_fn ~tool_exec tier_node with
          | Ok raw_output ->
            let (confidence, cleaned) = parse_confidence_from_output raw_output in
            let score = Chain_types.confidence_to_float confidence in
            if score >= tier.confidence_threshold then begin
              Hashtbl.replace ctx.outputs "cascade_tier" (string_of_int tier.tier_index);
              Hashtbl.replace ctx.outputs "cascade_escalations" (string_of_int escalations);
              Hashtbl.replace ctx.outputs "cascade_hard_failures" (string_of_int hard_failures);
              Chain_stats.track_cascade ~resolved_tier:tier.tier_index ~escalations ~hard_failures;
              let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
              record_complete ctx node.id ~duration_ms ~success:true ~node_type:"cascade";
              store_node_output ctx node cleaned;
              Ok cleaned
            end else
              try_tier rest (escalations + 1) hard_failures (Some cleaned)
          | Error msg ->
            record_error ctx node.id msg;
            try_tier rest escalations (hard_failures + 1) prev_context
        with
        | Out_of_memory | Stack_overflow | Sys.Break as exn -> raise exn
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
          record_error ctx node.id (Printexc.to_string exn);
          try_tier rest escalations (hard_failures + 1) prev_context
      end
  in
  try_tier sorted_tiers 0 0 None

(** Execute Monte Carlo Tree Search node *)


let execute_goal_driven ctx ~sw ~clock ~(exec_fn : exec_fn) ~(execute_node : execute_node_fn) ~tool_exec (parent : node)
    ~goal_metric ~goal_operator ~goal_value ~action_node ~measure_func
    ~max_iterations ~strategy_hints ~conversational ~relay_models : (string, string) result =
  record_start ctx parent.id;
  let start = Time_compat.now () in

  (* Initialize conversation context if conversational mode is enabled *)
  let prev_conversation = ctx.conversation in
  (if conversational then
     let models = if relay_models = [] then ["gemini"; "claude"; "codex"] else relay_models in
     ctx.conversation <- Some (make_conversation_ctx ~models ()));

  (* Get strategy hint based on current progress *)
  let get_strategy_hint current_value =
    (* strategy_hints format: [("below_50", "fast"), ("above_50", "accurate")] *)
    let pct = (current_value /. goal_value) *. 100.0 in
    List.find_opt (fun (condition, _) ->
      match String.split_on_char '_' condition with
      | ["below"; n] -> (try pct < float_of_string n with Failure _ -> false)
      | ["above"; n] -> (try pct >= float_of_string n with Failure _ -> false)
      | _ -> false
    ) strategy_hints
    |> Option.map snd
  in

  (* Measure metric from output using measure_func *)
  let measure output =
    match measure_func with
    | "parse_float" | "parse_json" ->
        (* Direct float parsing from output *)
        (try Some (float_of_string (String.trim output))
         with Failure _ ->
           (* Try JSON extraction *)
           try
             let json = Yojson.Safe.from_string output in
             let open Yojson.Safe.Util in
             Some (json |> member goal_metric |> to_float)
           with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None)
    | "exec_test" ->
        (* For test execution: extract coverage/pass rate from output *)
        (* Expected format: "coverage: 0.85" or JSON with metric field *)
        let regex = Str.regexp (goal_metric ^ "[: ]+\\([0-9.]+\\)") in
        (try
          let _ = Str.search_forward regex output 0 in
          Some (float_of_string (Str.matched_group 1 output))
        with Not_found ->
          try Some (float_of_string (String.trim output))
          with Failure _ -> None)
    | "call_api" ->
        (* For API calls: expect JSON response with metric *)
        (try
          let json = Yojson.Safe.from_string output in
          let open Yojson.Safe.Util in
          Some (json |> member goal_metric |> to_float)
        with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None)
    | "model_judge" ->
        (* Use MODEL to assess the metric *)
        let prompt = Printf.sprintf
          "Evaluate the following output for '%s' metric. Return ONLY a number between 0.0 and 1.0:\n\n%s"
          goal_metric output
        in
        let result = exec_fn ~model:Env_config_runtime.Chain.judge_model ?system:None ~prompt:prompt ?tools:None () in
        (match result with
         | Ok score_str ->
             (try Some (float_of_string (String.trim score_str))
              with Failure _ -> None)
         | Error _ -> None)
    | _ ->
        (* Default: try to extract any float *)
        (try Some (float_of_string (String.trim output))
         with Failure _ -> None)
  in

  let rec iterate iteration last_value =
    if iteration > max_iterations then begin
      ctx.iteration_ctx <- None;  (* Clear iteration context on completion *)
      let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
      record_complete ctx parent.id ~duration_ms ~success:false;
      Error (Printf.sprintf "Goal not achieved after %d iterations (last value: %.2f, target: %.2f)"
               max_iterations last_value goal_value)
    end else begin
      (* Get current strategy hint *)
      let current_strategy = get_strategy_hint last_value in

      (* Calculate progress toward goal *)
      let progress = last_value /. (max 0.001 goal_value) in

      (* Set iteration context for variable substitution in prompts *)
      ctx.iteration_ctx <- Some {
        iteration;
        max_iterations;
        progress;
        last_value;
        goal_value;
        strategy = current_strategy;
      };

      (* Execute the action node *)
      match execute_node ctx ~sw ~clock ~exec_fn ~tool_exec action_node with
      | Error msg ->
          let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
          record_complete ctx parent.id ~duration_ms ~success:false;
          Error (Printf.sprintf "Iteration %d failed: %s" iteration msg)
      | Ok output ->
          (* Update conversation context with this iteration's output when not a direct MODEL node *)
          let should_record =
            match action_node.node_type with
            | Model _ -> false
            | _ -> true
          in
          (match ctx.conversation, should_record with
           | Some conv, true ->
               add_message conv ~role:"assistant" ~content:output ~iteration ~model:conv.current_model;
               maybe_summarize_and_rotate ~exec_fn conv
           | _ -> ());

          (* Measure the metric *)
          (match measure output with
           | None ->
               (* Can't measure, keep trying with same last_value *)
               iterate (iteration + 1) last_value
           | Some v ->
               (* Check if goal is met *)
               let goal_met = match goal_operator with
                 | Gt -> v > goal_value
                 | Gte -> v >= goal_value
                 | Lt -> v < goal_value
                 | Lte -> v <= goal_value
                 | Eq -> abs_float (v -. goal_value) < 0.001
                 | Neq -> abs_float (v -. goal_value) >= 0.001
               in
               if goal_met then begin
                 ctx.iteration_ctx <- None;  (* Clear iteration context on completion *)
                 ctx.conversation <- None;   (* Clear conversation context on completion *)
                 let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
                 record_complete ctx parent.id ~duration_ms ~success:true;
                 store_node_output ctx parent output;
                 Ok output
               end else
                 iterate (iteration + 1) v)
    end
  in
  let result = iterate 1 0.0 in
  ctx.conversation <- prev_conversation;
  result

(** Execute evaluator node - score candidates and select based on strategy *)


let execute_feedback_loop ctx ~sw ~clock ~(exec_fn : exec_fn) ~(execute_node : execute_node_fn) ~tool_exec (parent : node)
    ~generator ~(evaluator_config : Chain_types.evaluator_config)
    ~improver_prompt ~max_iterations ~score_threshold ~score_operator
    ~conversational ~relay_models : (string, string) result =
  record_start ctx parent.id;
  let start = Time_compat.now () in
  let prev_conversation = ctx.conversation in
  (if conversational then
     let models = if relay_models = [] then ["gemini"; "claude"; "codex"] else relay_models in
     ctx.conversation <- Some (make_conversation_ctx ~models ()));

  (* Helper: Check if score passes threshold using operator *)
  let passes_threshold score =
    match score_operator with
    | Chain_types.Gt -> score > score_threshold
    | Chain_types.Gte -> score >= score_threshold
    | Chain_types.Lt -> score < score_threshold
    | Chain_types.Lte -> score <= score_threshold
    | Chain_types.Eq -> abs_float (score -. score_threshold) < 0.001
    | Chain_types.Neq -> abs_float (score -. score_threshold) >= 0.001
  in

  (* Helper: Format operator for error messages *)
  let op_str = match score_operator with
    | Chain_types.Gt -> ">" | Chain_types.Gte -> ">=" | Chain_types.Lt -> "<"
    | Chain_types.Lte -> "<=" | Chain_types.Eq -> "=" | Chain_types.Neq -> "!="
  in

  (* Helper: Score output using evaluator_config.scoring_func *)
  let score_output output =
    match evaluator_config.scoring_func with
    | "model_judge" ->
        let prompt = match evaluator_config.scoring_prompt with
          | Some p -> Printf.sprintf "%s\n\nOutput to evaluate:\n%s\n\nRespond with ONLY a number between 0.0 and 1.0" p output
          | None -> Printf.sprintf "Score this output from 0.0 to 1.0 for quality and correctness:\n\n%s\n\nRespond with ONLY a number between 0.0 and 1.0" output
        in
        (match exec_fn ~model:Env_config_runtime.Chain.judge_model ?system:None ~prompt ?tools:None () with
         | Ok score_str ->
             let cleaned = String.trim score_str in
             (try min 1.0 (max 0.0 (float_of_string cleaned))
              with Failure _ ->
                let regex = Str.regexp "[0-9]+\\.[0-9]+" in
                try
                  let _ = Str.search_forward regex cleaned 0 in
                  min 1.0 (max 0.0 (float_of_string (Str.matched_string cleaned)))
                with Not_found | Failure _ -> 0.5)
         | Error _ -> 0.5)
    | "regex_match" ->
        float_of_int (String.length output) /. 1000.0
    | "json_schema" ->
        (try
          let json = Yojson.Safe.from_string output in
          let depth = ref 0 in
          let rec count_depth = function
            | `Assoc fields -> incr depth; List.iter (fun (_, v) -> count_depth v) fields
            | `List items -> incr depth; List.iter count_depth items
            | _ -> ()
          in
          count_depth json;
          min 1.0 (0.5 +. (float_of_int !depth *. 0.1))
        with Yojson.Json_error _ -> 0.0)
    | _ ->
        (try
          let json = Yojson.Safe.from_string output in
          let open Yojson.Safe.Util in
          json |> member "score" |> to_float
        with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> 0.5)
  in

  (* Helper: Generate feedback for improvement *)
  let generate_feedback output score =
    let prompt = Printf.sprintf
      "The following output scored %.2f out of 1.0 for quality. Provide specific, actionable feedback on how to improve it:\n\n%s\n\nProvide 2-3 concrete suggestions for improvement:"
      score output
    in
    match exec_fn ~model:Env_config_runtime.Chain.judge_model ?system:None ~prompt ?tools:None () with
    | Ok feedback -> feedback
    | Error _ -> "Please improve the quality and accuracy of the output."
  in

  (* Helper: Substitute variables in improver_prompt *)
  let substitute_prompt template ~score ~feedback ~previous_output =
    template
    |> Str.global_replace (Str.regexp "{{score}}") (Printf.sprintf "%.2f" score)
    |> Str.global_replace (Str.regexp "{{feedback}}") feedback
    |> Str.global_replace (Str.regexp "{{previous_output}}") previous_output
  in

  (* Create a mutable copy of the generator for prompt updates *)
  let current_generator = ref generator in

  let rec iterate iteration =
    if iteration > max_iterations then begin
      let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
      record_complete ctx parent.id ~duration_ms ~success:false;
      Error (Printf.sprintf "FeedbackLoop: Max iterations (%d) reached without meeting threshold %s%.2f"
               max_iterations op_str score_threshold)
    end else begin
      (* Execute current generator *)
      match execute_node ctx ~sw ~clock ~exec_fn ~tool_exec !current_generator with
      | Error msg ->
          let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
          record_complete ctx parent.id ~duration_ms ~success:false;
          Error (Printf.sprintf "FeedbackLoop iteration %d failed: %s" iteration msg)
      | Ok output ->
          (* Score the output *)
          let score = score_output output in

          (* Store feedback in outputs for reference *)
          Hashtbl.replace ctx.outputs (parent.id ^ ".feedback") "";

          if passes_threshold score then begin
            (* Success: score meets threshold *)
            let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
            record_complete ctx parent.id ~duration_ms ~success:true;
            store_node_output ctx parent output;
            Ok output
          end else begin
            (* Generate feedback and prepare for next iteration *)
            let feedback = generate_feedback output score in
            Hashtbl.replace ctx.outputs (parent.id ^ ".feedback") feedback;

            (* Update generator prompt with feedback *)
            let new_prompt = substitute_prompt improver_prompt ~score ~feedback ~previous_output:output in
            let updated_generator = match (!current_generator).node_type with
              | Model model_config ->
                  { !current_generator with
                    node_type = Model { model_config with prompt = new_prompt };
                    id = Printf.sprintf "%s_iter%d" generator.id iteration }
              | _ ->
                  (* For non-MODEL generators, we can't easily update prompt *)
                  (* Just retry with same generator *)
                  !current_generator
            in
            current_generator := updated_generator;
            iterate (iteration + 1)
          end
    end
  in
  let result = iterate 1 in
  ctx.conversation <- prev_conversation;
  result

let execute_stream_merge ctx ~sw ~clock ~(exec_fn : exec_fn) ~(execute_node : execute_node_fn) ~tool_exec (parent : node)
    ~nodes ~reducer ~initial ~min_results ~timeout : (string, string) result =
  record_start ctx parent.id;
  let start = Time_compat.now () in

  (* Stream for progressive results: Some (id, output) or None for completion *)
  let stream = Eio.Stream.create (List.length nodes) in
  let completed_count = ref 0 in
  let total_count = List.length nodes in
  let count_mutex = Eio.Mutex.create () in

  (* Producer: Execute nodes in parallel, push results to stream as they complete *)
  Eio.Fiber.fork ~sw (fun () ->
    let is_cancelled exn =
      match exn with
      | Eio.Cancel.Cancelled _ -> true
      | _ -> false
    in
    let safe_stream_add value =
      try
        Eio.Stream.add stream value
      with exn ->
        if is_cancelled exn then raise exn;
        Log.Chain.error "stream add error: %s"
          (Printexc.to_string exn)
    in
    (try
       Eio.Fiber.all (List.map (fun (node : node) ->
         fun () ->
           try
             match execute_node ctx ~sw ~clock ~exec_fn ~tool_exec node with
             | Ok output ->
                 Eio.Mutex.use_rw count_mutex ~protect:true (fun () ->
                   incr completed_count;
                   Log.Chain.info "%s completed (%d/%d)"
                     node.id !completed_count total_count);
                 safe_stream_add (Some (node.id, Ok output))
             | Error msg ->
                 Eio.Mutex.use_rw count_mutex ~protect:true (fun () ->
                   incr completed_count);
                 safe_stream_add (Some (node.id, Error msg))
           with exn ->
             let err = Printexc.to_string exn in
             Eio.Mutex.use_rw count_mutex ~protect:true (fun () ->
               incr completed_count);
             safe_stream_add (Some (node.id, Error err))
       ) nodes)
     with exn ->
       if is_cancelled exn then raise exn;
       Log.Chain.info "producer crashed: %s"
         (Printexc.to_string exn));
    (* Signal completion after all producers done *)
    (try
       safe_stream_add None
     with exn ->
       if is_cancelled exn then raise exn;
       Log.Chain.error "completion signal error: %s"
         (Printexc.to_string exn))
  );

  (* Consumer: Process results progressively using reducer *)
  let acc = ref initial in
  let results_collected = ref 0 in
  let min_required = match min_results with Some n -> n | None -> total_count in
  let timeout_sec = match timeout with Some t -> t | None -> infinity in
  let deadline = start +. timeout_sec in

  let rec consume () =
    let now = Time_compat.now () in
    if now > deadline && !results_collected >= min_required then begin
      (* Timeout reached after min_results met *)
      Log.Chain.info "Timeout reached with %d results" !results_collected;
      Ok !acc
    end else begin
      match Eio.Stream.take stream with
      | None ->
          (* All producers finished *)
          Log.Chain.info "All %d nodes processed" !results_collected;
          Ok !acc
      | Some (id, Error msg) ->
          Log.Chain.error "%s failed: %s" id msg;
          consume ()  (* Skip failures, continue processing *)
      | Some (id, Ok output) ->
          incr results_collected;
          (* Apply reducer to accumulate result *)
          let new_acc = match reducer with
            | First -> if !acc = initial then output else !acc
            | Last -> output
            | Concat ->
                if !acc = initial then output
                else !acc ^ "\n" ^ output
            | WeightedAvg ->
                if !acc = initial then Printf.sprintf "[%s]: %s" id output
                else !acc ^ "\n---\n" ^ Printf.sprintf "[%s]: %s" id output
            | Custom func_name ->
                if !acc = initial then Printf.sprintf "[%s via %s]: %s" id func_name output
                else !acc ^ "\n---\n" ^ Printf.sprintf "[%s via %s]: %s" id func_name output
          in
          acc := new_acc;
          Log.Chain.info "Accumulated %s (%d collected)" id !results_collected;

          (* Check if we can return early (min_results met + optional timeout) *)
          if !results_collected >= min_required && timeout_sec < infinity then begin
            (* Wait briefly for more results or timeout *)
            let remaining = deadline -. Time_compat.now () in
            if remaining <= 0.0 then Ok !acc
            else consume ()  (* Keep consuming until timeout *)
          end else
            consume ()
    end
  in

  let result = consume () in
  let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in

  match result with
  | Ok output ->
      record_complete ctx parent.id ~duration_ms ~success:true;
      store_node_output ctx parent output;
      Ok output
  | Error msg ->
      record_complete ctx parent.id ~duration_ms ~success:false;
      record_error ctx parent.id msg;
      Error msg


