(** Evidence rows and report assembly for the coding-outcome eval
    (RFC-0396 W2).

    [scripts/harness_coding_eval.sh] appends one JSON row per run to
    [runs.jsonl]; this module decodes those rows, maps them onto
    {!Masc.Eval_harness.eval_run}, and assembles the suite result through
    [summarize_runs] / [compute_pass_at_k]. The pass verdict is carried in
    from the runner's verify execution (RFC-0396 D2) — nothing here re-judges
    an outcome, and a row whose [passed] disagrees with its own
    [status]/[verify_exit] is a decode error, not a repair. *)

open Masc

type run_status =
  | Run_ok
  | Run_timeout
  | Run_provider_error
  | Run_transport_error

let run_status_to_string = function
  | Run_ok -> "ok"
  | Run_timeout -> "timeout"
  | Run_provider_error -> "provider_error"
  | Run_transport_error -> "transport_error"
;;

let run_status_of_string_opt = function
  | "ok" -> Some Run_ok
  | "timeout" -> Some Run_timeout
  | "provider_error" -> Some Run_provider_error
  | "transport_error" -> Some Run_transport_error
  | _ -> None
;;

type row = {
  case_id : string;
  run_index : int;
  run_id : string;
  provider : string;
  model : string;
  status : run_status;
  verify_exit : int option;
  regression_exit : int option;
  passed : bool;
  duration_ms : int;
  recorded_at : float;
  tool_calls : string list;
  input_tokens : int option;
  output_tokens : int option;
  cost_usd : float option;
  error : string option;
}

let row_keys =
  [ "case_id"
  ; "run_index"
  ; "run_id"
  ; "provider"
  ; "model"
  ; "status"
  ; "verify_exit"
  ; "regression_exit"
  ; "passed"
  ; "duration_ms"
  ; "recorded_at"
  ; "tool_calls"
  ; "input_tokens"
  ; "output_tokens"
  ; "cost_usd"
  ; "error"
  ]
;;

let row_of_json json =
  let ( let* ) = Result.bind in
  match json with
  | `Assoc fields ->
    let unknown =
      fields |> List.filter (fun (key, _) -> not (List.mem key row_keys)) |> List.map fst
    in
    let* () =
      if unknown = []
      then Ok ()
      else
        Error
          (Printf.sprintf
             "run row has undeclared key(s): %s"
             (String.concat ", " unknown))
    in
    let str name =
      match List.assoc_opt name fields with
      | Some (`String value) when String.trim value <> "" -> Ok value
      | Some _ -> Error (Printf.sprintf "%s must be a non-empty string" name)
      | None -> Error (Printf.sprintf "%s is missing" name)
    in
    let int name =
      match List.assoc_opt name fields with
      | Some (`Int value) -> Ok value
      | Some _ -> Error (Printf.sprintf "%s must be an integer" name)
      | None -> Error (Printf.sprintf "%s is missing" name)
    in
    let opt_int name =
      match List.assoc_opt name fields with
      | None | Some `Null -> Ok None
      | Some (`Int value) -> Ok (Some value)
      | Some _ -> Error (Printf.sprintf "%s must be an integer or null" name)
    in
    let opt_float name =
      match List.assoc_opt name fields with
      | None | Some `Null -> Ok None
      | Some (`Float value) -> Ok (Some value)
      | Some (`Int value) -> Ok (Some (float_of_int value))
      | Some _ -> Error (Printf.sprintf "%s must be a number or null" name)
    in
    let opt_str name =
      match List.assoc_opt name fields with
      | None | Some `Null -> Ok None
      | Some (`String value) -> Ok (Some value)
      | Some _ -> Error (Printf.sprintf "%s must be a string or null" name)
    in
    let* case_id = str "case_id" in
    let* run_index = int "run_index" in
    let* run_id = str "run_id" in
    let* provider = str "provider" in
    let* model = str "model" in
    let* status_raw = str "status" in
    let* status =
      match run_status_of_string_opt status_raw with
      | Some status -> Ok status
      | None ->
        Error
          (Printf.sprintf
             "status must be one of [ok, timeout, provider_error, transport_error], \
              got %S"
             status_raw)
    in
    let* verify_exit = opt_int "verify_exit" in
    let* regression_exit = opt_int "regression_exit" in
    let* passed =
      match List.assoc_opt "passed" fields with
      | Some (`Bool value) -> Ok value
      | Some _ -> Error "passed must be a boolean"
      | None -> Error "passed is missing"
    in
    let* duration_ms = int "duration_ms" in
    let* recorded_at =
      match List.assoc_opt "recorded_at" fields with
      | Some (`Float value) -> Ok value
      | Some (`Int value) -> Ok (float_of_int value)
      | Some _ -> Error "recorded_at must be a number (unix epoch seconds)"
      | None -> Error "recorded_at is missing"
    in
    let* tool_calls =
      match List.assoc_opt "tool_calls" fields with
      | Some (`List items) ->
        let names =
          List.filter_map (function `String name -> Some name | _ -> None) items
        in
        if List.length names = List.length items
        then Ok names
        else Error "tool_calls must be a list of strings"
      | Some _ -> Error "tool_calls must be a list"
      | None -> Error "tool_calls is missing"
    in
    let* input_tokens = opt_int "input_tokens" in
    let* output_tokens = opt_int "output_tokens" in
    let* cost_usd = opt_float "cost_usd" in
    let* error = opt_str "error" in
    (* A run passes only when verify is green AND, if the case declares a
       PASS_TO_PASS regression guard, that guard stayed green too. A case with
       no regression declared leaves [regression_exit] absent, which cannot
       fail the run. *)
    let regression_ok =
      match regression_exit with
      | None -> true
      | Some code -> code = 0
    in
    let derived_passed = status = Run_ok && verify_exit = Some 0 && regression_ok in
    let* () =
      if Bool.equal derived_passed passed
      then Ok ()
      else
        Error
          (Printf.sprintf
             "row %s r%d: passed=%b disagrees with status=%s verify_exit=%s \
              regression_exit=%s — the runner and the row must tell one story"
             case_id
             run_index
             passed
             (run_status_to_string status)
             (match verify_exit with
              | Some code -> string_of_int code
              | None -> "null")
             (match regression_exit with
              | Some code -> string_of_int code
              | None -> "null"))
    in
    Ok
      { case_id
      ; run_index
      ; run_id
      ; provider
      ; model
      ; status
      ; verify_exit
      ; regression_exit
      ; passed
      ; duration_ms
      ; recorded_at
      ; tool_calls
      ; input_tokens
      ; output_tokens
      ; cost_usd
      ; error
      }
  | _ -> Error "run row must be a JSON object"
;;

let rows_of_jsonl_file path =
  match open_in_bin path with
  | exception Sys_error message -> Error message
  | channel ->
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () ->
         let rec loop line_number acc =
           match input_line channel with
           | exception End_of_file -> Ok (List.rev acc)
           | line when String.trim line = "" -> loop (line_number + 1) acc
           | line ->
             (match Yojson.Safe.from_string line with
              | exception Yojson.Json_error message ->
                Error (Printf.sprintf "%s:%d: %s" path line_number message)
              | json ->
                (match row_of_json json with
                 | Error message ->
                   Error (Printf.sprintf "%s:%d: %s" path line_number message)
                 | Ok row -> loop (line_number + 1) (row :: acc)))
         in
         loop 1 [])
;;

let scenario_of_case (case : Coding_eval_case.t) : Eval_harness.scenario =
  { id = case.id
  ; name = case.id
  ; description = case.description
  ; category = "coding"
  ; goal = case.prompt
  ; setup_messages = []
  ; expected_outcome = "verify exits 0 on the run workspace"
  ; tool_expectations = []
  ; graders = []
  ; tags = [ Coding_eval_case.level_to_string case.level; case.lang ]
  ; ownership = Eval_harness.Self_owned
  }
;;

let eval_run_of_row (row : row) : Eval_harness.eval_run =
  let outcome : Trajectory.trajectory_outcome =
    match row.status with
    | Run_ok -> Trajectory.Completed
    | Run_timeout -> Trajectory.Timeout
    | Run_provider_error ->
      Trajectory.Failed (Option.value row.error ~default:"provider_error")
    | Run_transport_error ->
      Trajectory.Failed (Option.value row.error ~default:"transport_error")
  in
  { scenario_id = row.case_id
  ; run_index = row.run_index
  ; trace_id = row.run_id
  ; scores = []
  ; weighted_score = (if row.passed then 1.0 else 0.0)
  ; passed = row.passed
  ; tool_calls_made = row.tool_calls
  ; total_turns = 1 (* one keeper_msg episode is one turn; tool rounds live inside it *)
  ; total_cost_usd = row.cost_usd
  ; duration_ms = row.duration_ms
  ; outcome
  ; error = row.error
  }
;;

(* Coarse outcome buckets for the v0 report. The RFC-0396 D5 taxonomy
   (edit_miss / wrong_file / ...) needs trajectory analysis and lands with W3;
   these buckets only restate what a row already says, so the report cannot
   claim more than the evidence carries. *)
type bucket =
  | Verify_green
  | Verify_red
  | Bucket_timeout
  | Bucket_provider_error
  | Bucket_transport_error

let bucket_to_string = function
  | Verify_green -> "verify_green"
  | Verify_red -> "verify_red"
  | Bucket_timeout -> "timeout"
  | Bucket_provider_error -> "provider_error"
  | Bucket_transport_error -> "transport_error"
;;

let all_buckets =
  [ Verify_green; Verify_red; Bucket_timeout; Bucket_provider_error
  ; Bucket_transport_error
  ]
;;

let bucket_of_row (row : row) =
  match row.status with
  | Run_ok -> if row.passed then Verify_green else Verify_red
  | Run_timeout -> Bucket_timeout
  | Run_provider_error -> Bucket_provider_error
  | Run_transport_error -> Bucket_transport_error
;;

type suite_report = {
  suite : Eval_harness.eval_suite_result;
  bucket_counts : (bucket * int) list;
  unrun_case_ids : string list;
}

let build_suite ~(cases : Coding_eval_case.t list) ~(rows : row list) ~k =
  let ( let* ) = Result.bind in
  let case_ids = List.map (fun (case : Coding_eval_case.t) -> case.id) cases in
  let orphan_rows =
    rows
    |> List.filter (fun row -> not (List.mem row.case_id case_ids))
    |> List.map (fun row -> row.case_id)
    |> List.sort_uniq String.compare
  in
  let* () =
    if orphan_rows = []
    then Ok ()
    else
      Error
        (Printf.sprintf
           "runs reference unknown case id(s): %s"
           (String.concat ", " orphan_rows))
  in
  let results =
    cases
    |> List.filter_map (fun (case : Coding_eval_case.t) ->
      match List.filter (fun row -> String.equal row.case_id case.id) rows with
      | [] -> None
      | case_rows ->
        let runs =
          case_rows
          |> List.sort (fun (a : row) b -> compare a.run_index b.run_index)
          |> List.map eval_run_of_row
        in
        Some (Eval_harness.summarize_runs ~scenario:(scenario_of_case case) ~k runs))
  in
  let unrun_case_ids =
    cases
    |> List.filter_map (fun (case : Coding_eval_case.t) ->
      if List.exists (fun row -> String.equal row.case_id case.id) rows
      then None
      else Some case.id)
  in
  let total_runs = List.length rows in
  let passed_runs = List.length (List.filter (fun row -> row.passed) rows) in
  let overall_pass_rate =
    if total_runs = 0 then 0.0 else float_of_int passed_runs /. float_of_int total_runs
  in
  let costs = List.filter_map (fun row -> row.cost_usd) rows in
  let total_cost_usd =
    (* A missing cost stays unknown for the total: summing only the known
       subset would understate spend while reading as complete. *)
    if List.length costs = total_runs && total_runs > 0
    then Some (List.fold_left ( +. ) 0.0 costs)
    else None
  in
  let started_at =
    List.fold_left (fun acc row -> Float.min acc row.recorded_at) infinity rows
  in
  let ended_at =
    List.fold_left (fun acc row -> Float.max acc row.recorded_at) neg_infinity rows
  in
  let suite : Eval_harness.eval_suite_result =
    { suite_name = "coding-eval"
    ; started_at = (if total_runs = 0 then 0.0 else started_at)
    ; ended_at = (if total_runs = 0 then 0.0 else ended_at)
    ; results
    ; overall_pass_rate
    ; total_cost_usd
    ; total_runs
    }
  in
  let bucket_counts =
    List.map
      (fun bucket ->
         ( bucket
         , List.length (List.filter (fun row -> bucket_of_row row = bucket) rows) ))
      all_buckets
  in
  Ok { suite; bucket_counts; unrun_case_ids }
;;

let render_report (report : suite_report) =
  let buffer = Buffer.create 2048 in
  Buffer.add_string buffer (Eval_harness.report_to_string report.suite);
  Buffer.add_string buffer "\n## Outcome buckets (coarse, v0)\n\n";
  List.iter
    (fun (bucket, count) ->
       Buffer.add_string
         buffer
         (Printf.sprintf "- %s: %d\n" (bucket_to_string bucket) count))
    report.bucket_counts;
  (match report.unrun_case_ids with
   | [] -> ()
   | unrun ->
     Buffer.add_string
       buffer
       (Printf.sprintf
          "\n## Cases with no recorded runs yet\n\n- %s\n"
          (String.concat "\n- " unrun)));
  Buffer.contents buffer
;;

let report_json (report : suite_report) : Yojson.Safe.t =
  let result_json (result : Eval_harness.eval_result) =
    `Assoc
      [ "case_id", `String result.scenario.id
      ; "runs", `Int (List.length result.runs)
      ; "pass_at_k", `Float result.pass_at_k
      ; "mean_score", `Float result.mean_score
      ; "consistency", `Float result.consistency
      ; "ci95_low", `Float result.ci95_low
      ; "ci95_high", `Float result.ci95_high
      ; "min_runs_met", `Bool result.min_runs_met
      ; ( "total_cost_usd"
        , match result.total_cost_usd with
          | Some cost -> `Float cost
          | None -> `Null )
      ]
  in
  `Assoc
    [ "suite_name", `String report.suite.suite_name
    ; "total_runs", `Int report.suite.total_runs
    ; "overall_pass_rate", `Float report.suite.overall_pass_rate
    ; ( "total_cost_usd"
      , match report.suite.total_cost_usd with
        | Some cost -> `Float cost
        | None -> `Null )
    ; "results", `List (List.map result_json report.suite.results)
    ; ( "bucket_counts"
      , `Assoc
          (List.map
             (fun (bucket, count) -> bucket_to_string bucket, `Int count)
             report.bucket_counts) )
    ; ( "unrun_case_ids"
      , `List (List.map (fun id -> `String id) report.unrun_case_ids) )
    ]
;;
