open Tool_call_quality_benchmark_types

let avg_float values =
  match values with
  | [] -> 0.0
  | _ ->
      List.fold_left ( +. ) 0.0 values /. Stdlib.Float.of_int (List.length values)

let avg_int_option values =
  values
  |> List.filter_map (fun value -> value)
  |> List.map Stdlib.Float.of_int
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
        Stdlib.Int.of_float (Float.ceil (0.95 *. Stdlib.Float.of_int n)) - 1
        |> max 0 |> min (n - 1)
      in
      match List.nth_opt values idx with
      | Some v -> Stdlib.Float.of_int v
      | None -> 0.0

let model_label (run : evidence_run) = run.provider ^ ":" ^ run.model

module String_set = Set.Make (String)
module String_map = Map.Make (String)

module Summary_key = struct
  type t = string option * string option * string option

  let compare (p1, m1, k1) (p2, m2, k2) =
    let c = Option.compare String.compare p1 p2 in
    if c <> 0 then c
    else
      let c = Option.compare String.compare m1 m2 in
      if c <> 0 then c
      else Option.compare String.compare k1 k2
end

module Summary_key_map = Map.Make (Summary_key)

module Repeated_key = struct
  type t = (string option * string option * string option) * string

  let compare (sk1, c1) (sk2, c2) =
    let c = Summary_key.compare sk1 sk2 in
    if c <> 0 then c else String.compare c1 c2
end

module Repeated_key_map = Map.Make (Repeated_key)

let normalize_filter_set values =
  values
  |> Json_util.normalize_string_list
  |> List.fold_left (fun acc value -> String_set.add value acc) String_set.empty

let keep_run ?model_filter_set ?keeper_filter_set (run : evidence_run) =
  let model_ok =
    match model_filter_set with
    | None -> true
    | Some set -> String_set.mem (model_label run) set
  in
  let keeper_ok =
    match keeper_filter_set with
    | None -> true
    | Some set -> String_set.mem run.keeper_profile set
  in
  model_ok && keeper_ok

let group_scores_by_case grouped_scores =
  List.fold_left
    (fun acc score ->
      let current = String_map.find_opt score.case_id acc |> Option.value ~default:[] in
      String_map.add score.case_id (score :: current) acc)
    String_map.empty
    grouped_scores

let modal_ratio values =
  match values with
  | [] -> None
  | _ ->
      let counts =
        List.fold_left
          (fun acc value ->
            let next =
              match String_map.find_opt value acc with
              | Some count -> count + 1
              | None -> 1
            in
            String_map.add value next acc)
          String_map.empty
          values
      in
      let best =
        String_map.fold (fun _ count acc -> max acc count) counts 0
      in
      Some (Stdlib.Float.of_int best /. Stdlib.Float.of_int (List.length values))

let tool_sequence (run : evidence_run) =
  run.tool_calls |> List.map (fun (call : tool_call) -> call.tool_name)

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

let is_run_status (a : run_status) (b : run_status) =
  match a, b with
  | Run_ok, Run_ok
  | Run_unsupported, Run_unsupported
  | Run_runtime_unreachable, Run_runtime_unreachable -> true
  | (Run_ok | Run_unsupported | Run_runtime_unreachable),
    (Run_ok | Run_unsupported | Run_runtime_unreachable) -> false

let repeated_metrics_for_view view runs =
  let grouped =
    List.fold_left
      (fun acc run ->
        if is_run_status run.status Run_ok then
          let sk = summary_key_of_run view run in
          let key = (sk, run.case_id) in
          let current = Repeated_key_map.find_opt key acc |> Option.value ~default:[] in
          Repeated_key_map.add key (run :: current) acc
        else acc)
      Repeated_key_map.empty
      runs
  in
  Repeated_key_map.fold
    (fun (sk, _case_id) (grouped_runs : evidence_run list) acc ->
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
                 Option.value ~default:false run.task_success |> Bool.to_string)
          |> modal_ratio
        in
        let stability =
          [ tool_sequence_ratio; prompt_ratio; pass_ratio ]
          |> List.filter_map (fun value -> value)
          |> avg_float
        in
        (sk, (stability, tool_sequence_ratio, prompt_ratio, pass_ratio))
        :: acc)
    grouped []

let collapse_repeated_metrics metrics =
  let grouped =
    List.fold_left
      (fun acc (key, values) ->
        let current = Summary_key_map.find_opt key acc |> Option.value ~default:[] in
        Summary_key_map.add key (values :: current) acc)
      Summary_key_map.empty
      metrics
  in
  Summary_key_map.fold
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
      Summary_key_map.add
        key
        ( avg_float stability_values
        , (match tool_values with [] -> None | _ -> Some (avg_float tool_values))
        , (match prompt_values with [] -> None | _ -> Some (avg_float prompt_values))
        , (match pass_values with [] -> None | _ -> Some (avg_float pass_values))
        , List.length values )
        acc)
    grouped
    Summary_key_map.empty

let build_summary_rows view runs scores =
  let repeated_metrics =
    repeated_metrics_for_view view runs |> collapse_repeated_metrics
  in
  let runs_by_key =
    List.fold_left
      (fun acc run ->
        let key = summary_key_of_run view run in
        let current = Summary_key_map.find_opt key acc |> Option.value ~default:[] in
        Summary_key_map.add key (run :: current) acc)
      Summary_key_map.empty
      runs
  in
  let scores_by_key =
    List.fold_left
      (fun acc score ->
        let key = summary_key_of_score view score in
        let current = Summary_key_map.find_opt key acc |> Option.value ~default:[] in
        Summary_key_map.add key (score :: current) acc)
      Summary_key_map.empty
      scores
  in
  Summary_key_map.fold
    (fun (provider, model, keeper_profile as key)
         (grouped_scores : case_score list) acc ->
      let grouped_runs =
        Summary_key_map.find_opt key runs_by_key |> Option.value ~default:[]
      in
      let grouped_scores_by_case = group_scores_by_case grouped_scores in
      let unsupported_runs =
        grouped_runs
        |> List.filter (fun run -> is_run_status run.status Run_unsupported)
        |> List.length
      in
      let runtime_unreachable_runs =
        grouped_runs
        |> List.filter (fun run -> is_run_status run.status Run_runtime_unreachable)
        |> List.length
      in
      let stability_score, tool_sequence_consistency_rate,
          prompt_fingerprint_consistency_rate, pass_consistency_rate,
          repeated_case_groups =
        match Summary_key_map.find_opt key repeated_metrics with
        | Some (stability, tool_rate, prompt_rate, pass_rate, group_count) ->
            (Some stability, tool_rate, prompt_rate, pass_rate, group_count)
        | None -> (None, None, None, None, 0)
      in
      let cases_total = String_map.cardinal grouped_scores_by_case in
      let cases_passed =
        String_map.fold
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
          tool_policy_rate =
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
            |> List.map (fun (score : case_score) -> Stdlib.Float.of_int score.tool_call_count)
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
  let model_filter_set =
    match model_filters with
    | None | Some [] -> None
    | Some filters -> Some (normalize_filter_set filters)
  in
  let keeper_filter_set =
    match keeper_filters with
    | None | Some [] -> None
    | Some filters -> Some (normalize_filter_set filters)
  in
  let filtered_runs =
    runs
    |> List.filter (fun run ->
           keep_run ?model_filter_set ?keeper_filter_set run)
  in
  let score_results =
    filtered_runs
    |> List.filter_map (Tool_call_quality_benchmark_scoring.score_run ~cases)
  in
  let case_id_set =
    List.fold_left
      (fun acc case -> String_set.add case.id acc)
      String_set.empty
      cases
  in
  let unsupported_runs, runtime_unreachable_runs, unknown_case_runs =
    List.fold_left
      (fun (unsupported, unreachable, unknown_case) (run : evidence_run) ->
        match run.status with
        | Run_unsupported -> unsupported + 1, unreachable, unknown_case
        | Run_runtime_unreachable -> unsupported, unreachable + 1, unknown_case
        | Run_ok ->
          if String_set.mem run.case_id case_id_set
          then unsupported, unreachable, unknown_case
          else unsupported, unreachable, unknown_case + 1)
      (0, 0, 0)
      filtered_runs
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
