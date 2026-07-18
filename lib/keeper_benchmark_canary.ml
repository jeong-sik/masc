type recommendation = {
  keeper_profile : string;
  model_label : string;
  composite_score : float;
  task_pass_rate : float;
  stability_score : float option;
  cases_total : int;
  cases_passed : int;
}

type manifest = {
  version : int;
  generated_at : string;
  source_summary_path : string option;
  recommendations : recommendation list;
}

let row_to_recommendation
    (row : Tool_call_quality_benchmark.summary_row) : recommendation option =
  match row.provider, row.model, row.keeper_profile with
  | Some provider, Some model, Some keeper_profile
    when row.cases_total > 0
         && row.cases_passed = row.cases_total
         && row.unsupported_runs = 0
         && row.runtime_unreachable_runs = 0 ->
      Some
        {
          keeper_profile;
          model_label = provider ^ ":" ^ model;
          composite_score = row.composite_score;
          task_pass_rate = row.task_pass_rate;
          stability_score = row.stability_score;
          cases_total = row.cases_total;
          cases_passed = row.cases_passed;
        }
  | _ -> None

let compare_float_option_desc a b =
  match a, b with
  | Some left, Some right -> Float.compare right left
  | Some _, None -> -1
  | None, Some _ -> 1
  | None, None -> 0

let compare_recommendation left right =
  match Float.compare right.composite_score left.composite_score with
  | 0 -> (
      match Float.compare right.task_pass_rate left.task_pass_rate with
      | 0 -> (
          match compare_float_option_desc left.stability_score right.stability_score with
          | 0 -> (
              match Int.compare right.cases_total left.cases_total with
              | 0 -> (
                  match Int.compare right.cases_passed left.cases_passed with
                  | 0 -> String.compare left.model_label right.model_label
                  | cmp -> cmp)
              | cmp -> cmp)
          | cmp -> cmp)
      | cmp -> cmp)
  | cmp -> cmp

let generated_at_utc () = Masc_domain.now_iso ()

let build_manifest ?source_summary_path
    (summary : Tool_call_quality_benchmark.benchmark_summary) : manifest =
  let grouped = Hashtbl.create 8 in
  summary.grouped_by_provider_model_keeper
  |> List.filter_map row_to_recommendation
  |> List.iter (fun recommendation ->
         let current =
           Hashtbl.find_opt grouped recommendation.keeper_profile
         in
         match current with
         | Some best when compare_recommendation recommendation best >= 0 -> ()
         | _ ->
             Hashtbl.replace grouped recommendation.keeper_profile recommendation);
  let recommendations =
    Hashtbl.to_seq_values grouped
    |> List.of_seq
    |> List.sort (fun left right ->
           match String.compare left.keeper_profile right.keeper_profile with
           | 0 -> compare_recommendation left right
           | cmp -> cmp)
  in
  {
    version = 1;
    generated_at = generated_at_utc ();
    source_summary_path;
    recommendations;
  }

let recommendation_to_yojson (recommendation : recommendation) =
  `Assoc
    [
      ("keeper_profile", `String recommendation.keeper_profile);
      ("model_label", `String recommendation.model_label);
      ("composite_score", `Float recommendation.composite_score);
      ("task_pass_rate", `Float recommendation.task_pass_rate);
      ( "stability_score",
        Option.fold ~none:`Null ~some:(fun value -> `Float value)
          recommendation.stability_score );
      ("cases_total", `Int recommendation.cases_total);
      ("cases_passed", `Int recommendation.cases_passed);
    ]

let manifest_to_yojson (manifest : manifest) =
  `Assoc
    [
      ("version", `Int manifest.version);
      ("generated_at", `String manifest.generated_at);
      ( "source_summary_path",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          manifest.source_summary_path );
      ( "recommendations",
        `List (List.map recommendation_to_yojson manifest.recommendations) );
    ]
