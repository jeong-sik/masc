open Yojson.Safe.Util

type scenario =
  | Success
  | Exit_nonzero
  | Stale_revision
  | Missing_artifact
  | Retry_success
  | Usage_unreported

let scenario_of_string = function
  | "success" -> Ok Success
  | "exit-nonzero" -> Ok Exit_nonzero
  | "stale-revision" -> Ok Stale_revision
  | "missing-artifact" -> Ok Missing_artifact
  | "retry-success" -> Ok Retry_success
  | "usage-unreported" -> Ok Usage_unreported
  | other -> Error ("unknown scenario: " ^ other)
;;

type live_scenario =
  | Live_success
  | Live_negative
  | Live_retry_success

let live_scenario_of_string = function
  | "success" -> Ok Live_success
  | "negative" -> Ok Live_negative
  | "retry-success" -> Ok Live_retry_success
  | other -> Error ("unknown live scenario: " ^ other)
;;

type run_scenario =
  | Matrix_scenario of scenario
  | Live_scenario of live_scenario

let run_scenario_of_string ~execution_mode s =
  match execution_mode with
  | "live" ->
    (match live_scenario_of_string s with
     | Ok lsc -> Ok (Live_scenario lsc)
     | Error err -> Error err)
  | _ ->
    (match scenario_of_string s with
     | Ok sc -> Ok (Matrix_scenario sc)
     | Error err -> Error err)
;;

type usage_scope =
  | Per_request
  | Cumulative_request_snapshot

let usage_scope_to_string = function
  | Per_request -> "per-request"
  | Cumulative_request_snapshot -> "cumulative-request-snapshot"
;;

let usage_scope_of_string = function
  | "per-request" -> Ok Per_request
  | "cumulative-request-snapshot" -> Ok Cumulative_request_snapshot
  | other -> Error ("invalid or unknown usage_scope: " ^ other)
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
  ; scenario : run_scenario
  ; repeat_index : int
  ; run_id : string
  ; execution_mode : string
  ; request_or_task_identity : string option
  ; run_turn_attempt_identity : string option
  ; target_revision : string option
  ; requested_revision : string option
  ; artifact_references : string list
  ; command_exit_code : int option
  ; external_verified : bool
  ; verdict_run_identity : string option
  ; verdict_passed : bool
  ; usage : usage_observation
  ; usage_scope : usage_scope option
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

let default_phase_boundaries =
  [ "queue_started_at"
  ; "model_started_at"
  ; "model_ended_at"
  ; "tool_started_at"
  ; "tool_ended_at"
  ; "verification_started_at"
  ; "verification_ended_at"
  ; "cleanup_ended_at"
  ]
;;

let default_required_entities =
  [ "request_or_task_identity"
  ; "run_turn_attempt_identity"
  ; "target_revision"
  ; "artifact_references"
  ; "verdict_run_identity"
  ]
;;

let default_case_manifests () =
  [ { scenario = Success
    ; case_id = "success"
    ; expected_verified = true
    ; expected_outcome = "verified"
    ; required_entities = default_required_entities
    ; phase_boundaries = default_phase_boundaries
    }
  ; { scenario = Exit_nonzero
    ; case_id = "exit-nonzero"
    ; expected_verified = false
    ; expected_outcome = "command_exit_nonzero"
    ; required_entities = default_required_entities
    ; phase_boundaries = default_phase_boundaries
    }
  ; { scenario = Stale_revision
    ; case_id = "stale-revision"
    ; expected_verified = false
    ; expected_outcome = "stale_revision_rejected"
    ; required_entities = default_required_entities
    ; phase_boundaries = default_phase_boundaries
    }
  ; { scenario = Missing_artifact
    ; case_id = "missing-artifact"
    ; expected_verified = false
    ; expected_outcome = "missing_artifact_rejected"
    ; required_entities = [ "request_or_task_identity"; "run_turn_attempt_identity" ]
    ; phase_boundaries = default_phase_boundaries
    }
  ; { scenario = Retry_success
    ; case_id = "retry-success"
    ; expected_verified = true
    ; expected_outcome = "verified_after_retry"
    ; required_entities = default_required_entities
    ; phase_boundaries = default_phase_boundaries
    }
  ; { scenario = Usage_unreported
    ; case_id = "usage-unreported"
    ; expected_verified = false
    ; expected_outcome = "unreported_usage_preserved"
    ; required_entities = default_required_entities
    ; phase_boundaries = default_phase_boundaries
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
  let case_ids = List.map (fun (c : case_manifest) -> c.case_id) cases in
  let expected_outcomes =
    List.map (fun (c : case_manifest) -> c.case_id, c.expected_outcome) cases
  in
  let required_entities_by_case =
    List.map (fun (c : case_manifest) -> c.case_id, c.required_entities) cases
  in
  let phase_boundaries_by_case =
    List.map (fun (c : case_manifest) -> c.case_id, c.phase_boundaries) cases
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

let aggregate_run_usages (observations : run_observation list) : usage_totals =
  let per_request_obs =
    List.filter (fun (o : run_observation) -> o.usage_scope = Some Per_request) observations
  in
  let cumulative_obs =
    List.filter
      (fun (o : run_observation) -> o.usage_scope = Some Cumulative_request_snapshot)
      observations
  in
  let distinct_per_request =
    List.fold_left
      (fun acc (o : run_observation) ->
         let key =
           match o.run_turn_attempt_identity with
           | Some id -> id
           | None -> o.run_id
         in
         if List.exists (fun (k, _) -> k = key) acc then acc
         else (key, o) :: acc)
      [] per_request_obs
    |> List.map snd
  in
  let request_ids =
    List.sort_uniq String.compare
      (List.map
         (fun (o : run_observation) ->
            match o.request_or_task_identity with
            | Some r -> r
            | None -> o.run_id)
         cumulative_obs)
  in
  let latest_cumulative =
    List.map
      (fun req_id ->
         let matching =
           List.filter
             (fun (o : run_observation) ->
                let r =
                  match o.request_or_task_identity with
                  | Some r -> r
                  | None -> o.run_id
                in
                r = req_id)
             cumulative_obs
         in
         let sorted =
           List.sort
             (fun a b ->
                match Int.compare a.attempt_sequence b.attempt_sequence with
                | 0 ->
                  let a_cost =
                    match a.usage with
                    | Usage_reported r -> (match r.cost_usd with Some c -> c | None -> 0.0)
                    | Usage_missing _ -> 0.0
                  in
                  let b_cost =
                    match b.usage with
                    | Usage_reported r -> (match r.cost_usd with Some c -> c | None -> 0.0)
                    | Usage_missing _ -> 0.0
                  in
                  Float.compare a_cost b_cost
                | c -> c)
             matching
         in
         List.hd (List.rev sorted))
      request_ids
  in
  let all_countable = distinct_per_request @ latest_cumulative in
  let sum_in = ref 0 in
  let sum_out = ref 0 in
  let sum_cache = ref 0 in
  let total_cost = ref 0.0 in
  let has_reported_cost = ref false in
  List.iter
    (fun (o : run_observation) ->
       match o.usage with
       | Usage_reported r ->
         sum_in := !sum_in + r.input_tokens;
         sum_out := !sum_out + r.output_tokens;
         sum_cache := !sum_cache + r.cache_read_input_tokens;
         (match r.cost_usd with
          | Some c ->
            has_reported_cost := true;
            total_cost := !total_cost +. c
          | None -> ())
       | Usage_missing _ -> ())
    all_countable;
  let final_cost = if !has_reported_cost then Some !total_cost else None in
  let final_cost_exact =
    match final_cost with
    | Some c -> Some (Printf.sprintf "%.2f" c)
    | None -> None
  in
  { total_input_tokens = !sum_in
  ; total_output_tokens = !sum_out
  ; total_cache_read_input_tokens = !sum_cache
  ; total_cost_usd = final_cost
  ; total_cost_usd_exact = final_cost_exact
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

let check_phase_boundary_order (pt : phase_timestamps) : bool =
  let ts =
    [ pt.queue_started_at
    ; pt.model_started_at
    ; pt.model_ended_at
    ; pt.tool_started_at
    ; pt.tool_ended_at
    ; pt.verification_started_at
    ; pt.verification_ended_at
    ; pt.cleanup_ended_at
    ]
  in
  let present_ts = List.filter_map (fun x -> x) ts in
  let rec is_monotonic = function
    | [] | [ _ ] -> true
    | a :: (b :: _ as rest) -> if a <= b then is_monotonic rest else false
  in
  is_monotonic present_ts
;;

let check_observations
      ~(manifest : manifest)
      ~(observations : run_observation list)
  : checker_summary
  =
  let findings = ref [] in
  let add_finding rule_id description passed detail =
    findings := { rule_id; description; passed; detail } :: !findings
  in
  let false_verified = ref 0 in
  let required_join_missing = ref 0 in
  let unknown_coerced_to_zero = ref 0 in
  let duplicated_usage = ref 0 in
  let totals_mismatch = ref 0 in

  let matrix_expected = 18 in
  let live_expected = 3 in

  let matrix_obs =
    List.filter (fun (o : run_observation) -> o.execution_mode = "matrix")
      observations in
  let live_obs =
    List.filter (fun (o : run_observation) -> o.execution_mode = "live")
      observations in

  (* Group observations by run key: (case_id, repeat_index) *)
  let run_keys_matrix =
    List.sort_uniq
      (fun (c1, r1) (c2, r2) ->
         match String.compare c1 c2 with
         | 0 -> Int.compare r1 r2
         | c -> c)
      (List.map (fun (o : run_observation) -> o.case_id, o.repeat_index)
         matrix_obs)
  in
  let matrix_observed = List.length run_keys_matrix in

  let run_keys_live =
    List.sort_uniq
      (fun (c1, r1) (c2, r2) ->
         match String.compare c1 c2 with
         | 0 -> Int.compare r1 r2
         | c -> c)
      (List.map (fun (o : run_observation) -> o.case_id, o.repeat_index)
         live_obs)
  in
  let live_observed = List.length run_keys_live in

  (* 1. Manifest completeness check *)
  List.iter
    (fun expected_case_id ->
       if not (List.mem_assoc expected_case_id manifest.required_entities_by_case) then (
         incr required_join_missing;
         add_finding "missing_required_entities_declaration"
           (Printf.sprintf "manifest missing required_entities_by_case declaration for %s" expected_case_id)
           false
           (Some expected_case_id)
       );
       if not (List.mem_assoc expected_case_id manifest.phase_boundaries_by_case) then (
         add_finding "missing_phase_boundaries_declaration"
           (Printf.sprintf "manifest missing phase_boundaries_by_case declaration for %s" expected_case_id)
           false
           (Some expected_case_id)
       );
       if not (List.mem_assoc expected_case_id manifest.expected_outcomes) then (
         add_finding "missing_expected_outcome_declaration"
           (Printf.sprintf "manifest missing expected_outcomes declaration for %s" expected_case_id)
           false
           (Some expected_case_id)
       );
       for rep = 1 to 3 do
         if not (List.exists (fun (c, r) -> c = expected_case_id && r = rep) run_keys_matrix)
         then (
           incr required_join_missing;
           add_finding "manifest_case_missing"
             (Printf.sprintf "case %s repeat %d must be observed in matrix" expected_case_id rep)
             false
             (Some (Printf.sprintf "missing %s[%d]" expected_case_id rep))
         )
       done)
    manifest.case_ids;

  (* 2. Process each matrix run *)
  let matrix_runs_passed = ref 0 in
  List.iter
    (fun (case_id, repeat_index) ->
       let run_obs =
         List.filter
           (fun (o : run_observation) ->
              o.case_id = case_id && o.repeat_index = repeat_index)
           matrix_obs
       in
       let sorted_attempts =
         List.sort (fun a b -> Int.compare a.attempt_sequence b.attempt_sequence) run_obs
       in
       let final_attempt = List.hd (List.rev sorted_attempts) in
       let first_attempt = List.hd sorted_attempts in
       let run_valid = ref true in

       (* Check for duplicated usage within run *)
       let per_req_attempts =
         List.filter (fun (o : run_observation) -> o.usage_scope = Some Per_request) run_obs
       in
       let per_req_ids =
         List.filter_map
           (fun (o : run_observation) -> o.run_turn_attempt_identity)
           per_req_attempts
       in
       let unique_per_req_ids = List.sort_uniq String.compare per_req_ids in
       if List.length per_req_ids <> List.length unique_per_req_ids then (
         incr duplicated_usage;
         run_valid := false;
         add_finding "duplicated_per_request_usage"
           (Printf.sprintf "run %s[%d] contains duplicated per-request attempt identities" case_id repeat_index)
           false
           (Some (Printf.sprintf "%s[%d]" case_id repeat_index))
       );
       let cumulative_attempts =
         List.filter
           (fun (o : run_observation) ->
              o.usage_scope = Some Cumulative_request_snapshot)
           run_obs
       in
       (* Key on the snapshot's own identity: the contract's canonical
          cumulative shape records several progressive snapshots of one
          attempt (attempt-2-snap-1 / -snap-2) under the same
          request_or_task_identity and attempt_sequence, and the totals rule
          below requires exactly that aggregate. What counts as duplicated is
          the same snapshot recorded twice, not a later snapshot of the same
          attempt. *)
       let cumulative_keys =
         List.map
           (fun (o : run_observation) ->
              ( match o.run_turn_attempt_identity with
                | Some id -> id
                | None -> o.run_id )
              , o.attempt_sequence )
           cumulative_attempts
       in
       let unique_cumulative_keys =
         List.sort_uniq
           (fun (r1, s1) (r2, s2) ->
              match String.compare r1 r2 with
              | 0 -> Int.compare s1 s2
              | c -> c)
           cumulative_keys
       in
       if List.length cumulative_keys <> List.length unique_cumulative_keys then (
         incr duplicated_usage;
         run_valid := false;
         add_finding "duplicated_cumulative_usage"
           (Printf.sprintf "run %s[%d] contains duplicated cumulative snapshots" case_id repeat_index)
           false
           (Some (Printf.sprintf "%s[%d]" case_id repeat_index))
       );

       (* Check required entities from manifest map required_entities_by_case *)
       let required_entities =
         match List.assoc_opt case_id manifest.required_entities_by_case with
         | Some entities -> entities
         | None ->
           incr required_join_missing;
           run_valid := false;
           add_finding "missing_required_entities_declaration"
             (Printf.sprintf "manifest lacks required_entities_by_case for %s" case_id)
             false
             (Some case_id);
           []
       in
       List.iter
         (fun req_entity ->
            match req_entity with
            | "request_or_task_identity" ->
              if Option.is_none final_attempt.request_or_task_identity then (
                incr required_join_missing;
                run_valid := false;
                add_finding "missing_required_join"
                  (Printf.sprintf "missing request_or_task_identity in %s[%d]" case_id repeat_index)
                  false
                  (Some (Printf.sprintf "%s[%d]" case_id repeat_index))
              )
            | "run_turn_attempt_identity" ->
              if Option.is_none final_attempt.run_turn_attempt_identity then (
                incr required_join_missing;
                run_valid := false;
                add_finding "missing_required_join"
                  (Printf.sprintf "missing run_turn_attempt_identity in %s[%d]" case_id repeat_index)
                  false
                  (Some (Printf.sprintf "%s[%d]" case_id repeat_index))
              )
            | "target_revision" ->
              if Option.is_none final_attempt.target_revision then (
                incr required_join_missing;
                run_valid := false;
                add_finding "missing_required_join"
                  (Printf.sprintf "missing target_revision in %s[%d]" case_id repeat_index)
                  false
                  (Some (Printf.sprintf "%s[%d]" case_id repeat_index))
              )
            | "artifact_references" ->
              if final_attempt.artifact_references = [] then (
                incr required_join_missing;
                run_valid := false;
                add_finding "missing_required_join"
                  (Printf.sprintf "missing artifact_references in %s[%d]" case_id repeat_index)
                  false
                  (Some (Printf.sprintf "%s[%d]" case_id repeat_index))
              )
            | "verdict_run_identity" ->
              if Option.is_none final_attempt.verdict_run_identity then (
                incr required_join_missing;
                run_valid := false;
                add_finding "missing_required_join"
                  (Printf.sprintf "missing verdict_run_identity in %s[%d]" case_id repeat_index)
                  false
                  (Some (Printf.sprintf "%s[%d]" case_id repeat_index))
              )
            | other ->
              incr required_join_missing;
              run_valid := false;
              add_finding "unknown_required_entity"
                (Printf.sprintf "unknown required entity %s in %s[%d]" other case_id repeat_index)
                false
                (Some other))
         required_entities;

       (* Check phase timestamps presence and monotonicity using phase_boundaries_by_case *)
       let required_phase_boundaries =
         match List.assoc_opt case_id manifest.phase_boundaries_by_case with
         | Some boundaries -> boundaries
         | None ->
           run_valid := false;
           add_finding "missing_phase_boundaries_declaration"
             (Printf.sprintf "manifest lacks phase_boundaries_by_case for %s" case_id)
             false
             (Some case_id);
           []
       in
       List.iter
         (fun (o : run_observation) ->
            List.iter
              (fun b ->
                 let present =
                   match b with
                   | "queue_started_at" -> Option.is_some o.phase_timestamps.queue_started_at
                   | "model_started_at" -> Option.is_some o.phase_timestamps.model_started_at
                   | "model_ended_at" -> Option.is_some o.phase_timestamps.model_ended_at
                   | "tool_started_at" -> Option.is_some o.phase_timestamps.tool_started_at
                   | "tool_ended_at" -> Option.is_some o.phase_timestamps.tool_ended_at
                   | "verification_started_at" -> Option.is_some o.phase_timestamps.verification_started_at
                   | "verification_ended_at" -> Option.is_some o.phase_timestamps.verification_ended_at
                   | "cleanup_ended_at" -> Option.is_some o.phase_timestamps.cleanup_ended_at
                   | _ -> false
                 in
                 if not present then (
                   run_valid := false;
                   add_finding "missing_phase_boundary"
                     (Printf.sprintf "missing required phase boundary %s in %s[%d] run %s"
                        b case_id repeat_index o.run_id)
                     false
                     (Some (Printf.sprintf "%s:%s" o.run_id b))
                 ))
              required_phase_boundaries;
            if not (check_phase_boundary_order o.phase_timestamps) then (
              run_valid := false;
              add_finding "phase_boundary_order"
                (Printf.sprintf "phase timestamps not monotonic in %s[%d]" case_id repeat_index)
                false
                (Some o.run_id)
            ))
         run_obs;

       (* Check expected outcomes from manifest expected_outcomes map *)
       (match List.assoc_opt case_id manifest.expected_outcomes with
        | None ->
          run_valid := false;
          add_finding "missing_expected_outcome_declaration"
            (Printf.sprintf "manifest lacks expected_outcomes for %s" case_id)
            false
            (Some case_id)
        | Some expected_outcome ->
          let outcome_matches =
            match expected_outcome with
            | "verified" ->
              final_attempt.external_verified
              && final_attempt.verdict_passed
              && final_attempt.command_exit_code = Some 0
            | "command_exit_nonzero" ->
              (not final_attempt.external_verified)
              && final_attempt.command_exit_code <> Some 0
            | "stale_revision_rejected" ->
              not final_attempt.external_verified
            | "missing_artifact_rejected" ->
              (not final_attempt.external_verified)
              && final_attempt.artifact_references = []
            | "verified_after_retry" ->
              (not first_attempt.external_verified)
              && final_attempt.external_verified
            | "unreported_usage_preserved" ->
              (not final_attempt.external_verified)
              && (match final_attempt.usage with Usage_missing _ -> true | _ -> false)
            | _ -> false
          in
          if not outcome_matches then (
            run_valid := false;
            add_finding "manifest_expected_outcome_mismatch"
              (Printf.sprintf "run %s[%d] outcome did not match manifest expected outcome %s"
                 case_id repeat_index expected_outcome)
              false
              (Some (Printf.sprintf "expected=%s case=%s[%d]" expected_outcome case_id repeat_index))
          ));

       (* Check scenario-specific outcome rules using typed scenario variant *)
       (match final_attempt.scenario with
        | Matrix_scenario Success ->
          if (not final_attempt.external_verified)
             || (not final_attempt.verdict_passed)
             || final_attempt.command_exit_code <> Some 0
          then (
            run_valid := false;
            add_finding (Printf.sprintf "success_verification_failed_%d" repeat_index)
              (Printf.sprintf "matrix success run %d failed verification or exited nonzero" repeat_index)
              false
              (Some (Printf.sprintf "verified=%b passed=%b exit=%s"
                       final_attempt.external_verified
                       final_attempt.verdict_passed
                       (match final_attempt.command_exit_code with Some c -> string_of_int c | None -> "none")))
          )
        | Matrix_scenario Exit_nonzero ->
          if final_attempt.command_exit_code = Some 0 || final_attempt.external_verified then (
            incr false_verified;
            run_valid := false;
            add_finding (Printf.sprintf "exit_nonzero_false_verified_%d" repeat_index)
              (Printf.sprintf "matrix exit-nonzero run %d was falsely verified or exited 0" repeat_index)
              false
              (Some (Printf.sprintf "verified=%b exit=%s"
                       final_attempt.external_verified
                       (match final_attempt.command_exit_code with Some c -> string_of_int c | None -> "none")))
          )
        | Matrix_scenario Stale_revision ->
          if final_attempt.external_verified then (
            incr false_verified;
            run_valid := false;
            add_finding (Printf.sprintf "stale_revision_false_verified_%d" repeat_index)
              (Printf.sprintf "matrix stale-revision run %d was falsely verified" repeat_index)
              false
              (Some (Printf.sprintf "rev=%s" (match final_attempt.target_revision with Some r -> r | None -> "none")))
          )
        | Matrix_scenario Missing_artifact ->
          if final_attempt.external_verified then (
            incr false_verified;
            run_valid := false;
            add_finding (Printf.sprintf "missing_artifact_false_verified_%d" repeat_index)
              (Printf.sprintf "matrix missing-artifact run %d was falsely verified" repeat_index)
              false
              (Some (Printf.sprintf "run_id=%s" final_attempt.run_id))
          )
        | Matrix_scenario Retry_success ->
          if first_attempt.external_verified || (not final_attempt.external_verified) then (
            run_valid := false;
            add_finding (Printf.sprintf "retry_success_sequence_invalid_%d" repeat_index)
              (Printf.sprintf "matrix retry-success run %d first attempt must fail and final must verify" repeat_index)
              false
              (Some (Printf.sprintf "first_verified=%b final_verified=%b"
                       first_attempt.external_verified final_attempt.external_verified))
          );
          let totals = aggregate_run_usages run_obs in
          if totals.total_input_tokens <> 40
             || totals.total_output_tokens <> 8
             || totals.total_cache_read_input_tokens <> 8
             || totals.total_cost_usd <> Some 0.07
          then (
            incr totals_mismatch;
            run_valid := false;
            add_finding (Printf.sprintf "retry_success_fixture_rep_%d" repeat_index)
              "retry-success aggregated usage matches contract totals exactly (40/8/8/$0.07)"
              false
              (Some
                 (Printf.sprintf
                    "got in=%d out=%d cache=%d cost=%s"
                    totals.total_input_tokens
                    totals.total_output_tokens
                    totals.total_cache_read_input_tokens
                    (match totals.total_cost_usd_exact with
                     | Some c -> c
                     | None -> "null")))
          )
        | Matrix_scenario Usage_unreported ->
          (match final_attempt.usage with
           | Usage_reported r ->
             if r.input_tokens = 0 || r.output_tokens = 0 || r.cost_usd = Some 0.0 then (
               incr unknown_coerced_to_zero;
               run_valid := false;
               add_finding (Printf.sprintf "usage_unreported_coerced_zero_%d" repeat_index)
                 "usage-unreported run coerced unknown usage to 0"
                 false
                 (Some (Printf.sprintf "tokens=%d cost=%s"
                          r.input_tokens
                          (match r.cost_usd with Some c -> string_of_float c | None -> "none")))
             )
           | Usage_missing _ ->
             if final_attempt.external_verified then (
               run_valid := false;
               add_finding (Printf.sprintf "usage_unreported_unexpected_verify_%d" repeat_index)
                 "usage-unreported run was marked verified unexpectedly"
                 false
                 None
             ))
        | Live_scenario _ ->
          run_valid := false;
          add_finding (Printf.sprintf "invalid_live_scenario_in_matrix_%d" repeat_index)
            "matrix observation has live_scenario variant"
            false
            None);

       if !run_valid then incr matrix_runs_passed)
    run_keys_matrix;

  let matrix_passed = !matrix_runs_passed in

  (* 3. Process each live run *)
  let live_runs_passed = ref 0 in
  List.iter
    (fun (case_id, repeat_index) ->
       let run_obs =
         List.filter
           (fun (o : run_observation) ->
              o.case_id = case_id && o.repeat_index = repeat_index)
           live_obs
       in
       let sorted_attempts =
         List.sort (fun a b -> Int.compare a.attempt_sequence b.attempt_sequence) run_obs
       in
       let final_attempt = List.hd (List.rev sorted_attempts) in
       let first_attempt = List.hd sorted_attempts in
       let run_valid = ref true in

       (match final_attempt.scenario with
        | Live_scenario Live_success ->
          if not final_attempt.external_verified then (
            run_valid := false;
            add_finding (Printf.sprintf "live_success_failed_%d" repeat_index)
              "live success run failed external verification"
              false
              (Some final_attempt.run_id)
          )
        | Live_scenario Live_negative ->
          if final_attempt.external_verified then (
            incr false_verified;
            run_valid := false;
            add_finding (Printf.sprintf "live_negative_false_verified_%d" repeat_index)
              "live negative run was falsely verified"
              false
              (Some final_attempt.run_id)
          )
        | Live_scenario Live_retry_success ->
          (* Rule 68: The live retry needs an observed failed attempt and a real subsequent successful attempt. *)
          if List.length sorted_attempts < 2 then (
            run_valid := false;
            add_finding (Printf.sprintf "live_retry_missing_attempts_%d" repeat_index)
              "live retry requires at least 2 attempts (failed attempt + subsequent success)"
              false
              (Some (Printf.sprintf "attempts=%d" (List.length sorted_attempts)))
          ) else if first_attempt.external_verified then (
            run_valid := false;
            add_finding (Printf.sprintf "live_retry_first_attempt_not_failed_%d" repeat_index)
              "live retry first attempt must be an observed failed attempt"
              false
              None
          ) else if not final_attempt.external_verified then (
            run_valid := false;
            add_finding (Printf.sprintf "live_retry_final_attempt_not_success_%d" repeat_index)
              "live retry final attempt must be verified"
              false
              None
          )
        | Matrix_scenario _ ->
          run_valid := false;
          add_finding (Printf.sprintf "invalid_matrix_scenario_in_live_%d" repeat_index)
            "live observation has matrix_scenario variant"
            false
            None);

       if !run_valid then incr live_runs_passed)
    run_keys_live;

  let live_passed = !live_runs_passed in

  let overall_passed =
    matrix_observed = matrix_expected
    && matrix_passed = matrix_expected
    && live_observed = live_expected
    && live_passed = live_expected
    && !false_verified = 0
    && !required_join_missing = 0
    && !unknown_coerced_to_zero = 0
    && !duplicated_usage = 0
    && !totals_mismatch = 0
    && List.for_all (fun (f : check_finding) -> f.passed) !findings
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
    [ "contract_sha256", `String m.contract_sha256
    ; "source_commit", `String m.source_commit
    ; "binary_sha256", `String m.binary_sha256
    ; "runtime_config_sha256", `String m.runtime_config_sha256
    ; "model_identity", `String m.model_identity
    ; "workload_revision", `String m.workload_revision
    ; "execution_mode", `String m.execution_mode
    ; ( "expected_outcomes"
      , `Assoc (List.map (fun (k, v) -> k, `String v) m.expected_outcomes) )
    ; "case_ids", `List (List.map (fun id -> `String id) m.case_ids)
    ; ( "required_entities_by_case"
      , `Assoc
          (List.map
             (fun (k, vs) -> k, `List (List.map (fun v -> `String v) vs))
             m.required_entities_by_case) )
    ; ( "phase_boundaries_by_case"
      , `Assoc
          (List.map
             (fun (k, vs) -> k, `List (List.map (fun v -> `String v) vs))
             m.phase_boundaries_by_case) )
    ]
;;

let manifest_of_json (json : Yojson.Safe.t) : (manifest, string) result =
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
      |> List.map (fun (k, v) -> k, to_string v)
    in
    let required_entities_by_case =
      json
      |> member "required_entities_by_case"
      |> to_assoc
      |> List.map (fun (k, v) -> k, to_list v |> List.map to_string)
    in
    let phase_boundaries_by_case =
      json
      |> member "phase_boundaries_by_case"
      |> to_assoc
      |> List.map (fun (k, v) -> k, to_list v |> List.map to_string)
    in
    let cases =
      List.filter_map
        (fun cid ->
           match scenario_of_string cid with
           | Error _ -> None
           | Ok sc ->
             let exp_out =
               match List.assoc_opt cid expected_outcomes with
               | Some v -> v
               | None -> ""
             in
             let req_ent =
               match List.assoc_opt cid required_entities_by_case with
               | Some v -> v
               | None -> []
             in
             let ph_bnd =
               match List.assoc_opt cid phase_boundaries_by_case with
               | Some v -> v
               | None -> []
             in
             let exp_ver =
               match sc with
               | Success | Retry_success -> true
               | Exit_nonzero | Stale_revision | Missing_artifact | Usage_unreported -> false
             in
             Some
               { scenario = sc
               ; case_id = cid
               ; expected_verified = exp_ver
               ; expected_outcome = exp_out
               ; required_entities = req_ent
               ; phase_boundaries = ph_bnd
               })
        case_ids
    in
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
  with
  | Yojson.Json_error msg -> Error ("JSON syntax error: " ^ msg)
  | Yojson.Safe.Util.Type_error (msg, _) -> Error ("JSON type error: " ^ msg)
  | Failure msg -> Error msg
  | Invalid_argument msg -> Error msg
  | Not_found -> Error "Key or element not found"
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
        ; "cost_usd", (match r.cost_usd with Some c -> `Float c | None -> `Null)
        ; ( "cost_usd_exact"
          , match r.cost_usd_exact with Some s -> `String s | None -> `Null )
        ]
  in
  let pt_json =
    `Assoc
      [ "queue_started_at", (match o.phase_timestamps.queue_started_at with Some t -> `Float t | None -> `Null)
      ; "model_started_at", (match o.phase_timestamps.model_started_at with Some t -> `Float t | None -> `Null)
      ; "model_ended_at", (match o.phase_timestamps.model_ended_at with Some t -> `Float t | None -> `Null)
      ; "tool_started_at", (match o.phase_timestamps.tool_started_at with Some t -> `Float t | None -> `Null)
      ; "tool_ended_at", (match o.phase_timestamps.tool_ended_at with Some t -> `Float t | None -> `Null)
      ; "verification_started_at", (match o.phase_timestamps.verification_started_at with Some t -> `Float t | None -> `Null)
      ; "verification_ended_at", (match o.phase_timestamps.verification_ended_at with Some t -> `Float t | None -> `Null)
      ; "cleanup_ended_at", (match o.phase_timestamps.cleanup_ended_at with Some t -> `Float t | None -> `Null)
      ]
  in
  `Assoc
    [ "case_id", `String o.case_id
    ; "repeat_index", `Int o.repeat_index
    ; "run_id", `String o.run_id
    ; "execution_mode", `String o.execution_mode
    ; ( "request_or_task_identity"
      , match o.request_or_task_identity with Some s -> `String s | None -> `Null )
    ; ( "run_turn_attempt_identity"
      , match o.run_turn_attempt_identity with Some s -> `String s | None -> `Null )
    ; ( "target_revision"
      , match o.target_revision with Some s -> `String s | None -> `Null )
    ; ( "requested_revision"
      , match o.requested_revision with Some s -> `String s | None -> `Null )
    ; "artifact_references", `List (List.map (fun a -> `String a) o.artifact_references)
    ; ( "command_exit_code"
      , match o.command_exit_code with Some c -> `Int c | None -> `Null )
    ; "external_verified", `Bool o.external_verified
    ; ( "verdict_run_identity"
      , match o.verdict_run_identity with Some v -> `String v | None -> `Null )
    ; "verdict_passed", `Bool o.verdict_passed
    ; "usage", usage_json
    ; ( "usage_scope"
      , match o.usage_scope with Some s -> `String (usage_scope_to_string s) | None -> `Null )
    ; "phase_timestamps", pt_json
    ; "attempt_sequence", `Int o.attempt_sequence
    ; "total_attempts_in_run", `Int o.total_attempts_in_run
    ]
;;

let run_observation_of_json (json0 : Yojson.Safe.t) : (run_observation, string) result =
  try
    (* Harness and roadmap rows are flat: they have no nested "usage",
       "phase_timestamps" or similar objects. [member] on `Null raises
       "Can't get member ... of non-object type null", so normalize the root
       (and treat any absent nested object the same way below) instead of
       making every member lookup null-safe by hand. *)
    let json =
      match json0 with
      | `Null -> `Assoc []
      | other -> other
    in
    let case_id = json |> member "case_id" |> to_string in
    let repeat_index =
      match json |> member "repeat_index" |> to_int_option with
      | Some idx -> idx
      | None ->
        (match json |> member "run_index" |> to_int_option with
         | Some idx -> idx
         | None -> failwith "missing repeat_index or run_index")
    in
    let run_id =
      match json |> member "run_id" |> to_string_option with
      | Some id -> id
      | None ->
        (match json |> member "request" |> to_string_option with
         | Some r -> r
         | None -> Printf.sprintf "%s-%d" case_id repeat_index)
    in
    let execution_mode =
      match json |> member "execution_mode" |> to_string_option with
      | Some mode -> mode
      | None -> "matrix"
    in
    let scenario =
      match run_scenario_of_string ~execution_mode case_id with
      | Ok sc -> sc
      | Error err -> failwith err
    in
    let request_or_task_identity =
      match json |> member "request_or_task_identity" |> to_string_option with
      | Some req -> Some req
      | None ->
        (match json |> member "request_id" |> to_string_option with
         | Some req -> Some req
         | None -> json |> member "request" |> to_string_option)
    in
    let run_turn_attempt_identity =
      json |> member "run_turn_attempt_identity" |> to_string_option
    in
    let target_revision =
      json |> member "target_revision" |> to_string_option
    in
    let requested_revision =
      match json |> member "requested_revision" |> to_string_option with
      | Some rev -> Some rev
      | None -> target_revision
    in
    let artifact_references =
      match json |> member "artifact_references" |> to_option to_list with
      | Some list -> List.map to_string list
      | None ->
        (match json |> member "edited_target_files" |> to_option to_list with
         | Some list -> List.map to_string list
         | None -> [])
    in
    let command_exit_code =
      match json |> member "command_exit_code" |> to_int_option with
      | Some code -> Some code
      | None -> json |> member "verify_exit" |> to_int_option
    in
    let external_verified =
      match json |> member "external_verified" |> to_bool_option with
      | Some b -> b
      | None ->
        (match json |> member "passed" |> to_bool_option with
         | Some b -> b
         | None -> false)
    in
    let verdict_run_identity =
      json |> member "verdict_run_identity" |> to_string_option
    in
    let verdict_passed =
      match json |> member "verdict_passed" |> to_bool_option with
      | Some b -> b
      | None -> external_verified
    in
    let usage_scope =
      let raw_opt =
        match json |> member "usage_scope" |> to_string_option with
        | Some s -> Some s
        | None -> json |> member "scope" |> to_string_option
      in
      match raw_opt with
      | Some raw ->
        (match usage_scope_of_string raw with
         | Ok sc -> Some sc
         | Error err -> failwith err)
      | None -> None
    in
    let usage =
      let u =
        match json |> member "usage" with
        | `Null -> `Assoc []
        | other -> other
      in
      let reported =
        match u |> member "reported" |> to_bool_option with
        | Some b -> b
        | None ->
          (match json |> member "input_tokens" with
           | `Int _ -> true
           | _ ->
             (match u |> member "input_tokens" with
              | `Int _ -> true
              | _ -> false))
      in
      if reported then
        let input_tokens =
          match u |> member "input_tokens" |> to_int_option with
          | Some t -> t
          | None -> json |> member "input_tokens" |> to_int
        in
        let output_tokens =
          match u |> member "output_tokens" |> to_int_option with
          | Some t -> t
          | None -> json |> member "output_tokens" |> to_int
        in
        let cache_read_input_tokens =
          match u |> member "cache_read_input_tokens" |> to_int_option with
          | Some t -> t
          | None ->
            (match json |> member "cache_read_input_tokens" |> to_int_option with
             | Some t -> t
             | None -> 0)
        in
        let parse_cost json_node =
          match json_node with
          | `Float f -> Some f
          | `Int i -> Some (float_of_int i)
          | `String s -> (try Some (float_of_string s) with Failure _ -> None)
          | _ -> None
        in
        let cost_usd =
          match parse_cost (u |> member "cost_usd") with
          | Some c -> Some c
          | None -> parse_cost (json |> member "cost_usd")
        in
        let cost_usd_exact =
          match u |> member "cost_usd_exact" |> to_string_option with
          | Some s -> Some s
          | None ->
            (match u |> member "cost_usd" with
             | `String s -> Some s
             | _ ->
               (match json |> member "cost_usd" with
                | `String s -> Some s
                | _ ->
                  (match cost_usd with
                   | Some c -> Some (Printf.sprintf "%.2f" c)
                   | None -> None)))
        in
        Usage_reported
          { input_tokens
          ; output_tokens
          ; cache_read_input_tokens
          ; cost_usd
          ; cost_usd_exact
          }
      else
        let reason =
          match u |> member "reason" |> to_string_option with
          | Some r -> r
          | None ->
            (match json |> member "error" |> to_string_option with
             | Some e -> e
             | None -> "unreported")
        in
        Usage_missing reason
    in
    let pt =
      match json |> member "phase_timestamps" with
      | `Null -> `Assoc []
      | other -> other
    in
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
      match json |> member "attempt_sequence" |> to_int_option with
      | Some seq -> seq
      | None -> 1
    in
    let total_attempts_in_run =
      match json |> member "total_attempts_in_run" |> to_int_option with
      | Some tot -> tot
      | None -> 1
    in
    Ok
      { case_id
      ; scenario
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
  with
  | Yojson.Json_error msg -> Error ("JSON syntax error: " ^ msg)
  | Yojson.Safe.Util.Type_error (msg, _) -> Error ("JSON type error: " ^ msg)
  | Failure msg -> Error msg
  | Invalid_argument msg -> Error msg
  | Not_found -> Error "Key or element not found"
;;

let checker_summary_to_json (s : checker_summary) : Yojson.Safe.t =
  let findings_json =
    List.map
      (fun f ->
         `Assoc
           [ "rule_id", `String f.rule_id
           ; "description", `String f.description
           ; "passed", `Bool f.passed
           ; ( "detail"
             , match f.detail with Some d -> `String d | None -> `Null )
           ])
      s.findings
  in
  `Assoc
    [ "matrix_expected", `Int s.matrix_expected
    ; "matrix_observed", `Int s.matrix_observed
    ; "matrix_passed", `Int s.matrix_passed
    ; "live_expected", `Int s.live_expected
    ; "live_observed", `Int s.live_observed
    ; "live_passed", `Int s.live_passed
    ; "false_verified_count", `Int s.false_verified_count
    ; "required_join_missing_count", `Int s.required_join_missing_count
    ; ( "unknown_usage_coerced_to_zero_count"
      , `Int s.unknown_usage_coerced_to_zero_count )
    ; "duplicated_usage_count", `Int s.duplicated_usage_count
    ; ( "reported_usage_totals_mismatch_count"
      , `Int s.reported_usage_totals_mismatch_count )
    ; "overall_passed", `Bool s.overall_passed
    ; "findings", `List findings_json
    ]
;;

let checker_summary_of_json (json : Yojson.Safe.t) : (checker_summary, string) result =
  try
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
    let duplicated_usage_count =
      json |> member "duplicated_usage_count" |> to_int
    in
    let reported_usage_totals_mismatch_count =
      json |> member "reported_usage_totals_mismatch_count" |> to_int
    in
    let overall_passed = json |> member "overall_passed" |> to_bool in
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
  with
  | Yojson.Json_error msg -> Error ("JSON syntax error: " ^ msg)
  | Yojson.Safe.Util.Type_error (msg, _) -> Error ("JSON type error: " ^ msg)
  | Failure msg -> Error msg
  | Invalid_argument msg -> Error msg
  | Not_found -> Error "Key or element not found"
;;

let summary_to_json (s : checker_summary) : Yojson.Safe.t =
  `Assoc
    [ "matrix_expected", `Int s.matrix_expected
    ; "matrix_observed", `Int s.matrix_observed
    ; "matrix_passed", `Int s.matrix_passed
    ; "live_expected", `Int s.live_expected
    ; "live_observed", `Int s.live_observed
    ; "live_passed", `Int s.live_passed
    ; "false_verified_count", `Int s.false_verified_count
    ; "required_join_missing_count", `Int s.required_join_missing_count
    ; ( "unknown_usage_coerced_to_zero_count"
      , `Int s.unknown_usage_coerced_to_zero_count )
    ; "duplicated_usage_count", `Int s.duplicated_usage_count
    ; ( "reported_usage_totals_mismatch_count"
      , `Int s.reported_usage_totals_mismatch_count )
    ; "overall_passed", `Bool s.overall_passed
    ]
;;

let write_file_string (path : string) (contents : string) : (unit, string) result =
  match open_out_bin path with
  | exception Sys_error msg -> Error (Printf.sprintf "cannot open %s for writing: %s" path msg)
  | oc ->
    Fun.protect
      ~finally:(fun () -> close_out_noerr oc)
      (fun () ->
         output_string oc contents;
         Ok ())
;;

let write_checker_file (path : string) (s : checker_summary) : (unit, string) result =
  let json = checker_summary_to_json s in
  write_file_string path (Yojson.Safe.pretty_to_string json ^ "\n")
;;

let write_summary_file (path : string) (s : checker_summary) : (unit, string) result =
  let json = summary_to_json s in
  write_file_string path (Yojson.Safe.pretty_to_string json ^ "\n")
;;

let load_manifest_file (path : string) : (manifest, string) result =
  match open_in_bin path with
  | exception Sys_error msg -> Error (Printf.sprintf "cannot open %s: %s" path msg)
  | ic ->
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
         let len = in_channel_length ic in
         let content = really_input_string ic len in
         let json_res =
           try Ok (Yojson.Safe.from_string content) with
           | Yojson.Json_error msg -> Error (Printf.sprintf "%s: JSON syntax error: %s" path msg)
           | Failure msg -> Error (Printf.sprintf "%s: %s" path msg)
         in
         match json_res with
         | Error _ as err -> err
         | Ok json -> manifest_of_json json)
;;

let load_observations_file (path : string) : (run_observation list, string) result =
  match open_in_bin path with
  | exception Sys_error msg -> Error (Printf.sprintf "cannot open %s: %s" path msg)
  | ic ->
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
         let rec loop line_num acc =
           match input_line ic with
           | exception End_of_file -> Ok (List.rev acc)
           | line ->
             let trimmed = String.trim line in
             if trimmed = "" then loop (line_num + 1) acc
             else
               let json_res =
                 try Ok (Yojson.Safe.from_string trimmed) with
                 | Yojson.Json_error msg ->
                   Error (Printf.sprintf "%s:%d: JSON parse error: %s" path line_num msg)
                 | Failure msg ->
                   Error (Printf.sprintf "%s:%d: %s" path line_num msg)
               in
               match json_res with
               | Error _ as err -> err
               | Ok json ->
                 match run_observation_of_json json with
                 | Error err ->
                   Error (Printf.sprintf "%s:%d: invalid run observation: %s" path line_num err)
                 | Ok obs -> loop (line_num + 1) (obs :: acc)
         in
         loop 1 [])
;;

