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

type memory_mode = Seeded | Verified | Filtered | Source_bound | Off

let memory_mode_to_string = function
  | Seeded -> "seeded"
  | Verified -> "verified"
  | Filtered -> "filtered"
  | Source_bound -> "source-bound"
  | Off -> "off"
;;

let memory_mode_of_string = function
  | "seeded" -> Ok Seeded
  | "verified" -> Ok Verified
  | "filtered" -> Ok Filtered
  | "source-bound" -> Ok Source_bound
  | "off" -> Ok Off
  | value -> Error (Printf.sprintf "unknown memory_mode: %S" value)
;;

type row = {
  case_id : string;
  run_index : int;
  run_id : string;
  operation_id : Keeper_operation_id.t option;
  (* The accepted chat operation, observed from the admission response. None
     means no accepted identity was observed; never reconstructed from run_id. *)
  provider : string;
  model : string;
  experiment_digest : string;
  memory_mode : memory_mode;
  status : run_status;
  verify_exit : int option;
  regression_exit : int option;
  (* Deterministic trajectory signals the harness records by comparing the
     graded workspace against the case's pristine copy (content diff, never
     output parsing): how many pristine source files the candidate changed, and
     how many of the reference-solution target files it changed. They split a
     verify-red run into gave-up / off-target / wrong-solution without guessing.
     [build_exit] is the optional build-probe exit code that further separates a
     non-compiling edit from a wrong one. Absent on rows the harness did not
     instrument, which degrade to the coarse [Verify_red] bucket. *)
  edited_source_files : int option;
  edited_target_files : int option;
  build_exit : int option;
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
  ; "operation_id"
  ; "provider"
  ; "model"
  ; "experiment_digest"
  ; "memory_mode"
  ; "status"
  ; "verify_exit"
  ; "regression_exit"
  ; "edited_source_files"
  ; "edited_target_files"
  ; "build_exit"
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
  let open Result.Syntax in
  match json with
  | `Assoc fields ->
    let names = List.map fst fields in
    let* () =
      if List.length names = List.length (List.sort_uniq String.compare names)
      then Ok ()
      else Error "run row has duplicate object keys"
    in
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
    let* operation_id =
      match List.assoc_opt "operation_id" fields with
      | None | Some `Null -> Ok None
      | Some (`String value) ->
        Keeper_operation_id.of_string value |> Result.map Option.some
      | Some _ -> Error "operation_id must be a string or null"
    in
    let* provider = str "provider" in
    let* model = str "model" in
    let* experiment_digest = str "experiment_digest" in
    let* () =
      if String.length experiment_digest = 64
         && String.for_all
              (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
              experiment_digest
      then Ok ()
      else Error "experiment_digest must be a lowercase SHA256 hex digest"
    in
    let* memory_mode_raw = str "memory_mode" in
    let* memory_mode = memory_mode_of_string memory_mode_raw in
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
    let* edited_source_files = opt_int "edited_source_files" in
    let* edited_target_files = opt_int "edited_target_files" in
    let* build_exit = opt_int "build_exit" in
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
    let* () =
      match cost_usd with
      | None -> Ok ()
      | Some cost when Float.is_finite cost && cost >= 0.0 -> Ok ()
      | Some _ -> Error "cost_usd must be finite and nonnegative, or null"
    in
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
      ; operation_id
      ; provider
      ; model
      ; experiment_digest
      ; memory_mode
      ; status
      ; verify_exit
      ; regression_exit
      ; edited_source_files
      ; edited_target_files
      ; build_exit
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

(* Failure taxonomy for the report (RFC-0396 D5). Each bucket is decided by a
   typed run signal, never by parsing model output or tool-name strings:

   - [Budget_exceeded] / [Provider_error] / [Transport_error] come from the run
     status (a wall-clock timeout, a provider refusal, a transport fault).
   - [Regressed] uses the PASS_TO_PASS signal: verify went green but a declared
     regression broke.
   - [Gave_up] / [Off_target_edit] / [Wrong_solution] / [Build_failed] split a
     verify-red run by the harness's deterministic file-delta signals -- how
     many pristine source files the candidate changed, how many of them were the
     reference-solution targets, and whether the optional build probe stayed
     green. Nothing is guessed: a run that changed no source is [Gave_up]; one
     that changed source but never the target file is [Off_target_edit]; one
     that changed the target but fails the build probe is [Build_failed], else
     [Wrong_solution].
   - [Verify_red] is the honest fallback for a verify-red run the harness did
     not instrument with those signals (older rows, or a run with no workspace);
     the report degrades to the coarse bucket rather than inventing a finer one. *)
type bucket =
  | Verify_green
  | Regressed
  | Gave_up
  | Off_target_edit
  | Build_failed
  | Wrong_solution
  | Verify_red
  | Budget_exceeded
  | Provider_error
  | Transport_error

let bucket_to_string = function
  | Verify_green -> "verify_green"
  | Regressed -> "regressed"
  | Gave_up -> "gave_up"
  | Off_target_edit -> "off_target_edit"
  | Build_failed -> "build_failed"
  | Wrong_solution -> "wrong_solution"
  | Verify_red -> "verify_red"
  | Budget_exceeded -> "budget_exceeded"
  | Provider_error -> "provider_error"
  | Transport_error -> "transport_error"
;;

let all_buckets =
  [ Verify_green; Regressed; Gave_up; Off_target_edit; Build_failed
  ; Wrong_solution; Verify_red; Budget_exceeded; Provider_error; Transport_error
  ]
;;

let bucket_of_row (row : row) =
  match row.status with
  | Run_ok ->
    if row.passed
    then Verify_green
    else (
      match row.verify_exit, row.regression_exit with
      (* verify went green but the PASS_TO_PASS regression broke: a distinct,
         typed failure the taxonomy names on its own rather than lumping with a
         plain wrong-output run. *)
      | Some 0, Some code when code <> 0 -> Regressed
      | _ ->
        (* verify itself is red: attribute by the deterministic trajectory
           signals when the harness recorded them, else fall back to the coarse
           bucket. [edited_target_files] > 0 means the candidate did edit a file
           the reference fix also edits, so the failure is in its logic (or its
           build); = 0 with some source edited means it edited the wrong place;
           = 0 with nothing edited means it did not attempt the fix. *)
        (match row.edited_target_files, row.edited_source_files with
         | Some target, _ when target > 0 ->
           (match row.build_exit with
            | Some code when code <> 0 -> Build_failed
            | _ -> Wrong_solution)
         | Some 0, Some source when source > 0 -> Off_target_edit
         | Some 0, Some 0 -> Gave_up
         | _ -> Verify_red))
  | Run_timeout -> Budget_exceeded
  | Run_provider_error -> Provider_error
  | Run_transport_error -> Transport_error
;;

(** These are configured model labels from the producer, not an attestation of
    the actual provider model selected after runtime failover. Every statistical
    result belongs to exactly one such cohort and one immutable experiment. *)
type cohort = {
  provider : string;
  model : string;
  memory_mode : memory_mode;
  experiment_digest : string;
}

module Cohorts = Map.Make (struct
  type t = cohort
  let compare = Stdlib.compare
end)

module Runs = Set.Make (struct
  type t = cohort * string
  let compare = Stdlib.compare
end)
module Repeats = Set.Make (struct
  type t = cohort * string * int
  let compare = Stdlib.compare
end)

type cohort_report = {
  cohort : cohort;
  suite : Eval_harness.eval_suite_result;
  bucket_counts : (bucket * int) list;
  unrun_case_ids : string list;
}

type suite_report = {
  cohorts : cohort_report list;
  case_ids : string list;
}

type cost_summary = {
  observed_runs : int;
  unreported_runs : int;
  known_cost_usd : float;
  total_cost_usd : float option;
  cost_per_solved_task_usd : float option;
}

let cohort_of_row (row : row) : cohort =
  { provider = row.provider; model = row.model; memory_mode = row.memory_mode;
    experiment_digest = row.experiment_digest }
;;

(* The numerator includes failed episodes and their reported retry costs. It is
   complete only when every episode has an observed full cost; no solved episode
   or missing costs leave cost-per-solved unknown, never zero. *)
let summarize_costs (runs : Eval_harness.eval_run list) =
  let observed_runs, known_cost_usd, solved =
    List.fold_left
      (fun (observed, known, solved) (run : Eval_harness.eval_run) ->
         let solved = solved + if run.passed then 1 else 0 in
         match run.total_cost_usd with
         | Some cost -> observed + 1, known +. cost, solved
         | None -> observed, known, solved)
      (0, 0.0, 0)
      runs
  in
  let unreported_runs = List.length runs - observed_runs in
  let total_cost_usd =
    if runs <> [] && unreported_runs = 0 then Some known_cost_usd else None
  in
  let cost_per_solved_task_usd =
    match total_cost_usd with
    | Some cost when solved > 0 -> Some (cost /. float_of_int solved)
    | Some _ | None -> None
  in
  { observed_runs; unreported_runs; known_cost_usd; total_cost_usd;
    cost_per_solved_task_usd }
;;

let build_cohort ~cases ~rows ~k cohort =
  let results =
    cases
    |> List.filter_map (fun (case : Coding_eval_case.t) ->
      match List.filter (fun (row : row) -> String.equal row.case_id case.id) rows with
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
      if List.exists (fun (row : row) -> String.equal row.case_id case.id) rows
      then None else Some case.id)
  in
  let total_runs = List.length rows in
  let passed_runs = List.length (List.filter (fun (row : row) -> row.passed) rows) in
  let costs = summarize_costs (List.map eval_run_of_row rows) in
  let started_at =
    List.fold_left (fun acc (row : row) -> Float.min acc row.recorded_at) infinity rows
  in
  let ended_at =
    List.fold_left (fun acc (row : row) -> Float.max acc row.recorded_at) neg_infinity rows
  in
  let suite : Eval_harness.eval_suite_result =
    { suite_name = "coding-eval"
    ; started_at = (if total_runs = 0 then 0.0 else started_at)
    ; ended_at = (if total_runs = 0 then 0.0 else ended_at)
    ; results
    ; overall_pass_rate =
        (if total_runs = 0 then 0.0 else float_of_int passed_runs /. float_of_int total_runs)
    ; total_cost_usd = costs.total_cost_usd
    ; total_runs
    }
  in
  let bucket_counts =
    List.map
      (fun bucket ->
         bucket, List.length (List.filter (fun row -> bucket_of_row row = bucket) rows))
      all_buckets
  in
  { cohort; suite; bucket_counts; unrun_case_ids }
;;

let build_suite ~(cases : Coding_eval_case.t list) ~(rows : row list) ~k =
  let open Result.Syntax in
  let case_ids = List.map (fun (case : Coding_eval_case.t) -> case.id) cases in
  let* groups, _, _ =
    List.fold_left
      (fun acc (row : row) ->
         let* groups, run_ids, repeats = acc in
         let cohort = cohort_of_row row in
         let run_id = cohort, row.run_id in
         let repeat = cohort, row.case_id, row.run_index in
         if not (List.mem row.case_id case_ids) then
           Error (Printf.sprintf "run references unknown case id: %s" row.case_id)
         else if Runs.mem run_id run_ids then
           Error (Printf.sprintf "duplicate cohort run_id: %s" row.run_id)
         else if Repeats.mem repeat repeats then
           Error (Printf.sprintf "duplicate cohort repeat: %s r%d" row.case_id row.run_index)
         else
           let prior = match Cohorts.find_opt cohort groups with Some prior -> prior | None -> [] in
           Ok (Cohorts.add cohort (row :: prior) groups,
               Runs.add run_id run_ids, Repeats.add repeat repeats))
      (Ok (Cohorts.empty, Runs.empty, Repeats.empty)) rows
  in
  let cohorts = Cohorts.bindings groups |> List.map (fun (cohort, rows) ->
    build_cohort ~cases ~rows:(List.rev rows) ~k cohort) in
  Ok { cohorts; case_ids }
;;

let runs_of_cohort (report : cohort_report) =
  List.concat_map (fun (result : Eval_harness.eval_result) -> result.runs) report.suite.results
;;

let runs_of_report (report : suite_report) = List.concat_map runs_of_cohort report.cohorts

let cost_to_string = function Some cost -> Printf.sprintf "%.6f" cost | None -> "unknown"

let render_report (report : suite_report) =
  let buffer = Buffer.create 2048 in
  let runs = runs_of_report report in
  Buffer.add_string buffer "# Coding outcome evaluation\n\n";
  Buffer.add_string buffer
    (Printf.sprintf "Recorded episodes: %d. Separate cohorts: %d.\n\n"
       (List.length runs) (List.length report.cohorts));
  Buffer.add_string buffer
    "Provider/model are configured labels; they do not attest the selected model after failover.\n\n";
  List.iteri
    (fun index (report : cohort_report) ->
       Buffer.add_string buffer (Printf.sprintf "## Cohort %d\n\n" (index + 1));
       Buffer.add_string buffer
         (Printf.sprintf "Provider: `%s`; model: `%s`; memory: `%s`; experiment: `%s`.\n\n"
            report.cohort.provider report.cohort.model
            (memory_mode_to_string report.cohort.memory_mode) report.cohort.experiment_digest);
       Buffer.add_string buffer (Eval_harness.report_to_string report.suite);
       let costs = summarize_costs (runs_of_cohort report) in
       Buffer.add_string buffer
         (Printf.sprintf
            "\nCost coverage: %d observed / %d unreported episodes. Known subtotal: USD %.6f. Full total: %s. Cost per solved acceptance: %s.\n"
            costs.observed_runs costs.unreported_runs costs.known_cost_usd
            (cost_to_string costs.total_cost_usd) (cost_to_string costs.cost_per_solved_task_usd));
       Buffer.add_string buffer "\n### Failure taxonomy (RFC-0396 D5)\n\n";
       List.iter (fun (bucket, count) -> Buffer.add_string buffer
         (Printf.sprintf "- %s: %d\n" (bucket_to_string bucket) count)) report.bucket_counts;
       match report.unrun_case_ids with
       | [] -> ()
       | unrun -> Buffer.add_string buffer
           (Printf.sprintf "\nCases with no recorded runs: %s\n\n" (String.concat ", " unrun)))
    report.cohorts;
  if report.cohorts = [] then
    Buffer.add_string buffer ("No cohort has recorded runs. Corpus cases: "
                              ^ String.concat ", " report.case_ids ^ "\n");
  Buffer.contents buffer
;;

let cost_accounting_fields summary =
  let number = function Some cost -> `Float cost | None -> `Null in
  [ "observed_runs", `Int summary.observed_runs
  ; "unreported_runs", `Int summary.unreported_runs
  ; "known_cost_usd", `Float summary.known_cost_usd
  ; "total_cost_usd", number summary.total_cost_usd ]
;;

let cost_summary_json summary =
  `Assoc (cost_accounting_fields summary
          @ [ "cost_per_solved_task_usd",
              (match summary.cost_per_solved_task_usd with
               | Some cost -> `Float cost
               | None -> `Null) ])
;;

let report_json (report : suite_report) : Yojson.Safe.t =
  let result_json (result : Eval_harness.eval_result) =
    `Assoc
      [ "case_id", `String result.scenario.id
      ; "runs", `Int (List.length result.runs)
      ; "passed_runs", `Int (List.length (List.filter (fun (run : Eval_harness.eval_run) -> run.passed) result.runs))
      ; "pass_at_k", `Float result.pass_at_k
      ; "mean_score", `Float result.mean_score
      ; "consistency", `Float result.consistency
      ; "ci95_low", `Float result.ci95_low
      ; "ci95_high", `Float result.ci95_high
      ; "min_runs_met", `Bool result.min_runs_met
      ; "cost", cost_summary_json (summarize_costs result.runs)
      ]
  in
  let cohort_json (report : cohort_report) =
    `Assoc
      [ "provider", `String report.cohort.provider
      ; "model", `String report.cohort.model
      ; "memory_mode", `String (memory_mode_to_string report.cohort.memory_mode)
      ; "experiment_digest", `String report.cohort.experiment_digest
      ; "total_runs", `Int report.suite.total_runs
      ; "overall_pass_rate", `Float report.suite.overall_pass_rate
      ; "cost", cost_summary_json (summarize_costs (runs_of_cohort report))
      ; "results", `List (List.map result_json report.suite.results)
      ; "bucket_counts", `Assoc (List.map
          (fun (bucket, count) -> bucket_to_string bucket, `Int count) report.bucket_counts)
      ; "unrun_case_ids", `List (List.map (fun id -> `String id) report.unrun_case_ids)
      ]
  in
  let runs = runs_of_report report in
  `Assoc
    [ "suite_name", `String "coding-eval"
    ; "model_identity_scope", `String "configured_model"
    ; "total_runs", `Int (List.length runs)
    ; "passed_runs", `Int (List.length (List.filter (fun (run : Eval_harness.eval_run) -> run.passed) runs))
    ; "cost", `Assoc (cost_accounting_fields (summarize_costs runs))
    ; "corpus_case_ids", `List (List.map (fun id -> `String id) report.case_ids)
    ; "cohorts", `List (List.map cohort_json report.cohorts)
    ]
;;
