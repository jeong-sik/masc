open Tool_call_quality_benchmark_types

let default_case_set_path ~repo_root =
  Filename.concat repo_root "benchmark/tool_call_quality_cases.json"

let default_evidence_path ~repo_root =
  Filename.concat repo_root "test/fixtures/tool_call_quality_benchmark/evidence_runs.json"

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

let raise_invalidf fmt = Printf.ksprintf invalid_arg fmt

let run_status_of_string raw =
  match String.trim (String.lowercase_ascii raw) with
  | "" | "ok" -> Run_ok
  | "unsupported" -> Run_unsupported
  | "runtime_unreachable" -> Run_runtime_unreachable
  | other -> Run_other other

let case_category_of_string raw =
  match String.trim (String.lowercase_ascii raw) with
  | "tool_required" -> Tool_required
  | "tool_forbidden" -> Tool_forbidden
  | "recovery_required" -> Recovery_required
  | "multi_step" -> Multi_step
  | other -> raise_invalidf "unknown tool-call-quality category: %s" other

let read_json_file path =
  match Safe_ops.read_json_file_safe path with
  | Ok json -> json
  | Error err -> raise_invalidf "failed to read %s: %s" path err

let member_opt key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let required_string_field json key =
  match Yojson.Safe.Util.member key json |> Yojson.Safe.Util.to_string_option with
  | Some value when String.trim value <> "" -> value
  | _ -> raise_invalidf "missing required string field %s" key

let list_field json key =
  match member_opt key json with
  | Some (`List items) -> items
  | Some `Null | None -> []
  | Some _ -> raise_invalidf "field %s must be a list" key

let string_list_field json key =
  list_field json key
  |> List.filter_map Yojson.Safe.Util.to_string_option
  |> normalize_string_list

let parse_json_check json =
  let open Yojson.Safe.Util in
  {
    path = required_string_field json "path";
    equals = (match member_opt "equals" json with Some value -> Some value | None -> None);
    contains = json |> member "contains" |> to_string_option;
    min_int = json |> member "min_int" |> to_int_option;
    present = json |> member "present" |> to_bool_option;
  }

let parse_arg_check json =
  let open Yojson.Safe.Util in
  {
    tool_name = required_string_field json "tool_name";
    path = required_string_field json "path";
    equals = (match member_opt "equals" json with Some value -> Some value | None -> None);
    contains = json |> member "contains" |> to_string_option;
    min_int = json |> member "min_int" |> to_int_option;
    present = json |> member "present" |> to_bool_option;
  }

let parse_recovery_policy json =
  let open Yojson.Safe.Util in
  {
    required = json |> member "required" |> to_bool_option |> Option.value ~default:false;
    success_after_failure =
      json |> member "success_after_failure" |> to_bool_option
      |> Option.value ~default:false;
    max_failures_before_success =
      json |> member "max_failures_before_success" |> to_int_option;
  }

let benchmark_case_of_yojson json =
  let open Yojson.Safe.Util in
  let id = required_string_field json "id" in
  let keeper_profiles = string_list_field json "keeper_profiles" in
  let success_checks = list_field json "success_checks" |> List.map parse_json_check in
  if keeper_profiles = [] then
    raise_invalidf "benchmark case %s must declare keeper_profiles" id;
  if success_checks = [] then
    raise_invalidf "benchmark case %s must declare success_checks" id;
  let max_tool_calls =
    json |> member "max_tool_calls" |> to_int_option |> Option.value ~default:0
  in
  if max_tool_calls < 0 then
    raise_invalidf "benchmark case %s has negative max_tool_calls" id;
  {
    id;
    prompt = required_string_field json "prompt";
    category =
      json |> member "category" |> to_string_option
      |> Option.value ~default:"tool_required"
      |> case_category_of_string;
    keeper_profiles;
    required_tools = string_list_field json "required_tools";
    forbidden_tools = string_list_field json "forbidden_tools";
    max_tool_calls;
    success_checks;
    arg_checks = list_field json "arg_checks" |> List.map parse_arg_check;
    recovery_policy =
      match member_opt "recovery_policy" json with
      | Some (`Assoc _ as value) -> Some (parse_recovery_policy value)
      | _ -> None;
  }

let tool_call_of_yojson json =
  let open Yojson.Safe.Util in
  {
    tool_name =
      (match json |> member "tool_name" |> to_string_option with
       | Some value -> value
       | None -> json |> member "tool" |> to_string_option |> Option.value ~default:"");
    success = json |> member "success" |> to_bool_option |> Option.value ~default:false;
    input = (match member_opt "input" json with Some value -> value | None -> `Assoc []);
    output = member_opt "output" json;
    duration_ms = json |> member "duration_ms" |> to_float_option;
  }

let evidence_run_of_yojson json =
  let open Yojson.Safe.Util in
  {
    case_id = required_string_field json "case_id";
    provider = required_string_field json "provider";
    model = required_string_field json "model";
    keeper_profile = required_string_field json "keeper_profile";
    run_id = json |> member "run_id" |> to_string_option;
    repeat_index = json |> member "repeat_index" |> to_int_option;
    prompt_fingerprint = json |> member "prompt_fingerprint" |> to_string_option;
    task_success = json |> member "task_success" |> to_bool_option;
    final_output = json |> member "final_output" |> to_string_option;
    final_result = member_opt "final_result" json;
    latency_ms = json |> member "latency_ms" |> to_int_option;
    input_tokens = json |> member "input_tokens" |> to_int_option;
    output_tokens = json |> member "output_tokens" |> to_int_option;
    cost_usd = json |> member "cost_usd" |> to_float_option;
    status =
      json |> member "status" |> to_string_option |> Option.value ~default:"ok"
      |> run_status_of_string;
    tool_calls = list_field json "tool_calls" |> List.map tool_call_of_yojson;
  }

let load_cases_from_file path =
  let json = read_json_file path in
  let cases =
    match json with
    | `List items -> items
    | `Assoc _ -> list_field json "cases"
    | _ -> raise_invalidf "invalid benchmark case set at %s" path
  in
  cases |> List.map benchmark_case_of_yojson

let load_runs_from_file path =
  let json = read_json_file path in
  let runs =
    match json with
    | `List items -> items
    | `Assoc _ -> list_field json "runs"
    | _ -> raise_invalidf "invalid benchmark evidence set at %s" path
  in
  runs |> List.map evidence_run_of_yojson
