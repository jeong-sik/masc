open Tool_call_quality_benchmark_types

let avg_float values =
  match values with
  | [] -> 0.0
  | _ ->
      List.fold_left ( +. ) 0.0 values /. float_of_int (List.length values)

let avg_int_option values =
  values
  |> List.filter_map (fun value -> value)
  |> List.map float_of_int
  |> avg_float

let avg_float_option values =
  values
  |> List.filter_map (fun value -> value)
  |> avg_float

let percentile95_int_option values =
  let values = List.filter_map (fun value -> value) values |> List.sort Int.compare in
  match values with
  | [] -> 0.0
  | _ ->
      let n = List.length values in
      let idx =
        int_of_float (Float.ceil (0.95 *. float_of_int n)) - 1
        |> max 0 |> min (n - 1)
      in
      float_of_int (List.nth values idx)

let dedupe_keep_order items =
  let seen = Hashtbl.create (List.length items) in
  List.filter
    (fun item ->
      if Hashtbl.mem seen item then false
      else (
        Hashtbl.add seen item ();
        true))
    items

let normalize_string_list items =
  items
  |> List.map String.trim
  |> List.filter (fun item -> item <> "")
  |> dedupe_keep_order

let model_label (run : evidence_run) = run.provider ^ ":" ^ run.model

let normalize_filter_set values =
  let table = Hashtbl.create 8 in
  values
  |> normalize_string_list
  |> List.iter (fun value -> Hashtbl.replace table value ());
  table

let keep_run ?model_filters ?keeper_filters (run : evidence_run) =
  let model_ok =
    match model_filters with
    | None | Some [] -> true
    | Some filters -> Hashtbl.mem (normalize_filter_set filters) (model_label run)
  in
  let keeper_ok =
    match keeper_filters with
    | None | Some [] -> true
    | Some filters -> Hashtbl.mem (normalize_filter_set filters) run.keeper_profile
  in
  model_ok && keeper_ok

let group_scores_by_case grouped_scores =
  let grouped = Hashtbl.create 8 in
  List.iter
    (fun score ->
      let current = Hashtbl.find_opt grouped score.case_id |> Option.value ~default:[] in
      Hashtbl.replace grouped score.case_id (score :: current))
    grouped_scores;
  grouped

let modal_ratio values =
  match values with
  | [] -> None
  | _ ->
      let counts = Hashtbl.create (List.length values) in
      List.iter
        (fun value ->
          let next =
            match Hashtbl.find_opt counts value with
            | Some count -> count + 1
            | None -> 1
          in
          Hashtbl.replace counts value next)
        values;
      let best =
        Hashtbl.fold (fun _ count acc -> max acc count) counts 0
      in
      Some (float_of_int best /. float_of_int (List.length values))

let tool_sequence (run : evidence_run) =
  run.tool_calls |> List.map (fun call -> call.tool_name)

let summary_key_of_run view (run : evidence_run) =
  match view with
  | By_provider_model_keeper -> (Some run.provider, Some run.model, Some run.keeper_profile)
  | By_provider_model -> (Some run.provider, Some run.model, None)
  | By_keeper_profile -> (None, None, Some run.keeper_profile)

let summary_key_of_score view (score : case_score) =
  match view with
  | By_provider_model_keeper ->
      (Some score.provider, Some score.model, Some score.keeper_profile)
  | By_provider_model -> (Some score.provider, Some score.model, None)
  | By_keeper_profile -> (None, None, Some score.keeper_profile)

let repeated_metrics_for_view view runs =
  let grouped = Hashtbl.create 16 in
  List.iter
    (fun run ->
      if run.status = Run_ok then
        let (provider, model, keeper_profile) = summary_key_of_run view run in
        let key = (provider, model, keeper_profile, run.case_id) in
        let current = Hashtbl.find_opt grouped key |> Option.value ~default:[] in
        Hashtbl.replace grouped key (run :: current))
    runs;
  Hashtbl.fold
    (fun (provider, model, keeper_profile, _case_id)
         (grouped_runs : evidence_run list) acc ->
      if List.length grouped_runs < 2 then acc
      else
        let tool_sequence_ratio =
          grouped_runs
          |> List.map tool_sequence
          |> List.map (String.concat ">")
          |> modal_ratio
        in
        let prompt_ratio =
          grouped_runs
          |> List.filter_map (fun (run : evidence_run) -> run.prompt_fingerprint)
          |> modal_ratio
        in
        let pass_ratio =
          grouped_runs
          |> List.map (fun (run : evidence_run) ->
                 Option.value ~default:false run.task_success |> string_of_bool)
          |> modal_ratio
        in
        let stability =
          [ tool_sequence_ratio; prompt_ratio; pass_ratio ]
          |> List.filter_map (fun value -> value)
          |> avg_float
        in
        ((provider, model, keeper_profile), (stability, tool_sequence_ratio, prompt_ratio, pass_ratio))
        :: acc)
    grouped []

let collapse_repeated_metrics metrics =
  let grouped = Hashtbl.create 8 in
  List.iter
    (fun (key, values) ->
      let current = Hashtbl.find_opt grouped key |> Option.value ~default:[] in
      Hashtbl.replace grouped key (values :: current))
    metrics;
  Hashtbl.fold
    (fun key values acc ->
      let stability_values, tool_values, prompt_values, pass_values =
        List.fold_left
          (fun (st_acc, tl_acc, pr_acc, pa_acc) (st, tl, pr, pa) ->
            ( st :: st_acc
            , (match tl with Some value -> value :: tl_acc | None -> tl_acc)
            , (match pr with Some value -> value :: pr_acc | None -> pr_acc)
            , (match pa with Some value -> value :: pa_acc | None -> pa_acc) ))
          ([], [], [], []) values
      in
      ( key
      , ( avg_float stability_values
        , (match tool_values with [] -> None | _ -> Some (avg_float tool_values))
        , (match prompt_values with [] -> None | _ -> Some (avg_float prompt_values))
        , (match pass_values with [] -> None | _ -> Some (avg_float pass_values))
        , List.length values ) )
      :: acc)
    grouped []

let build_summary_rows view runs scores =
  let repeated_metrics =
    repeated_metrics_for_view view runs |> collapse_repeated_metrics
    |> List.to_seq |> Hashtbl.of_seq
  in
  let scores_by_key = Hashtbl.create 16 in
  List.iter
    (fun score ->
      let key = summary_key_of_score view score in
      let current = Hashtbl.find_opt scores_by_key key |> Option.value ~default:[] in
      Hashtbl.replace scores_by_key key (score :: current))
    scores;
  Hashtbl.fold
    (fun (provider, model, keeper_profile as key)
         (grouped_scores : case_score list) acc ->
      let grouped_runs =
        runs
        |> List.filter (fun run ->
               let run_key = summary_key_of_run view run in
               run_key = key)
      in
      let grouped_scores_by_case = group_scores_by_case grouped_scores in
      let unsupported_runs =
        grouped_runs
        |> List.filter (fun run -> run.status = Run_unsupported)
        |> List.length
      in
      let runtime_unreachable_runs =
        grouped_runs
        |> List.filter (fun run -> run.status = Run_runtime_unreachable)
        |> List.length
      in
      let stability_score, tool_sequence_consistency_rate,
          prompt_fingerprint_consistency_rate, pass_consistency_rate,
          repeated_case_groups =
        match Hashtbl.find_opt repeated_metrics key with
        | Some (stability, tool_rate, prompt_rate, pass_rate, group_count) ->
            (Some stability, tool_rate, prompt_rate, pass_rate, group_count)
        | None -> (None, None, None, None, 0)
      in
      let cases_total = Hashtbl.length grouped_scores_by_case in
      let cases_passed =
        Hashtbl.fold
          (fun _ scores_for_case count ->
            if List.for_all (fun score -> score.passed) scores_for_case then count + 1
            else count)
          grouped_scores_by_case 0
      in
      let row =
        {
          provider;
          model;
          keeper_profile;
          cases_total;
          cases_passed;
          task_pass_rate =
            grouped_scores |> List.map (fun (score : case_score) -> score.task_pass)
            |> avg_float;
          correct_tool_rate =
            grouped_scores
            |> List.map (fun (score : case_score) -> score.tool_selection)
            |> avg_float;
          arg_valid_rate =
            grouped_scores
            |> List.map (fun (score : case_score) -> score.arg_validity)
            |> avg_float;
          recovery_rate =
            grouped_scores
            |> List.map (fun (score : case_score) -> score.recovery)
            |> avg_float;
          unnecessary_tool_rate =
            grouped_scores
            |> List.map (fun (score : case_score) -> score.unnecessary_tool_rate)
            |> avg_float;
          avg_tool_calls =
            grouped_scores
            |> List.map (fun (score : case_score) -> float_of_int score.tool_call_count)
            |> avg_float;
          p95_latency_ms =
            grouped_scores |> List.map (fun (score : case_score) -> score.latency_ms)
            |> percentile95_int_option;
          avg_input_tokens =
            grouped_scores |> List.map (fun (score : case_score) -> score.input_tokens)
            |> avg_int_option;
          avg_output_tokens =
            grouped_scores |> List.map (fun (score : case_score) -> score.output_tokens)
            |> avg_int_option;
          avg_cost_usd =
            grouped_scores |> List.map (fun (score : case_score) -> score.cost_usd)
            |> avg_float_option;
          composite_score =
            grouped_scores |> List.map (fun (score : case_score) -> score.composite_score)
            |> avg_float;
          unsupported_runs;
          runtime_unreachable_runs;
          stability_score;
          tool_sequence_consistency_rate;
          prompt_fingerprint_consistency_rate;
          pass_consistency_rate;
          repeated_case_groups;
        }
      in
      row :: acc)
    scores_by_key []
  |> List.sort (fun a b ->
         match Float.compare b.composite_score a.composite_score with
         | 0 -> Int.compare b.cases_total a.cases_total
         | cmp -> cmp)

let summarize ~cases ~runs ?model_filters ?keeper_filters () =
  let filtered_runs =
    runs
    |> List.filter (fun run -> keep_run ?model_filters ?keeper_filters run)
  in
  let score_results =
    filtered_runs
    |> List.filter_map (Tool_call_quality_benchmark_scoring.score_run ~cases)
  in
  let unsupported_runs =
    filtered_runs |> List.filter (fun run -> run.status = Run_unsupported) |> List.length
  in
  let runtime_unreachable_runs =
    filtered_runs
    |> List.filter (fun run -> run.status = Run_runtime_unreachable)
    |> List.length
  in
  let unknown_case_runs =
    filtered_runs
    |> List.filter (fun run ->
           run.status = Run_ok
           && not (List.exists (fun case -> String.equal case.id run.case_id) cases))
    |> List.length
  in
  {
    cases_total = List.length cases;
    runs_total = List.length filtered_runs;
    scored_runs = List.length score_results;
    unsupported_runs;
    runtime_unreachable_runs;
    unknown_case_runs;
    grouped_by_provider_model_keeper =
      build_summary_rows By_provider_model_keeper filtered_runs score_results;
    grouped_by_provider_model =
      build_summary_rows By_provider_model filtered_runs score_results;
    grouped_by_keeper_profile =
      build_summary_rows By_keeper_profile filtered_runs score_results;
  }
