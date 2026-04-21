open Tool_call_quality_benchmark_types

let case_score_to_yojson (score : case_score) =
  `Assoc
    [
      ("case_id", `String score.case_id);
      ("provider", `String score.provider);
      ("model", `String score.model);
      ("keeper_profile", `String score.keeper_profile);
      ("passed", `Bool score.passed);
      ("task_pass", `Float score.task_pass);
      ("tool_selection", `Float score.tool_selection);
      ("arg_validity", `Float score.arg_validity);
      ("recovery", `Float score.recovery);
      ("efficiency", `Float score.efficiency);
      ("unnecessary_tool_rate", `Float score.unnecessary_tool_rate);
      ("composite_score", `Float score.composite_score);
      ("tool_call_count", `Int score.tool_call_count);
      ("latency_ms", Option.fold ~none:`Null ~some:(fun value -> `Int value) score.latency_ms);
      ("input_tokens", Option.fold ~none:`Null ~some:(fun value -> `Int value) score.input_tokens);
      ("output_tokens", Option.fold ~none:`Null ~some:(fun value -> `Int value) score.output_tokens);
      ("cost_usd", Option.fold ~none:`Null ~some:(fun value -> `Float value) score.cost_usd);
      ("prompt_fingerprint",
       Option.fold ~none:`Null ~some:(fun value -> `String value) score.prompt_fingerprint);
      ("tool_sequence", `List (List.map (fun value -> `String value) score.tool_sequence));
    ]

let json_check_to_yojson (check : json_check) =
  `Assoc
    [
      ("path", `String check.path);
      ("equals", Option.value ~default:`Null check.equals);
      ("contains", Option.fold ~none:`Null ~some:(fun value -> `String value) check.contains);
      ("min_int", Option.fold ~none:`Null ~some:(fun value -> `Int value) check.min_int);
      ("present", Option.fold ~none:`Null ~some:(fun value -> `Bool value) check.present);
    ]

let summary_row_to_yojson (row : summary_row) =
  `Assoc
    [
      ("provider", Option.fold ~none:`Null ~some:(fun value -> `String value) row.provider);
      ("model", Option.fold ~none:`Null ~some:(fun value -> `String value) row.model);
      ("keeper_profile",
       Option.fold ~none:`Null ~some:(fun value -> `String value) row.keeper_profile);
      ("cases_total", `Int row.cases_total);
      ("cases_passed", `Int row.cases_passed);
      ("task_pass_rate", `Float row.task_pass_rate);
      ("correct_tool_rate", `Float row.correct_tool_rate);
      ("arg_valid_rate", `Float row.arg_valid_rate);
      ("recovery_rate", `Float row.recovery_rate);
      ("unnecessary_tool_rate", `Float row.unnecessary_tool_rate);
      ("avg_tool_calls", `Float row.avg_tool_calls);
      ("p95_latency_ms", `Float row.p95_latency_ms);
      ("avg_input_tokens", `Float row.avg_input_tokens);
      ("avg_output_tokens", `Float row.avg_output_tokens);
      ("avg_cost_usd", `Float row.avg_cost_usd);
      ("composite_score", `Float row.composite_score);
      ("unsupported_runs", `Int row.unsupported_runs);
      ("runtime_unreachable_runs", `Int row.runtime_unreachable_runs);
      ("stability_score", Option.fold ~none:`Null ~some:(fun value -> `Float value) row.stability_score);
      ( "tool_sequence_consistency_rate",
        Option.fold ~none:`Null ~some:(fun value -> `Float value)
          row.tool_sequence_consistency_rate );
      ( "prompt_fingerprint_consistency_rate",
        Option.fold ~none:`Null ~some:(fun value -> `Float value)
          row.prompt_fingerprint_consistency_rate );
      ( "pass_consistency_rate",
        Option.fold ~none:`Null ~some:(fun value -> `Float value)
          row.pass_consistency_rate );
      ("repeated_case_groups", `Int row.repeated_case_groups);
    ]

let benchmark_summary_to_yojson (summary : benchmark_summary) =
  `Assoc
    [
      ("cases_total", `Int summary.cases_total);
      ("runs_total", `Int summary.runs_total);
      ("scored_runs", `Int summary.scored_runs);
      ("unsupported_runs", `Int summary.unsupported_runs);
      ("runtime_unreachable_runs", `Int summary.runtime_unreachable_runs);
      ("unknown_case_runs", `Int summary.unknown_case_runs);
      ( "grouped_by_provider_model_keeper",
        `List (List.map summary_row_to_yojson summary.grouped_by_provider_model_keeper) );
      ( "grouped_by_provider_model",
        `List (List.map summary_row_to_yojson summary.grouped_by_provider_model) );
      ( "grouped_by_keeper_profile",
        `List (List.map summary_row_to_yojson summary.grouped_by_keeper_profile) );
    ]

let csv_escape value =
  let needs_quote =
    String.contains value ','
    || String.contains value '"'
    || String.contains value '\n'
  in
  if not needs_quote then value
  else "\"" ^ String.concat "\"\"" (String.split_on_char '"' value) ^ "\""

let value_or_empty = function Some value -> value | None -> ""

let string_of_float_option = function
  | Some value -> Printf.sprintf "%.4f" value
  | None -> ""

let rows_for_view view summary =
  match view with
  | By_provider_model_keeper -> summary.grouped_by_provider_model_keeper
  | By_provider_model -> summary.grouped_by_provider_model
  | By_keeper_profile -> summary.grouped_by_keeper_profile

let summary_rows_to_csv ~view summary =
  let headers =
    [
      "provider";
      "model";
      "keeper_profile";
      "cases_total";
      "cases_passed";
      "task_pass_rate";
      "correct_tool_rate";
      "arg_valid_rate";
      "recovery_rate";
      "unnecessary_tool_rate";
      "avg_tool_calls";
      "p95_latency_ms";
      "avg_input_tokens";
      "avg_output_tokens";
      "avg_cost_usd";
      "composite_score";
      "unsupported_runs";
      "runtime_unreachable_runs";
      "stability_score";
      "tool_sequence_consistency_rate";
      "prompt_fingerprint_consistency_rate";
      "pass_consistency_rate";
      "repeated_case_groups";
    ]
  in
  let row_to_values (row : summary_row) =
    [
      value_or_empty row.provider;
      value_or_empty row.model;
      value_or_empty row.keeper_profile;
      string_of_int row.cases_total;
      string_of_int row.cases_passed;
      Printf.sprintf "%.4f" row.task_pass_rate;
      Printf.sprintf "%.4f" row.correct_tool_rate;
      Printf.sprintf "%.4f" row.arg_valid_rate;
      Printf.sprintf "%.4f" row.recovery_rate;
      Printf.sprintf "%.4f" row.unnecessary_tool_rate;
      Printf.sprintf "%.4f" row.avg_tool_calls;
      Printf.sprintf "%.1f" row.p95_latency_ms;
      Printf.sprintf "%.1f" row.avg_input_tokens;
      Printf.sprintf "%.1f" row.avg_output_tokens;
      Printf.sprintf "%.6f" row.avg_cost_usd;
      Printf.sprintf "%.2f" row.composite_score;
      string_of_int row.unsupported_runs;
      string_of_int row.runtime_unreachable_runs;
      string_of_float_option row.stability_score;
      string_of_float_option row.tool_sequence_consistency_rate;
      string_of_float_option row.prompt_fingerprint_consistency_rate;
      string_of_float_option row.pass_consistency_rate;
      string_of_int row.repeated_case_groups;
    ]
  in
  let lines =
    headers :: List.map row_to_values (rows_for_view view summary)
    |> List.map (fun values -> values |> List.map csv_escape |> String.concat ",")
  in
  String.concat "\n" lines ^ "\n"
