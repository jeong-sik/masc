open Tool_call_quality_benchmark_types

let avg_float values =
  match values with
  | [] -> 0.0
  | _ ->
      List.fold_left ( +. ) 0.0 values /. float_of_int (List.length values)

let split_path path =
  let path = String.trim path in
  if path = "$" then []
  else
    let path =
      if String.starts_with ~prefix:"$." path then
        String.sub path 2 (String.length path - 2)
      else if String.starts_with ~prefix:"$" path then
        String.sub path 1 (String.length path - 1)
      else
        path
    in
    if path = "" then [] else String.split_on_char '.' path

let rec json_at_path json segments =
  match segments, json with
  | [], _ -> Some json
  | segment :: rest, `Assoc fields -> (
      match List.assoc_opt segment fields with
      | Some value -> json_at_path value rest
      | None -> None)
  | segment :: rest, `List items -> (
      match int_of_string_opt segment with
      | Some idx when idx >= 0 && idx < List.length items ->
          json_at_path (List.nth items idx) rest
      | _ -> None)
  | _ -> None

let string_of_json value =
  match value with
  | `String s -> s
  | _ -> Yojson.Safe.to_string value

let evaluate_json_check ~(target : Yojson.Safe.t option) (check : json_check) =
  let actual =
    match target with
    | Some json -> json_at_path json (split_path check.path)
    | None -> None
  in
  let present_ok =
    match check.present with
    | None -> true
    | Some true -> (match actual with Some `Null | None -> false | Some _ -> true)
    | Some false -> (match actual with Some value when value <> `Null -> false | _ -> true)
  in
  let equals_ok =
    match check.equals with
    | None -> true
    | Some expected -> actual = Some expected
  in
  let contains_ok =
    match check.contains with
    | None -> true
    | Some needle -> (
        match actual with
        | Some value -> String_util.contains_substring (string_of_json value) needle
        | None -> false)
  in
  let min_int_ok =
    match check.min_int with
    | None -> true
    | Some min_value -> (
        match actual with
        | Some (`Int value) -> value >= min_value
        | Some (`Float value) -> value >= float_of_int min_value
        | _ -> false)
  in
  present_ok && equals_ok && contains_ok && min_int_ok

let tool_used tool_name (run : evidence_run) =
  List.exists (fun call -> String.equal call.tool_name tool_name) run.tool_calls

let arg_check_passes (run : evidence_run) (check : arg_check) =
  let predicate call =
    String.equal call.tool_name check.tool_name
    && evaluate_json_check ~target:(Some call.input)
         { path = check.path
         ; equals = check.equals
         ; contains = check.contains
         ; min_int = check.min_int
         ; present = check.present
         }
  in
  List.exists predicate run.tool_calls

let tool_sequence (run : evidence_run) =
  run.tool_calls |> List.map (fun call -> call.tool_name)

let required_tool_score (benchmark_case : benchmark_case) (run : evidence_run) =
  match benchmark_case.category with
  | Tool_forbidden ->
      if run.tool_calls = [] then 1.0 else 0.0
  | _ ->
      (match benchmark_case.required_tools with
       | [] -> 1.0
       | required_tools ->
           required_tools
           |> List.map (fun tool_name ->
                  if tool_used tool_name run then 1.0 else 0.0)
           |> avg_float)

let forbidden_tool_used (benchmark_case : benchmark_case) (run : evidence_run) =
  match benchmark_case.category with
  | Tool_forbidden -> run.tool_calls <> []
  | _ ->
      List.exists (fun tool_name -> tool_used tool_name run) benchmark_case.forbidden_tools

let task_pass_score (benchmark_case : benchmark_case) (run : evidence_run) =
  let reported = Option.value ~default:false run.task_success in
  let checks =
    benchmark_case.success_checks
    |> List.for_all (evaluate_json_check ~target:run.final_result)
  in
  if reported && checks then 1.0 else 0.0

let arg_validity_score (benchmark_case : benchmark_case) (run : evidence_run) =
  match benchmark_case.arg_checks with
  | [] -> 1.0
  | checks ->
      checks
      |> List.map (fun check -> if arg_check_passes run check then 1.0 else 0.0)
      |> avg_float

let recovery_score (benchmark_case : benchmark_case) (run : evidence_run) task_pass =
  match benchmark_case.recovery_policy with
  | None -> 1.0
  | Some policy when not policy.required -> 1.0
  | Some policy ->
      let calls = run.tool_calls in
      let rec find_success_after failures_seen failures_before_success = function
        | [] -> None
        | call :: rest ->
            if call.success then
              if failures_seen then Some failures_before_success
              else find_success_after failures_seen failures_before_success rest
            else
              find_success_after true (failures_before_success + 1) rest
      in
      let success_after_failure =
        if policy.success_after_failure then find_success_after false 0 calls else Some 0
      in
      let failure_limit_ok =
        match success_after_failure, policy.max_failures_before_success with
        | Some _, None -> true
        | Some failures, Some max_failures -> failures <= max_failures
        | None, _ -> false
      in
      if task_pass = 1.0 && failure_limit_ok && success_after_failure <> None then 1.0
      else 0.0

let unnecessary_tool_rate (benchmark_case : benchmark_case) (run : evidence_run) =
  let call_count = List.length run.tool_calls in
  if call_count = 0 then 0.0
  else
    match benchmark_case.category with
    | Tool_forbidden -> 1.0
    | _ ->
        let forbidden_count =
          run.tool_calls
          |> List.filter (fun call -> List.mem call.tool_name benchmark_case.forbidden_tools)
          |> List.length
        in
        let over_limit = max 0 (call_count - benchmark_case.max_tool_calls) in
        min 1.0
          (float_of_int (forbidden_count + over_limit) /. float_of_int call_count)

let efficiency_score (benchmark_case : benchmark_case) (run : evidence_run) =
  let call_count = List.length run.tool_calls in
  match benchmark_case.category with
  | Tool_forbidden ->
      if call_count = 0 then 1.0 else 0.0
  | _ ->
      if benchmark_case.max_tool_calls <= 0 then
        if call_count = 0 then 1.0 else 0.0
      else
        let over_limit = max 0 (call_count - benchmark_case.max_tool_calls) in
        max 0.0
          (1.0 -. (float_of_int over_limit /. float_of_int benchmark_case.max_tool_calls))

let score_run ~cases (run : evidence_run) =
  if run.status <> Run_ok then None
  else
    let cases_by_id =
      cases
      |> List.to_seq
      |> Seq.map (fun case -> (case.id, case))
      |> Hashtbl.of_seq
    in
    match Hashtbl.find_opt cases_by_id run.case_id with
    | None -> None
    | Some benchmark_case ->
        if not (List.mem run.keeper_profile benchmark_case.keeper_profiles) then None
        else
          let task_pass = task_pass_score benchmark_case run in
          let required_score = required_tool_score benchmark_case run in
          let tool_selection =
            if forbidden_tool_used benchmark_case run then 0.0 else required_score
          in
          let arg_validity = arg_validity_score benchmark_case run in
          let recovery = recovery_score benchmark_case run task_pass in
          let efficiency = efficiency_score benchmark_case run in
          let unnecessary_tool_rate = unnecessary_tool_rate benchmark_case run in
          let composite_score =
            (40.0 *. task_pass)
            +. (25.0 *. tool_selection)
            +. (15.0 *. arg_validity)
            +. (10.0 *. recovery)
            +. (10.0 *. efficiency)
          in
          let passed =
            task_pass = 1.0
            && tool_selection = 1.0
            && arg_validity = 1.0
            && recovery = 1.0
            && efficiency = 1.0
          in
          Some
            {
              case_id = run.case_id;
              provider = run.provider;
              model = run.model;
              keeper_profile = run.keeper_profile;
              passed;
              task_pass;
              tool_selection;
              arg_validity;
              recovery;
              efficiency;
              unnecessary_tool_rate;
              composite_score;
              tool_call_count = List.length run.tool_calls;
              latency_ms = run.latency_ms;
              input_tokens = run.input_tokens;
              output_tokens = run.output_tokens;
              cost_usd = run.cost_usd;
              prompt_fingerprint = run.prompt_fingerprint;
              tool_sequence = tool_sequence run;
            }
