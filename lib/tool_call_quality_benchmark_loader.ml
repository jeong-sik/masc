open Tool_call_quality_benchmark_types

let default_case_set_path ~repo_root =
  Filename.concat repo_root "benchmark/tool_call_quality_cases.json"
;;

let default_evidence_path ~repo_root =
  Filename.concat repo_root "test/fixtures/tool_call_quality_benchmark/evidence_runs.json"
;;

let dedupe_keep_order items =
  let seen = Hashtbl.create (List.length items) in
  List.filter
    (fun item ->
       if Hashtbl.mem seen item
       then false
       else (
         Hashtbl.add seen item ();
         true))
    items
;;

let normalize_string_list items =
  items
  |> List.map String.trim
  |> List.filter (fun item -> item <> "")
  |> dedupe_keep_order
;;

let errorf fmt = Printf.ksprintf (fun s -> Error s) fmt
let ( let* ) = Result.bind

let rec map_m f = function
  | [] -> Ok []
  | x :: xs ->
    let* y = f x in
    let* ys = map_m f xs in
    Ok (y :: ys)
;;

let run_status_of_string raw =
  match String.trim (String.lowercase_ascii raw) with
  | "" | "ok" -> Run_ok
  | "unsupported" -> Run_unsupported
  | "runtime_unreachable" -> Run_runtime_unreachable
  | other -> Run_other other
;;

let case_category_of_string raw =
  match String.trim (String.lowercase_ascii raw) with
  | "tool_required" -> Ok Tool_required
  | "tool_forbidden" -> Ok Tool_forbidden
  | "recovery_required" -> Ok Recovery_required
  | "multi_step" -> Ok Multi_step
  | other -> errorf "unknown tool-call-quality category: %s" other
;;

let read_json_file path =
  match Safe_ops.read_json_file_safe path with
  | Ok json -> Ok json
  | Error err -> errorf "failed to read %s: %s" path err
;;

let member_opt key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let required_string_field json key =
  match Yojson.Safe.Util.member key json |> Yojson.Safe.Util.to_string_option with
  | Some value when String.trim value <> "" -> Ok value
  | _ -> errorf "missing required string field %s" key
;;

let list_field json key =
  match member_opt key json with
  | Some (`List items) -> Ok items
  | Some `Null | None -> Ok []
  | Some _ -> errorf "field %s must be a list" key
;;

let string_list_field json key =
  let* items = list_field json key in
  Ok (items |> List.filter_map Yojson.Safe.Util.to_string_option |> normalize_string_list)
;;

let parse_json_check json =
  let open Yojson.Safe.Util in
  let* path = required_string_field json "path" in
  Ok
    { path
    ; equals =
        (match member_opt "equals" json with
         | Some value -> Some value
         | None -> None)
    ; contains = json |> member "contains" |> to_string_option
    ; min_int = json |> member "min_int" |> to_int_option
    ; present = json |> member "present" |> to_bool_option
    }
;;

let parse_arg_check json =
  let open Yojson.Safe.Util in
  let* tool_name = required_string_field json "tool_name" in
  let* path = required_string_field json "path" in
  Ok
    { tool_name
    ; path
    ; equals =
        (match member_opt "equals" json with
         | Some value -> Some value
         | None -> None)
    ; contains = json |> member "contains" |> to_string_option
    ; min_int = json |> member "min_int" |> to_int_option
    ; present = json |> member "present" |> to_bool_option
    }
;;

let parse_recovery_policy json =
  let open Yojson.Safe.Util in
  { required = json |> member "required" |> to_bool_option |> Option.value ~default:false
  ; success_after_failure =
      json
      |> member "success_after_failure"
      |> to_bool_option
      |> Option.value ~default:false
  ; max_failures_before_success =
      json |> member "max_failures_before_success" |> to_int_option
  }
;;

let benchmark_case_of_yojson json =
  let open Yojson.Safe.Util in
  let* id = required_string_field json "id" in
  let* keeper_profiles = string_list_field json "keeper_profiles" in
  let* success_check_items = list_field json "success_checks" in
  let* success_checks = map_m parse_json_check success_check_items in
  let* () =
    if keeper_profiles = []
    then errorf "benchmark case %s must declare keeper_profiles" id
    else Ok ()
  in
  let* () =
    if success_checks = []
    then errorf "benchmark case %s must declare success_checks" id
    else Ok ()
  in
  let max_tool_calls =
    json |> member "max_tool_calls" |> to_int_option |> Option.value ~default:0
  in
  let* () =
    if max_tool_calls < 0
    then errorf "benchmark case %s has negative max_tool_calls" id
    else Ok ()
  in
  let* prompt = required_string_field json "prompt" in
  let* required_tools = string_list_field json "required_tools" in
  let* forbidden_tools = string_list_field json "forbidden_tools" in
  let* category =
    json
    |> member "category"
    |> to_string_option
    |> Option.value ~default:"tool_required"
    |> case_category_of_string
  in
  let* arg_check_items = list_field json "arg_checks" in
  let* arg_checks = map_m parse_arg_check arg_check_items in
  let recovery_policy =
    match member_opt "recovery_policy" json with
    | Some (`Assoc _ as value) -> Some (parse_recovery_policy value)
    | _ -> None
  in
  Ok
    { id
    ; prompt
    ; category
    ; keeper_profiles
    ; required_tools
    ; forbidden_tools
    ; max_tool_calls
    ; success_checks
    ; arg_checks
    ; recovery_policy
    }
;;

let tool_call_of_yojson json =
  let open Yojson.Safe.Util in
  { tool_name =
      (match json |> member "tool_name" |> to_string_option with
       | Some value -> value
       | None -> json |> member "tool" |> to_string_option |> Option.value ~default:"")
  ; success = json |> member "success" |> to_bool_option |> Option.value ~default:false
  ; input =
      (match member_opt "input" json with
       | Some value -> value
       | None -> `Assoc [])
  ; output = member_opt "output" json
  ; duration_ms = json |> member "duration_ms" |> to_float_option
  }
;;

let evidence_run_of_yojson json =
  let open Yojson.Safe.Util in
  let* case_id = required_string_field json "case_id" in
  let* provider = required_string_field json "provider" in
  let* model = required_string_field json "model" in
  let* keeper_profile = required_string_field json "keeper_profile" in
  let* tool_call_items = list_field json "tool_calls" in
  Ok
    { case_id
    ; provider
    ; model
    ; keeper_profile
    ; run_id = json |> member "run_id" |> to_string_option
    ; repeat_index = json |> member "repeat_index" |> to_int_option
    ; prompt_fingerprint = json |> member "prompt_fingerprint" |> to_string_option
    ; task_success = json |> member "task_success" |> to_bool_option
    ; final_output = json |> member "final_output" |> to_string_option
    ; final_result = member_opt "final_result" json
    ; latency_ms = json |> member "latency_ms" |> to_int_option
    ; input_tokens = json |> member "input_tokens" |> to_int_option
    ; output_tokens = json |> member "output_tokens" |> to_int_option
    ; cost_usd = json |> member "cost_usd" |> to_float_option
    ; status =
        json
        |> member "status"
        |> to_string_option
        |> Option.value ~default:"ok"
        |> run_status_of_string
    ; tool_calls = List.map tool_call_of_yojson tool_call_items
    }
;;

let load_cases_from_file path =
  let* json = read_json_file path in
  let* cases =
    match json with
    | `List items -> Ok items
    | `Assoc _ -> list_field json "cases"
    | _ -> errorf "invalid benchmark case set at %s" path
  in
  map_m benchmark_case_of_yojson cases
;;

let load_runs_from_file path =
  let* json = read_json_file path in
  let* runs =
    match json with
    | `List items -> Ok items
    | `Assoc _ -> list_field json "runs"
    | _ -> errorf "invalid benchmark evidence set at %s" path
  in
  map_m evidence_run_of_yojson runs
;;
