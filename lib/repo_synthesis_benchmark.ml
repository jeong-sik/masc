type question = {
  question_id : string;
  title : string;
  question : string;
  artifact_scope : string list;
  required_claims : string list;
  gold_paths : string list;
  difficulty : string option;
  tags : string list;
}

type answer = {
  question_id : string;
  claims : string list;
  cited_paths : string list;
  latency_ms : int;
}

type question_score = {
  question_id : string;
  evidence_precision : float;
  claim_coverage : float;
  unsupported_claim_penalty : float;
  latency_ms : int;
  matched_claims : string list;
  missing_claims : string list;
  matched_paths : string list;
  unsupported_claims : string list;
}

type score_summary = {
  answer_set_label : string;
  question_count : int;
  answered_count : int;
  evidence_precision : float;
  claim_coverage : float;
  unsupported_claim_penalty : float;
  avg_latency_ms : float;
  composite_score : float;
  per_question : question_score list;
}

type run_record = {
  benchmark_run_id : string;
  created_at : string;
  created_by : string option;
  goal : string;
  question : string;
  question_id : string option;
  repo_root : string;
  artifact_scope : string list;
  program_note : string option;
  baseline_label : string option;
  model : string option;
  max_workers : int;
  time_budget_sec : int;
  workload_profile : string;
  operation_id : string option;
  trace_id : string option;
  session_id : string option;
  report_json_path : string option;
  report_md_path : string option;
  proof_json_path : string option;
  proof_md_path : string option;
  dataset_ref : string option;
  case_refs : string list;
  planned_worker_roles : string list;
  recommended_next_tools : string list;
  status : string;
}

let bench_root ~base_path =
  Filename.concat
    (Common.masc_dir_from_base_path ~base_path)
    "repo-synthesis-benchmarks"


let validate_run_id run_id =
  let run_id = String.trim run_id in
  if run_id = "" then
    Error "benchmark run id cannot be empty"
  else if String.length run_id > 128 then
    Error "benchmark run id too long (max 128 chars)"
  else if String.contains run_id '/' || String.contains run_id '\\' then
    Error "benchmark run id cannot contain path separators"
  else if String_util.contains_substring run_id ".." then
    Error "benchmark run id cannot contain traversal segments"
  else if
    not
      (String.for_all
         (function
           | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '.' | '_' | '-' -> true
           | _ -> false)
         run_id)
  then
    Error
      "benchmark run id may only contain letters, digits, dot, underscore, and hyphen"
  else
    Ok run_id

let run_dir_unchecked ~base_path run_id = Filename.concat (bench_root ~base_path) run_id
let run_json_path_unchecked ~base_path run_id =
  Filename.concat (run_dir_unchecked ~base_path run_id) "run.json"

let score_json_path_unchecked ~base_path run_id =
  Filename.concat (run_dir_unchecked ~base_path run_id) "score.json"

let run_dir ~base_path run_id =
  match validate_run_id run_id with
  | Ok run_id -> run_dir_unchecked ~base_path run_id
  | Error msg -> invalid_arg msg

let run_json_path ~base_path run_id =
  match validate_run_id run_id with
  | Ok run_id -> run_json_path_unchecked ~base_path run_id
  | Error msg -> invalid_arg msg

let score_json_path ~base_path run_id =
  match validate_run_id run_id with
  | Ok run_id -> score_json_path_unchecked ~base_path run_id
  | Error msg -> invalid_arg msg

let default_question_set_path ~repo_root =
  Filename.concat repo_root "benchmark/repo_synthesis_question_set.json"

let write_json_file path json =
  Fs_compat.mkdir_p (Filename.dirname path);
  let tmp = path ^ ".tmp" in
  Fs_compat.save_file tmp (Yojson.Safe.pretty_to_string json);
  Unix.rename tmp path

let read_json_file_opt path =
  match Safe_ops.read_json_file_safe path with
  | Ok json -> Some json
  | Error _ -> None

let normalize_ci_string value =
  value |> String.trim |> String.lowercase_ascii

let normalize_rel_path value =
  let trimmed = String.trim value in
  let normalized =
    if String.starts_with ~prefix:"./" trimmed then
      String.sub trimmed 2 (String.length trimmed - 2)
    else
      trimmed
  in
  normalize_ci_string normalized

let path_matches ~gold ~cited =
  let gold = normalize_rel_path gold in
  let cited = normalize_rel_path cited in
  String.equal gold cited
  || String.ends_with ~suffix:("/" ^ gold) cited

let string_list_member_ci value xs =
  let needle = normalize_ci_string value in
  List.exists (fun item -> String.equal needle (normalize_ci_string item)) xs

let avg_float xs =
  match xs with
  | [] -> 0.0
  | _ ->
      List.fold_left ( +. ) 0.0 xs /. float_of_int (List.length xs)

let question_to_yojson (q : question) =
  `Assoc
    [
      ("question_id", `String q.question_id);
      ("title", `String q.title);
      ("question", `String q.question);
      ("artifact_scope", `List (List.map (fun value -> `String value) q.artifact_scope));
      ("required_claims", `List (List.map (fun value -> `String value) q.required_claims));
      ("gold_paths", `List (List.map (fun value -> `String value) q.gold_paths));
      ("difficulty", Option.fold ~none:`Null ~some:(fun value -> `String value) q.difficulty);
      ("tags", `List (List.map (fun value -> `String value) q.tags));
    ]

let question_of_yojson (json : Yojson.Safe.t) =
  let string_list_field key =
    (match Json_util.assoc_member_opt key json with Some (`List l) -> List.filter_map (fun x -> match x with `String s -> Some s | _ -> None) l | _ -> [])
  in
  match Json_util.get_string json "question_id" with
  | None -> None
  | Some question_id ->
      Some
        {
          question_id;
          title = Json_util.get_string_with_default json ~key:"title" ~default:question_id;
          question = Json_util.get_string_with_default json ~key:"question" ~default:"";
          artifact_scope = string_list_field "artifact_scope";
          required_claims = string_list_field "required_claims";
          gold_paths = string_list_field "gold_paths";
          difficulty = Json_util.get_string json "difficulty";
          tags = string_list_field "tags";
        }

let answer_of_yojson (json : Yojson.Safe.t) =
  let string_list_field key =
    (match Json_util.assoc_member_opt key json with Some (`List l) -> List.filter_map (fun x -> match x with `String s -> Some s | _ -> None) l | _ -> [])
  in
  match Json_util.get_string json "question_id" with
  | None -> None
  | Some question_id ->
      Some
        {
          question_id;
          claims = string_list_field "claims";
          cited_paths = string_list_field "cited_paths";
          latency_ms =
            Json_util.get_int json "latency_ms" |> Option.value ~default:0;
        }

let question_score_to_yojson (score : question_score) =
  `Assoc
    [
      ("question_id", `String score.question_id);
      ("evidence_precision", `Float score.evidence_precision);
      ("claim_coverage", `Float score.claim_coverage);
      ("unsupported_claim_penalty", `Float score.unsupported_claim_penalty);
      ("latency_ms", `Int score.latency_ms);
      ("matched_claims", `List (List.map (fun value -> `String value) score.matched_claims));
      ("missing_claims", `List (List.map (fun value -> `String value) score.missing_claims));
      ("matched_paths", `List (List.map (fun value -> `String value) score.matched_paths));
      ( "unsupported_claims",
        `List (List.map (fun value -> `String value) score.unsupported_claims) );
    ]

let score_summary_to_yojson (summary : score_summary) =
  `Assoc
    [
      ("answer_set_label", `String summary.answer_set_label);
      ("question_count", `Int summary.question_count);
      ("answered_count", `Int summary.answered_count);
      ("evidence_precision", `Float summary.evidence_precision);
      ("claim_coverage", `Float summary.claim_coverage);
      ("unsupported_claim_penalty", `Float summary.unsupported_claim_penalty);
      ("avg_latency_ms", `Float summary.avg_latency_ms);
      ("composite_score", `Float summary.composite_score);
      ("per_question", `List (List.map question_score_to_yojson summary.per_question));
    ]

let score_summary_of_yojson (json : Yojson.Safe.t) =
  let per_question =
    (match Json_util.assoc_member_opt "per_question" json with Some (`List l) -> l | _ -> [])
    |> List.filter_map (fun item ->
           match Json_util.get_string item "question_id" with
           | None -> None
           | Some question_id ->
               Some
                 {
                   question_id;
                   evidence_precision =
                     Json_util.get_float item "evidence_precision"
                     |> Option.value ~default:0.0;
                   claim_coverage =
                     Json_util.get_float item "claim_coverage"
                     |> Option.value ~default:0.0;
                   unsupported_claim_penalty =
                     Json_util.get_float item "unsupported_claim_penalty"
                     |> Option.value ~default:0.0;
                   latency_ms =
                     Json_util.get_int item "latency_ms"
                     |> Option.value ~default:0;
                   matched_claims =
                     (match Json_util.assoc_member_opt "matched_claims" item with Some (`List l) -> l | _ -> [])
                     |> List.filter_map (fun x -> match x with `String s -> Some s | _ -> None);
                   missing_claims =
                     (match Json_util.assoc_member_opt "missing_claims" item with Some (`List l) -> l | _ -> [])
                     |> List.filter_map (fun x -> match x with `String s -> Some s | _ -> None);
                   matched_paths =
                     (match Json_util.assoc_member_opt "matched_paths" item with Some (`List l) -> l | _ -> [])
                     |> List.filter_map (fun x -> match x with `String s -> Some s | _ -> None);
                   unsupported_claims =
                     (match Json_util.assoc_member_opt "unsupported_claims" item with Some (`List l) -> l | _ -> [])
                     |> List.filter_map (fun x -> match x with `String s -> Some s | _ -> None);
                 })
  in
  {
    answer_set_label =
      Json_util.get_string_with_default json ~key:"answer_set_label" ~default:"";
    question_count =
      Json_util.get_int json "question_count" |> Option.value ~default:0;
    answered_count =
      Json_util.get_int json "answered_count" |> Option.value ~default:0;
    evidence_precision =
      Json_util.get_float json "evidence_precision" |> Option.value ~default:0.0;
    claim_coverage =
      Json_util.get_float json "claim_coverage" |> Option.value ~default:0.0;
    unsupported_claim_penalty =
      Json_util.get_float json "unsupported_claim_penalty"
      |> Option.value ~default:0.0;
    avg_latency_ms =
      Json_util.get_float json "avg_latency_ms" |> Option.value ~default:0.0;
    composite_score =
      Json_util.get_float json "composite_score" |> Option.value ~default:0.0;
    per_question;
  }

let run_record_to_yojson (run : run_record) =
  `Assoc
    [
      ("benchmark_run_id", `String run.benchmark_run_id);
      ("created_at", `String run.created_at);
      ("created_by", Option.fold ~none:`Null ~some:(fun value -> `String value) run.created_by);
      ("goal", `String run.goal);
      ("question", `String run.question);
      ("question_id", Option.fold ~none:`Null ~some:(fun value -> `String value) run.question_id);
      ("repo_root", `String run.repo_root);
      ("artifact_scope", `List (List.map (fun value -> `String value) run.artifact_scope));
      ("program_note", Option.fold ~none:`Null ~some:(fun value -> `String value) run.program_note);
      ("baseline_label", Option.fold ~none:`Null ~some:(fun value -> `String value) run.baseline_label);
      ("model", Option.fold ~none:`Null ~some:(fun value -> `String value) run.model);
      ("max_workers", `Int run.max_workers);
      ("time_budget_sec", `Int run.time_budget_sec);
      ("workload_profile", `String run.workload_profile);
      ("operation_id", Option.fold ~none:`Null ~some:(fun value -> `String value) run.operation_id);
      ("trace_id", Option.fold ~none:`Null ~some:(fun value -> `String value) run.trace_id);
      ("session_id", Option.fold ~none:`Null ~some:(fun value -> `String value) run.session_id);
      ("report_json_path", Option.fold ~none:`Null ~some:(fun value -> `String value) run.report_json_path);
      ("report_md_path", Option.fold ~none:`Null ~some:(fun value -> `String value) run.report_md_path);
      ("proof_json_path", Option.fold ~none:`Null ~some:(fun value -> `String value) run.proof_json_path);
      ("proof_md_path", Option.fold ~none:`Null ~some:(fun value -> `String value) run.proof_md_path);
      ("dataset_ref", Option.fold ~none:`Null ~some:(fun value -> `String value) run.dataset_ref);
      ("case_refs", `List (List.map (fun value -> `String value) run.case_refs));
      ("planned_worker_roles", `List (List.map (fun value -> `String value) run.planned_worker_roles));
      ("recommended_next_tools", `List (List.map (fun value -> `String value) run.recommended_next_tools));
      ("status", `String run.status);
    ]

let run_record_of_yojson (json : Yojson.Safe.t) =
  let string_list_field key =
    (match Json_util.assoc_member_opt key json with Some (`List l) -> List.filter_map (fun x -> match x with `String s -> Some s | _ -> None) l | _ -> [])
  in
  match Json_util.get_string json "benchmark_run_id" with
  | None -> None
  | Some benchmark_run_id ->
      Some
        {
          benchmark_run_id;
          created_at = Json_util.get_string_with_default json ~key:"created_at" ~default:"";
          created_by = Json_util.get_string json "created_by";
          goal = Json_util.get_string_with_default json ~key:"goal" ~default:"";
          question = Json_util.get_string_with_default json ~key:"question" ~default:"";
          question_id = Json_util.get_string json "question_id";
          repo_root = Json_util.get_string_with_default json ~key:"repo_root" ~default:"";
          artifact_scope = string_list_field "artifact_scope";
          program_note = Json_util.get_string json "program_note";
          baseline_label = Json_util.get_string json "baseline_label";
          model = Json_util.get_string json "model";
          max_workers = Json_util.get_int json "max_workers" |> Option.value ~default:0;
          time_budget_sec =
            Json_util.get_int json "time_budget_sec" |> Option.value ~default:0;
          workload_profile =
            Json_util.get_string_with_default json ~key:"workload_profile" ~default:"coding_task";
          operation_id = Json_util.get_string json "operation_id";
          trace_id = Json_util.get_string json "trace_id";
          session_id = Json_util.get_string json "session_id";
          report_json_path = Json_util.get_string json "report_json_path";
          report_md_path = Json_util.get_string json "report_md_path";
          proof_json_path = Json_util.get_string json "proof_json_path";
          proof_md_path = Json_util.get_string json "proof_md_path";
          dataset_ref = Json_util.get_string json "dataset_ref";
          case_refs = string_list_field "case_refs";
          planned_worker_roles = string_list_field "planned_worker_roles";
          recommended_next_tools = string_list_field "recommended_next_tools";
          status = Json_util.get_string_with_default json ~key:"status" ~default:"started";
        }

let make_run_id () =
  let ms = int_of_float (Unix.gettimeofday () *. 1000.0) in
  let suffix = Random.int 0x10000 in
  Printf.sprintf "rsb-%d-%04x" ms suffix

let save_run ~base_path (run : run_record) =
  match validate_run_id run.benchmark_run_id with
  | Ok run_id ->
      write_json_file (run_json_path_unchecked ~base_path run_id)
        (run_record_to_yojson run)
  | Error msg ->
      invalid_arg msg

let save_score ~base_path ~run_id (score : score_summary) =
  match validate_run_id run_id with
  | Ok run_id ->
      write_json_file (score_json_path_unchecked ~base_path run_id)
        (score_summary_to_yojson score)
  | Error msg ->
      invalid_arg msg

let load_run ~base_path run_id =
  match validate_run_id run_id with
  | Error _ -> None
  | Ok run_id -> (
      match read_json_file_opt (run_json_path_unchecked ~base_path run_id) with
      | Some json -> run_record_of_yojson json
      | None -> None)

let load_score ~base_path run_id =
  match validate_run_id run_id with
  | Error _ -> None
  | Ok run_id ->
      read_json_file_opt (score_json_path_unchecked ~base_path run_id)
      |> Option.map score_summary_of_yojson

let scan_run_ids ~base_path =
  let root = bench_root ~base_path in
  if not (Sys.file_exists root && Sys.is_directory root) then
    []
  else
    Sys.readdir root
    |> Array.to_list
    |> List.filter (fun name ->
           let path = Filename.concat root name in
           Sys.file_exists path && Sys.is_directory path)

let list_runs ~base_path =
  scan_run_ids ~base_path
  |> List.filter_map (fun run_id ->
         Option.map
           (fun run -> (run, load_score ~base_path run_id))
           (load_run ~base_path run_id))
  |> List.sort (fun (a, _) (b, _) -> String.compare b.created_at a.created_at)

let load_question_set ~repo_root =
  match read_json_file_opt (default_question_set_path ~repo_root) with
  | Some (`List items) -> List.filter_map question_of_yojson items
  | _ -> []

let find_question_by_id ~repo_root question_id =
  load_question_set ~repo_root
  |> List.find_opt (fun (question : question) ->
         String.equal question.question_id question_id)

let score_answer ~(question : question) (answer : answer) =
  let matched_claims =
    question.required_claims
    |> List.filter (fun claim -> string_list_member_ci claim answer.claims)
  in
  let missing_claims =
    question.required_claims
    |> List.filter (fun claim -> not (string_list_member_ci claim answer.claims))
  in
  let unsupported_claims =
    answer.claims
    |> List.filter (fun claim -> not (string_list_member_ci claim question.required_claims))
  in
  let matched_paths =
    answer.cited_paths
    |> List.filter (fun cited ->
           List.exists (fun gold -> path_matches ~gold ~cited) question.gold_paths)
  in
  let evidence_precision =
    match answer.cited_paths with
    | [] -> 0.0
    | cited ->
        float_of_int (List.length matched_paths)
        /. float_of_int (List.length cited)
  in
  let claim_coverage =
    match question.required_claims with
    | [] -> 1.0
    | required ->
        float_of_int (List.length matched_claims)
        /. float_of_int (List.length required)
  in
  let unsupported_claim_penalty =
    match answer.claims with
    | [] -> 0.0
    | claims ->
        float_of_int (List.length unsupported_claims)
        /. float_of_int (List.length claims)
  in
  {
    question_id = question.question_id;
    evidence_precision;
    claim_coverage;
    unsupported_claim_penalty;
    latency_ms = answer.latency_ms;
    matched_claims;
    missing_claims;
    matched_paths;
    unsupported_claims;
  }

let score_answers ~label ~(questions : question list) ~(answers : answer list) =
  let answer_by_question =
    List.fold_left
      (fun acc (answer : answer) -> (answer.question_id, answer) :: acc)
      [] answers
  in
  let per_question =
    questions
    |> List.filter_map (fun (question : question) ->
           match List.assoc_opt question.question_id answer_by_question with
           | Some answer -> Some (score_answer ~question answer)
           | None -> None)
  in
  let question_count = List.length questions in
  let answered_count = List.length per_question in
  let evidence_precision =
    per_question
    |> List.map (fun (score : question_score) -> score.evidence_precision)
    |> avg_float
  in
  let claim_coverage =
    per_question
    |> List.map (fun (score : question_score) -> score.claim_coverage)
    |> avg_float
  in
  let unsupported_claim_penalty =
    per_question
    |> List.map (fun (score : question_score) -> score.unsupported_claim_penalty)
    |> avg_float
  in
  let avg_latency_ms =
    per_question
    |> List.map (fun (score : question_score) -> float_of_int score.latency_ms)
    |> avg_float
  in
  let composite_score =
    max 0.0
      ((0.45 *. evidence_precision)
      +. (0.45 *. claim_coverage)
      -. (0.10 *. unsupported_claim_penalty))
  in
  {
    answer_set_label = label;
    question_count;
    answered_count;
    evidence_precision;
    claim_coverage;
    unsupported_claim_penalty;
    avg_latency_ms;
    composite_score;
    per_question;
  }

let load_answers_from_file path =
  match read_json_file_opt path with
  | Some (`List items) -> List.filter_map answer_of_yojson items
  | _ -> []

let run_summary_json ~base_path (run : run_record) score_opt =
  `Assoc
    [
      ("run", run_record_to_yojson run);
      ("score", Option.fold ~none:`Null ~some:score_summary_to_yojson score_opt);
      ( "score_json_path",
        if Option.is_some score_opt then
          `String (score_json_path ~base_path run.benchmark_run_id)
        else
          `Null );
    ]

