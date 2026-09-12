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

type live_scenario =
  | Live_success
  | Live_negative
  | Live_retry_success

type run_scenario =
  | Matrix_scenario of scenario
  | Live_scenario of live_scenario

val run_scenario_of_string : execution_mode:string -> string -> (run_scenario, string) result

type usage_scope =
  | Per_request
  | Cumulative_request_snapshot

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

val default_case_manifests : unit -> case_manifest list

val make_manifest :
     contract_sha256:string
  -> source_commit:string
  -> binary_sha256:string
  -> runtime_config_sha256:string
  -> model_identity:string
  -> workload_revision:string
  -> execution_mode:string
  -> manifest

type usage_totals =
  { total_input_tokens : int
  ; total_output_tokens : int
  ; total_cache_read_input_tokens : int
  ; total_cost_usd : float option
  ; total_cost_usd_exact : string option
  }

val aggregate_run_usages : run_observation list -> usage_totals

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

val check_observations :
     manifest:manifest
  -> observations:run_observation list
  -> checker_summary

val manifest_to_json : manifest -> Yojson.Safe.t
val manifest_of_json : Yojson.Safe.t -> (manifest, string) result

val run_observation_to_json : run_observation -> Yojson.Safe.t
val run_observation_of_json : Yojson.Safe.t -> (run_observation, string) result

val checker_summary_to_json : checker_summary -> Yojson.Safe.t
val checker_summary_of_json : Yojson.Safe.t -> (checker_summary, string) result

val summary_to_json : checker_summary -> Yojson.Safe.t

val load_manifest_file : string -> (manifest, string) result
val load_observations_file : string -> (run_observation list, string) result

val write_checker_file : string -> checker_summary -> (unit, string) result
val write_summary_file : string -> checker_summary -> (unit, string) result
