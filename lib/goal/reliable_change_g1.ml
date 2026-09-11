(** G1 Acceptance Contract and Checker for Reliable Change and Scale-out.
    SSOT: docs/RELIABLE-CHANGE-ROADMAP.md and docs/roadmaps/reliable-change-g1.json.
    Runtime Goal ID: goal-reliable-change-g1-20260909 (task-1478). *)

type scenario =
  | Success
  | Exit_nonzero
  | Stale_revision
  | Missing_artifact
  | Retry_success
  | Usage_unreported

let scenario_to_string = function
  | Success -> "success"
  | Exit_nonzero -> "exit-nonzero"
  | Stale_revision -> "stale-revision"
  | Missing_artifact -> "missing-artifact"
  | Retry_success -> "retry-success"
  | Usage_unreported -> "usage-unreported"
;;

let scenario_of_string_opt = function
  | "success" -> Some Success
  | "exit-nonzero" -> Some Exit_nonzero
  | "stale-revision" -> Some Stale_revision
  | "missing-artifact" -> Some Missing_artifact
  | "retry-success" -> Some Retry_success
  | "usage-unreported" -> Some Usage_unreported
  | _ -> None
;;

type live_scenario =
  | Live_success
  | Live_negative
  | Live_retry_success

let live_scenario_to_string = function
  | Live_success -> "success"
  | Live_negative -> "negative"
  | Live_retry_success -> "retry-success"
;;

let live_scenario_of_string_opt = function
  | "success" -> Some Live_success
  | "negative" -> Some Live_negative
  | "retry-success" -> Some Live_retry_success
  | _ -> None
;;

type usage_scope =
  | Per_request
  | Cumulative_request_snapshot

let usage_scope_to_string = function
  | Per_request -> "per-request"
  | Cumulative_request_snapshot -> "cumulative-request-snapshot"
;;

let usage_scope_of_string_opt = function
  | "per-request" -> Some Per_request
  | "cumulative-request-snapshot" -> Some Cumulative_request_snapshot
  | _ -> None
;;

type reported_usage =
  { input_tokens : int
  ; output_tokens : int
  ; cache_read_input_tokens : int
  ; cost_usd : float option
  ; cost_usd_exact : string option
  }

type usage_observation =
  | Usage_reported of reported_usage
  | Usage_missing of string

type phase_timestamps =
  { queue_started_at : float option
  ; model_started_at : float option
  ; model_ended_at : float option
  ; tool_started_at : float option
  ; tool_ended_at : float option
  ; verification_started_at : float option
  ; verification_ended_at : float option
  ; cleanup_ended_at : float option
  }

type run_observation =
  { case_id : string
  ; repeat_index : int
  ; run_id : string
  ; execution_mode : string
  ; request_or_task_identity : string
  ; run_turn_attempt_identity : string
  ; target_revision : string
  ; requested_revision : string
  ; artifact_references : string list
  ; command_exit_code : int option
  ; external_verified : bool
  ; verdict_run_identity : string option
  ; verdict_passed : bool
  ; usage : usage_observation
  ; usage_scope : usage_scope
  ; phase_timestamps : phase_timestamps
  ; attempt_sequence : int
  ; total_attempts_in_run : int
  }

type case_manifest =
  { scenario : scenario
  ; case_id : string
  ; expected_verified : bool
  ; expected_outcome : string
  ; required_entities : string list
  ; phase_boundaries : string list
  }

type manifest =
  { contract_sha256 : string
  ; source_commit : string
  ; binary_sha256 : string
  ; runtime_config_sha256 : string
  ; model_identity : string
  ; workload_revision : string
  ; expected_outcomes : (string * string) list
  ; case_ids : string list
  ; execution_mode : string
  ; required_entities_by_case : (string * string list) list
  ; phase_boundaries_by_case : (string * string list) list
  ; cases : case_manifest list
  }

let standard_required_entities =
  [ "request_or_task_identity"
  ; "run_turn_attempt_identity"
  ; "target_revision"
  ; "verdict_run_identity"
  ; "artifact_references"
  ; "raw_usage_or_missing_reason"
  ; "phase_timestamps"
  ]
;;

let standard_phase_boundaries =
  [ "queue"
  ; "model"
  ; "tool"
  ; "verification"
  ; "cleanup"
  ]
;;

let default_case_manifests () =
  [ { scenario = Success
    ; case_id = "success"
    ; expected_verified = true
    ; expected_outcome = "verified"
    ; required_entities = standard_required_entities
    ; phase_boundaries = standard_phase_boundaries
    }
  ; { scenario = Exit_nonzero
    ; case_id = "exit-nonzero"
    ; expected_verified = false
    ; expected_outcome = "command_exit_nonzero"
    ; required_entities = standard_required_entities
    ; phase_boundaries = standard_phase_boundaries
    }
  ; { scenario = Stale_revision
    ; case_id = "stale-revision"
    ; expected_verified = false
    ; expected_outcome = "revision_mismatch"
    ; required_entities = standard_required_entities
    ; phase_boundaries = standard_phase_boundaries
    }
  ; { scenario = Missing_artifact
    ; case_id = "missing-artifact"
    ; expected_verified = false
    ; expected_outcome = "missing_artifact"
    ; required_entities = standard_required_entities
    ; phase_boundaries = standard_phase_boundaries
    }
  ; { scenario = Retry_success
    ; case_id = "retry-success"
    ; expected_verified = true
    ; expected_outcome = "verified_after_retry"
    ; required_entities = standard_required_entities
    ; phase_boundaries = standard_phase_boundaries
    }
  ; { scenario = Usage_unreported
    ; case_id = "usage-unreported"
    ; expected_verified = false
    ; expected_outcome = "unreported_usage"
    ; required_entities = standard_required_entities
    ; phase_boundaries = standard_phase_boundaries
    }
  ]
;;

let make_manifest
    ~contract_sha256
    ~source_commit
    ~binary_sha256
    ~runtime_config_sha256
    ~model_identity
    ~workload_revision
    ~execution_mode
  =
  let cases = default_case_manifests () in
  let case_ids = List.map (fun c -> c.case_id) cases in
  let expected_outcomes =
    List.map (fun c -> (c.case_id, c.expected_outcome)) cases
  in
  let required_entities_by_case =
    List.map (fun c -> (c.case_id, c.required_entities)) cases
  in
  let phase_boundaries_by_case =
    List.map (fun c -> (c.case_id, c.phase_boundaries)) cases
  in
  { contract_sha256
  ; source_commit
  ; binary_sha256
  ; runtime_config_sha256
  ; model_identity
  ; workload_revision
  ; expected_outcomes
  ; case_ids
  ; execution_mode
  ; required_entities_by_case
  ; phase_boundaries_by_case
  ; cases
  }
;;

type usage_totals =
  { total_input_tokens : int
  ; total_output_tokens : int
  ; total_cache_read_input_tokens : int
  ; total_cost_usd : float option
  ; total_cost_usd_exact : string option
  }

let aggregate_run_usages observations =
  (* Group observations by request_or_task_identity *)
  let requests = Hashtbl.create 8 in
  List.iter
    (fun (obs : run_observation) ->
       let req = obs.request_or_task_identity in
       let existing =
         match Hashtbl.find_opt requests req with
         | Some list -> list
         | None -> []
       in
       Hashtbl.replace requests req (obs :: existing))
    observations;
  let has_reported = ref false in
  let sum_in = ref 0 in
  let sum_out = ref 0 in
  let sum_cache = ref 0 in
  let sum_cost = ref 0.0 in
  Hashtbl.iter
    (fun _req obs_list ->
       let sorted =
         List.sort (fun (a : run_observation) (b : run_observation) ->
           compare a.attempt_sequence b.attempt_sequence) obs_list
       in
       (* If any observation has Cumulative_request_snapshot scope, take latest snapshot *)
       let has_cumulative =
         List.exists (fun (o : run_observation) ->
           match o.usage_scope with
           | Cumulative_request_snapshot -> true
           | Per_request -> false) sorted
       in
       if has_cumulative then (
         (* Take latest observation for this request *)
         match List.rev sorted with
         | [] -> ()
         | latest :: _ ->
           (match latest.usage with
            | Usage_reported r ->
              has_reported := true;
              sum_in := !sum_in + r.input_tokens;
              sum_out := !sum_out + r.output_tokens;
              sum_cache := !sum_cache + r.cache_read_input_tokens;
              Option.iter (fun c -> sum_cost := !sum_cost +. c) r.cost_usd
            | Usage_missing _ -> ())
       ) else (
         (* Per_request scope: sum all *)
         List.iter
           (fun (o : run_observation) ->
              match o.usage with
              | Usage_reported r ->
                has_reported := true;
                sum_in := !sum_in + r.input_tokens;
                sum_out := !sum_out + r.output_tokens;
                sum_cache := !sum_cache + r.cache_read_input_tokens;
                Option.iter (fun c -> sum_cost := !sum_cost +. c) r.cost_usd
              | Usage_missing _ -> ())
           sorted
       ))
    requests;
  if !has_reported then
    { total_input_tokens = !sum_in
    ; total_output_tokens = !sum_out
    ; total_cache_read_input_tokens = !sum_cache
    ; total_cost_usd = Some !sum_cost
    ; total_cost_usd_exact = Some (Printf.sprintf "%.2f" !sum_cost)
    }
  else
    { total_input_tokens = 0
    ; total_output_tokens = 0
    ; total_cache_read_input_tokens = 0
    ; total_cost_usd = None
    ; total_cost_usd_exact = None
    }
;;

type check_finding =
  { rule_id : string
  ; description : string
  ; passed : bool
  ; detail : string option
  }

type checker_summary =
  { matrix_expected : int
  ; matrix_observed : int
  ; matrix_passed : int
  ; live_expected : int
  ; live_observed : int
  ; live_passed : int
  ; false_verified_count : int
  ; required_join_missing_count : int
  ; unknown_usage_coerced_to_zero_count : int
  ; duplicated_usage_count : int
  ; reported_usage_totals_mismatch_count : int
  ; overall_passed : bool
  ; findings : check_finding list
  }

let check_observations ~manifest ~observations =
  let matrix_expected = 18 in
  let live_expected = 3 in
  let matrix_obs =
    List.filter (fun (o : run_observation) -> o.execution_mode = "controlled" || o.execution_mode = "matrix") observations
  in
  let live_obs =
    List.filter (fun (o : run_observation) -> o.execution_mode = "live") observations
  in
  let matrix_observed = List.length matrix_obs in
  let live_observed = List.length live_obs in
  let false_verified = ref 0 in
  let required_join_missing = ref 0 in
  let unknown_coerced_to_zero = ref 0 in
  let duplicated_usage = ref 0 in
  let totals_mismatch = ref 0 in
  let findings = ref [] in
  let add_finding rule_id description passed detail =
    findings := { rule_id; description; passed; detail } :: !findings
  in

  (* Check counts *)
  let counts_passed = (matrix_observed = matrix_expected) && (live_observed = live_expected) in
  add_finding "matrix_count" "Matrix observation count matches contract (18)"
    (matrix_observed = matrix_expected)
    (if matrix_observed <> matrix_expected
     then Some (Printf.sprintf "expected %d, got %d" matrix_expected matrix_observed)
     else None);
  add_finding "live_count" "Live observation count matches contract (3)"
    (live_observed = live_expected)
    (if live_observed <> live_expected
     then Some (Printf.sprintf "expected %d, got %d" live_expected live_observed)
     else None);

  (* Check individual observations *)
  List.iter
    (fun (o : run_observation) ->
       let scenario_opt = scenario_of_string_opt o.case_id in
       (* Required joins *)
       if String.trim o.request_or_task_identity = ""
          || String.trim o.run_turn_attempt_identity = ""
          || String.trim o.target_revision = ""
       then incr required_join_missing;

       (match scenario_opt with
        | Some Success ->
          if not (o.external_verified && o.verdict_passed) then
            () (* failed run is not false verified *)
          else if o.target_revision <> o.requested_revision then
            incr false_verified
          else if Option.is_none o.verdict_run_identity || o.artifact_references = [] then
            incr required_join_missing
        | Some Exit_nonzero ->
          (* An exit-nonzero run must never be marked verified *)
          if o.verdict_passed || o.external_verified then
            incr false_verified
        | Some Stale_revision ->
          (* Stale revision must never be marked verified *)
          if o.verdict_passed || o.external_verified then
            incr false_verified
        | Some Missing_artifact ->
          (* Missing artifact must never be marked verified *)
          if o.verdict_passed || o.external_verified || o.artifact_references <> [] then
            incr false_verified
        | Some Retry_success ->
          (* Must have valid joins *)
          if o.verdict_passed && (Option.is_none o.verdict_run_identity || o.artifact_references = []) then
            incr required_join_missing
        | Some Usage_unreported ->
          (* Must NOT coerce unknown usage to 0 or 0.0 *)
          (match o.usage with
           | Usage_missing _ -> ()
           | Usage_reported r ->
             if r.input_tokens = 0 && r.output_tokens = 0 && r.cost_usd = Some 0.0 then
               incr unknown_coerced_to_zero)
        | None -> ());

       (* Nonzero command exit code cannot be verified *)
       (match o.command_exit_code with
        | Some code when code <> 0 && o.verdict_passed -> incr false_verified
        | _ -> ()))
    observations;

  (* Check retry-success reported usage fixture totals *)
  let retry_success_obs =
    List.filter (fun (o : run_observation) -> o.case_id = "retry-success") matrix_obs
  in
  if retry_success_obs <> [] then (
    let totals = aggregate_run_usages retry_success_obs in
    if totals.total_input_tokens <> 40
       || totals.total_output_tokens <> 8
       || totals.total_cache_read_input_tokens <> 8
       || totals.total_cost_usd <> Some 0.07 then (
      incr totals_mismatch;
      add_finding "retry_success_fixture"
        "retry-success aggregated usage matches contract totals exactly (40/8/8/$0.07)"
        false
        (Some
           (Printf.sprintf
              "got in=%d out=%d cache=%d cost=%s"
              totals.total_input_tokens
              totals.total_output_tokens
              totals.total_cache_read_input_tokens
              (Option.value ~default:"null" totals.total_cost_usd_exact)))
    ) else (
      add_finding "retry_success_fixture"
        "retry-success aggregated usage matches contract totals exactly (40/8/8/$0.07)"
        true
        None
    )
  );

  let matrix_passed =
    if !false_verified = 0 && !required_join_missing = 0 && !unknown_coerced_to_zero = 0 && !duplicated_usage = 0 && !totals_mismatch = 0
    then matrix_observed
    else 0
  in
  let live_passed =
    if !false_verified = 0 && !required_join_missing = 0 then live_observed else 0
  in
  let overall_passed =
    counts_passed
    && matrix_passed = matrix_expected
    && live_passed = live_expected
    && !false_verified = 0
    && !required_join_missing = 0
    && !unknown_coerced_to_zero = 0
    && !duplicated_usage = 0
    && !totals_mismatch = 0
  in
  { matrix_expected
  ; matrix_observed
  ; matrix_passed
  ; live_expected
  ; live_observed
  ; live_passed
  ; false_verified_count = !false_verified
  ; required_join_missing_count = !required_join_missing
  ; unknown_usage_coerced_to_zero_count = !unknown_coerced_to_zero
  ; duplicated_usage_count = !duplicated_usage
  ; reported_usage_totals_mismatch_count = !totals_mismatch
  ; overall_passed
  ; findings = List.rev !findings
  }
;;

let manifest_to_json (m : manifest) : Yojson.Safe.t =
  `Assoc
    [ "schema", `String "masc.reliable_change.g1_manifest.v1"
    ; "contract_sha256", `String m.contract_sha256
    ; "source_commit", `String m.source_commit
    ; "binary_sha256", `String m.binary_sha256
    ; "runtime_config_sha256", `String m.runtime_config_sha256
    ; "model_identity", `String m.model_identity
    ; "workload_revision", `String m.workload_revision
    ; "execution_mode", `String m.execution_mode
    ; "case_ids", `List (List.map (fun s -> `String s) m.case_ids)
    ; ( "expected_outcomes"
      , `Assoc (List.map (fun (k, v) -> (k, `String v)) m.expected_outcomes) )
    ; ( "required_entities_by_case"
      , `Assoc
          (List.map
             (fun (k, vs) -> (k, `List (List.map (fun s -> `String s) vs)))
             m.required_entities_by_case) )
    ; ( "phase_boundaries_by_case"
      , `Assoc
          (List.map
             (fun (k, vs) -> (k, `List (List.map (fun s -> `String s) vs)))
             m.phase_boundaries_by_case) )
    ]
;;

let manifest_of_json json : (manifest, string) result =
  let open Yojson.Safe.Util in
  try
    let contract_sha256 = json |> member "contract_sha256" |> to_string in
    let source_commit = json |> member "source_commit" |> to_string in
    let binary_sha256 = json |> member "binary_sha256" |> to_string in
    let runtime_config_sha256 = json |> member "runtime_config_sha256" |> to_string in
    let model_identity = json |> member "model_identity" |> to_string in
    let workload_revision = json |> member "workload_revision" |> to_string in
    let execution_mode = json |> member "execution_mode" |> to_string in
    let case_ids = json |> member "case_ids" |> to_list |> List.map to_string in
    let expected_outcomes =
      json
      |> member "expected_outcomes"
      |> to_assoc
      |> List.map (fun (k, v) -> (k, to_string v))
    in
    let required_entities_by_case =
      json
      |> member "required_entities_by_case"
      |> to_assoc
      |> List.map (fun (k, v) -> (k, to_list v |> List.map to_string))
    in
    let phase_boundaries_by_case =
      json
      |> member "phase_boundaries_by_case"
      |> to_assoc
      |> List.map (fun (k, v) -> (k, to_list v |> List.map to_string))
    in
    let cases = default_case_manifests () in
    Ok
      { contract_sha256
      ; source_commit
      ; binary_sha256
      ; runtime_config_sha256
      ; model_identity
      ; workload_revision
      ; expected_outcomes
      ; case_ids
      ; execution_mode
      ; required_entities_by_case
      ; phase_boundaries_by_case
      ; cases
      }
  with exn -> Error (Printexc.to_string exn)
;;

let run_observation_to_json (o : run_observation) : Yojson.Safe.t =
  let usage_json =
    match o.usage with
    | Usage_missing reason ->
      `Assoc [ "reported", `Bool false; "reason", `String reason; "cost_usd", `Null ]
    | Usage_reported r ->
      `Assoc
        [ "reported", `Bool true
        ; "input_tokens", `Int r.input_tokens
        ; "output_tokens", `Int r.output_tokens
        ; "cache_read_input_tokens", `Int r.cache_read_input_tokens
        ; "cost_usd", Option.fold ~none:`Null ~some:(fun c -> `Float c) r.cost_usd
        ; ( "cost_usd_exact"
          , Option.fold ~none:`Null ~some:(fun s -> `String s) r.cost_usd_exact )
        ]
  in
  let pt = o.phase_timestamps in
  let opt_f = Option.fold ~none:`Null ~some:(fun f -> `Float f) in
  let phase_timestamps_json =
    `Assoc
      [ "queue_started_at", opt_f pt.queue_started_at
      ; "model_started_at", opt_f pt.model_started_at
      ; "model_ended_at", opt_f pt.model_ended_at
      ; "tool_started_at", opt_f pt.tool_started_at
      ; "tool_ended_at", opt_f pt.tool_ended_at
      ; "verification_started_at", opt_f pt.verification_started_at
      ; "verification_ended_at", opt_f pt.verification_ended_at
      ; "cleanup_ended_at", opt_f pt.cleanup_ended_at
      ]
  in
  `Assoc
    [ "case_id", `String o.case_id
    ; "repeat_index", `Int o.repeat_index
    ; "run_id", `String o.run_id
    ; "execution_mode", `String o.execution_mode
    ; "request_or_task_identity", `String o.request_or_task_identity
    ; "run_turn_attempt_identity", `String o.run_turn_attempt_identity
    ; "target_revision", `String o.target_revision
    ; "requested_revision", `String o.requested_revision
    ; "artifact_references", `List (List.map (fun s -> `String s) o.artifact_references)
    ; "command_exit_code", Option.fold ~none:`Null ~some:(fun c -> `Int c) o.command_exit_code
    ; "external_verified", `Bool o.external_verified
    ; "verdict_run_identity", Option.fold ~none:`Null ~some:(fun s -> `String s) o.verdict_run_identity
    ; "verdict_passed", `Bool o.verdict_passed
    ; "usage", usage_json
    ; "usage_scope", `String (usage_scope_to_string o.usage_scope)
    ; "phase_timestamps", phase_timestamps_json
    ; "attempt_sequence", `Int o.attempt_sequence
    ; "total_attempts_in_run", `Int o.total_attempts_in_run
    ]
;;

let run_observation_of_json json : (run_observation, string) result =
  let open Yojson.Safe.Util in
  try
    let case_id = json |> member "case_id" |> to_string in
    let repeat_index = json |> member "repeat_index" |> to_int in
    let run_id = json |> member "run_id" |> to_string in
    let execution_mode = json |> member "execution_mode" |> to_string in
    let request_or_task_identity = json |> member "request_or_task_identity" |> to_string in
    let run_turn_attempt_identity = json |> member "run_turn_attempt_identity" |> to_string in
    let target_revision = json |> member "target_revision" |> to_string in
    let requested_revision = json |> member "requested_revision" |> to_string in
    let artifact_references =
      json |> member "artifact_references" |> to_list |> List.map to_string
    in
    let command_exit_code = json |> member "command_exit_code" |> to_int_option in
    let external_verified = json |> member "external_verified" |> to_bool in
    let verdict_run_identity = json |> member "verdict_run_identity" |> to_string_option in
    let verdict_passed = json |> member "verdict_passed" |> to_bool in
    let usage_scope_raw = json |> member "usage_scope" |> to_string in
    let usage_scope =
      Option.value ~default:Per_request (usage_scope_of_string_opt usage_scope_raw)
    in
    let usage =
      let u = json |> member "usage" in
      let reported = u |> member "reported" |> to_bool in
      if reported then
        let input_tokens = u |> member "input_tokens" |> to_int in
        let output_tokens = u |> member "output_tokens" |> to_int in
        let cache_read_input_tokens =
          u |> member "cache_read_input_tokens" |> to_int_option |> Option.value ~default:0
        in
        let cost_usd = u |> member "cost_usd" |> to_float_option in
        let cost_usd_exact = u |> member "cost_usd_exact" |> to_string_option in
        Usage_reported
          { input_tokens
          ; output_tokens
          ; cache_read_input_tokens
          ; cost_usd
          ; cost_usd_exact
          }
      else
        let reason =
          u |> member "reason" |> to_string_option |> Option.value ~default:"unreported"
        in
        Usage_missing reason
    in
    let pt = json |> member "phase_timestamps" in
    let phase_timestamps =
      { queue_started_at = pt |> member "queue_started_at" |> to_float_option
      ; model_started_at = pt |> member "model_started_at" |> to_float_option
      ; model_ended_at = pt |> member "model_ended_at" |> to_float_option
      ; tool_started_at = pt |> member "tool_started_at" |> to_float_option
      ; tool_ended_at = pt |> member "tool_ended_at" |> to_float_option
      ; verification_started_at = pt |> member "verification_started_at" |> to_float_option
      ; verification_ended_at = pt |> member "verification_ended_at" |> to_float_option
      ; cleanup_ended_at = pt |> member "cleanup_ended_at" |> to_float_option
      }
    in
    let attempt_sequence =
      json |> member "attempt_sequence" |> to_int_option |> Option.value ~default:1
    in
    let total_attempts_in_run =
      json |> member "total_attempts_in_run" |> to_int_option |> Option.value ~default:1
    in
    Ok
      { case_id
      ; repeat_index
      ; run_id
      ; execution_mode
      ; request_or_task_identity
      ; run_turn_attempt_identity
      ; target_revision
      ; requested_revision
      ; artifact_references
      ; command_exit_code
      ; external_verified
      ; verdict_run_identity
      ; verdict_passed
      ; usage
      ; usage_scope
      ; phase_timestamps
      ; attempt_sequence
      ; total_attempts_in_run
      }
  with exn -> Error (Printexc.to_string exn)
;;

let checker_summary_to_json (s : checker_summary) : Yojson.Safe.t =
  let findings_json =
    List.map
      (fun f ->
         `Assoc
           [ "rule_id", `String f.rule_id
           ; "description", `String f.description
           ; "passed", `Bool f.passed
           ; "detail", Option.fold ~none:`Null ~some:(fun d -> `String d) f.detail
           ])
      s.findings
  in
  `Assoc
    [ "schema", `String "masc.reliable_change.g1_checker_summary.v1"
    ; "overall_passed", `Bool s.overall_passed
    ; "matrix_expected", `Int s.matrix_expected
    ; "matrix_observed", `Int s.matrix_observed
    ; "matrix_passed", `Int s.matrix_passed
    ; "live_expected", `Int s.live_expected
    ; "live_observed", `Int s.live_observed
    ; "live_passed", `Int s.live_passed
    ; "false_verified_count", `Int s.false_verified_count
    ; "required_join_missing_count", `Int s.required_join_missing_count
    ; "unknown_usage_coerced_to_zero_count", `Int s.unknown_usage_coerced_to_zero_count
    ; "duplicated_usage_count", `Int s.duplicated_usage_count
    ; ( "reported_usage_totals_mismatch_count"
      , `Int s.reported_usage_totals_mismatch_count )
    ; "findings", `List findings_json
    ]
;;

let checker_summary_of_json json : (checker_summary, string) result =
  let open Yojson.Safe.Util in
  try
    let overall_passed = json |> member "overall_passed" |> to_bool in
    let matrix_expected = json |> member "matrix_expected" |> to_int in
    let matrix_observed = json |> member "matrix_observed" |> to_int in
    let matrix_passed = json |> member "matrix_passed" |> to_int in
    let live_expected = json |> member "live_expected" |> to_int in
    let live_observed = json |> member "live_observed" |> to_int in
    let live_passed = json |> member "live_passed" |> to_int in
    let false_verified_count = json |> member "false_verified_count" |> to_int in
    let required_join_missing_count =
      json |> member "required_join_missing_count" |> to_int
    in
    let unknown_usage_coerced_to_zero_count =
      json |> member "unknown_usage_coerced_to_zero_count" |> to_int
    in
    let duplicated_usage_count = json |> member "duplicated_usage_count" |> to_int in
    let reported_usage_totals_mismatch_count =
      json |> member "reported_usage_totals_mismatch_count" |> to_int
    in
    let findings =
      json
      |> member "findings"
      |> to_list
      |> List.map (fun f ->
        { rule_id = f |> member "rule_id" |> to_string
        ; description = f |> member "description" |> to_string
        ; passed = f |> member "passed" |> to_bool
        ; detail = f |> member "detail" |> to_string_option
        })
    in
    Ok
      { matrix_expected
      ; matrix_observed
      ; matrix_passed
      ; live_expected
      ; live_observed
      ; live_passed
      ; false_verified_count
      ; required_join_missing_count
      ; unknown_usage_coerced_to_zero_count
      ; duplicated_usage_count
      ; reported_usage_totals_mismatch_count
      ; overall_passed
      ; findings
      }
  with exn -> Error (Printexc.to_string exn)
;;
