module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

open Tool_call_quality_benchmark_types

let default_case_set_path ~repo_root =
  Filename.concat repo_root "benchmarks/data/tool_call_quality_cases.json"

let default_evidence_path ~repo_root =
  Filename.concat repo_root "test/fixtures/tool_call_quality_benchmark/evidence_runs.json"

let normalize_string_list items =
  items
  |> List.map String.trim
  |> List.filter (fun item -> not (String.equal item ""))
  |> Json_util.dedupe_keep_order

let errorf fmt = Printf.ksprintf (fun s -> Error s) fmt

let ( let* ) = Result.bind

let rec map_m f = function
  | [] -> Ok []
  | x :: xs ->
      let* y = f x in
      let* ys = map_m f xs in
      Ok (y :: ys)

let run_status_of_string raw =
  match String.trim (String.lowercase_ascii raw) with
  | "" | "ok" -> Run_ok
  | "unsupported" -> Run_unsupported
  | "runtime_unreachable" -> Run_runtime_unreachable
  | other -> Run_other other

let case_category_of_string raw =
  match String.trim (String.lowercase_ascii raw) with
  | "tool_use" -> Ok Tool_use
  | "tool_forbidden" -> Ok Tool_forbidden
  | "recovery_required" -> Ok Recovery_required
  | "multi_step" -> Ok Multi_step
  | other -> errorf "unknown tool-call-quality category: %s" other

let read_json_file path =
  match Safe_ops.read_json_file_safe path with
  | Ok json -> Ok json
  | Error err -> errorf "failed to read %s: %s" path err

let member_opt key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let required_string_field json key =
  match Json_util.get_string json key with
  | Some value when not (String.equal (String.trim value) "") -> Ok value
  | _ -> errorf "missing required string field %s" key

let list_field json key =
  match member_opt key json with
  | Some (`List items) -> Ok items
  | Some `Null | None -> Ok []
  | Some _ -> errorf "field %s must be a list" key

let string_list_field json key =
  let* items = list_field json key in
  Ok (items
      |> List.filter_map (function `String s -> Some s | _ -> None)
      |> normalize_string_list)

let selector_list_field json key =
  let* items = list_field json key in
  items
  |> map_m (fun item ->
         match Eval_tool_selector.of_yojson item with
         | Ok selector -> Ok selector
         | Error msg -> errorf "invalid %s entry: %s" key msg)

let parse_json_check json =
  let* path = required_string_field json "path" in
  Ok {
    path;
    equals = member_opt "equals" json;
    contains = Json_util.get_string json "contains";
    min_int = Json_util.get_int json "min_int";
    present = Json_util.get_bool json "present";
  }

let parse_arg_check json =
  let* tool_name = required_string_field json "tool_name" in
  let* path = required_string_field json "path" in
  Ok {
    tool_name;
    path;
    equals = member_opt "equals" json;
    contains = Json_util.get_string json "contains";
    min_int = Json_util.get_int json "min_int";
    present = Json_util.get_bool json "present";
  }

let parse_recovery_policy json =
  {
    required = Json_util.get_bool json "required" |> Option.value ~default:false;
    success_after_failure =
      Json_util.get_bool json "success_after_failure"
      |> Option.value ~default:false;
    max_failures_before_success =
      Json_util.get_int json "max_failures_before_success";
  }

let benchmark_case_of_yojson json =
  let* id = required_string_field json "id" in
  let* keeper_profiles = string_list_field json "keeper_profiles" in
  let* success_check_items = list_field json "success_checks" in
  let* success_checks = map_m parse_json_check success_check_items in
  let* () =
    if Stdlib.List.length keeper_profiles = 0 then
      errorf "benchmark case %s must declare keeper_profiles" id
    else Ok ()
  in
  let* () =
    if Stdlib.List.length success_checks = 0 then
      errorf "benchmark case %s must declare success_checks" id
    else Ok ()
  in
  let max_tool_calls =
    Json_util.get_int json "max_tool_calls" |> Option.value ~default:0
  in
  let* () =
    if max_tool_calls < 0 then
      errorf "benchmark case %s has negative max_tool_calls" id
    else Ok ()
  in
  let* prompt = required_string_field json "prompt" in
  let* forbidden_tools = string_list_field json "forbidden_tools" in
  let* forbidden_selectors = selector_list_field json "forbidden_selectors" in
  let* category =
    Json_util.get_string json "category"
    |> Option.value ~default:"tool_use"
    |> case_category_of_string
  in
  let* arg_check_items = list_field json "arg_checks" in
  let* arg_checks = map_m parse_arg_check arg_check_items in
  let recovery_policy =
    match member_opt "recovery_policy" json with
    | Some (`Assoc _ as value) -> Some (parse_recovery_policy value)
    | _ -> None
  in
  Ok {
    id;
    prompt;
    category;
    keeper_profiles;
    forbidden_tools;
    forbidden_selectors;
    max_tool_calls;
    success_checks;
    arg_checks;
    recovery_policy;
  }

let tool_call_of_yojson json =
  {
    tool_name =
      (match Json_util.get_string json "tool_name" with
       | Some value -> value
       | None -> Json_util.get_string_with_default json ~key:"tool" ~default:"");
    success = Json_util.get_bool json "success" |> Option.value ~default:false;
    input = (match member_opt "input" json with Some value -> value | None -> `Assoc []);
    output = member_opt "output" json;
    route_evidence = member_opt "route_evidence" json;
    duration_ms = Json_util.get_float json "duration_ms";
  }

let evidence_run_of_yojson json =
  let* case_id = required_string_field json "case_id" in
  let* provider = required_string_field json "provider" in
  let* model = required_string_field json "model" in
  let* keeper_profile = required_string_field json "keeper_profile" in
  let* tool_call_items = list_field json "tool_calls" in
  Ok {
    case_id;
    provider;
    model;
    keeper_profile;
    run_id = Json_util.get_string json "run_id";
    repeat_index = Json_util.get_int json "repeat_index";
    prompt_fingerprint = Json_util.get_string json "prompt_fingerprint";
    task_success = Json_util.get_bool json "task_success";
    final_output = Json_util.get_string json "final_output";
    final_result = member_opt "final_result" json;
    latency_ms = Json_util.get_int json "latency_ms";
    input_tokens = Json_util.get_int json "input_tokens";
    output_tokens = Json_util.get_int json "output_tokens";
    cost_usd = Json_util.get_float json "cost_usd";
    status =
      Json_util.get_string json "status" |> Option.value ~default:"ok"
      |> run_status_of_string;
    tool_calls = List.map tool_call_of_yojson tool_call_items;
  }

let load_cases_from_file path =
  let* json = read_json_file path in
  let* cases =
    match json with
    | `List items -> Ok items
    | `Assoc _ -> list_field json "cases"
    | _ -> errorf "invalid benchmark case set at %s" path
  in
  map_m benchmark_case_of_yojson cases

let load_runs_from_file path =
  let* json = read_json_file path in
  let* runs =
    match json with
    | `List items -> Ok items
    | `Assoc _ -> list_field json "runs"
    | _ -> errorf "invalid benchmark evidence set at %s" path
  in
  map_m evidence_run_of_yojson runs
