(** Sessions type definitions — pure data structures.

    All types carry [@@deriving yojson, show] for serialisation.

    @stability Internal
    @since 0.93.1 *)

type trace_capability =
  | Raw [@name "raw"]
  | Summary_only [@name "summary_only"]
  | No_trace [@name "none"]
[@@deriving yojson, show]

type session_info =
  { session_id : string
  ; title : string option
  ; tag : string option
  ; goal : string
  ; updated_at : float
  ; phase : Runtime.phase
  ; participant_count : int
  ; path : string
  }
[@@deriving yojson, show]

type telemetry_event_count =
  { name : string
  ; count : int
  }
[@@deriving yojson, show]

type telemetry_step =
  { seq : int
  ; ts : float
  ; kind : string
  ; participant : string option
  ; detail : string option
  }
[@@deriving yojson, show]

type telemetry =
  { session_id : string
  ; generated_at : float
  ; step_count : int
  ; event_counts : telemetry_event_count list
  ; steps : telemetry_step list
  }
[@@deriving yojson, show]

type structured_event_count =
  { event_name : string
  ; count : int
  }
[@@deriving yojson, show]

type structured_telemetry_step =
  { seq : int
  ; ts : float
  ; event_name : string
  ; participant : string option
  ; detail : string option
  ; actor : string option
  ; role : string option
  ; provider : string option
  ; model : string option
  ; raw_trace_run_id : string option
  ; stop_reason : string option
  ; artifact_id : string option
  ; artifact_name : string option
  ; artifact_kind : string option
  ; checkpoint_label : string option
  ; outcome : string option
  ; dropped_output_deltas : int option
  ; persistence_failure_phase : string option
  }
[@@deriving yojson, show]

type structured_telemetry =
  { session_id : string
  ; generated_at : float
  ; step_count : int
  ; event_counts : structured_event_count list
  ; steps : structured_telemetry_step list
  }
[@@deriving yojson, show]

type evidence_file =
  { label : string
  ; path : string
  ; size_bytes : int
  ; md5 : string
  }
[@@deriving yojson, show]

type missing_file =
  { label : string
  ; path : string
  }
[@@deriving yojson, show]

type evidence =
  { session_id : string
  ; generated_at : float
  ; files : evidence_file list
  ; missing_files : missing_file list
  }
[@@deriving yojson, show]

type hook_summary =
  { hook_name : string
  ; count : int
  ; latest_decision : string option
  ; latest_detail : string option
  ; latest_ts : float option
  }
[@@deriving yojson, show]

type tool_contract =
  { name : string
  ; description : string
  ; origin : string option
  ; execution_mode : Tool_contract.execution_mode
  ; completion : Tool_contract.completion
  }
[@@deriving show]

val tool_contract_to_yojson : tool_contract -> Yojson.Safe.t
val tool_contract_of_yojson : Yojson.Safe.t -> (tool_contract, string) result

type raw_trace_run = Raw_trace.run_ref [@@deriving yojson, show]
type raw_trace_summary = Raw_trace.run_summary [@@deriving yojson, show]
type raw_trace_validation = Raw_trace.run_validation [@@deriving yojson, show]

type raw_trace_manifest =
  { session_id : string
  ; generated_at : float
  ; latest_raw_trace_run : raw_trace_run option
  ; raw_trace_runs : raw_trace_run list
  ; raw_trace_summaries : raw_trace_summary list
  ; raw_trace_validations : raw_trace_validation list
  }
[@@deriving yojson, show]

type worker_status =
  | Planned [@name "planned"]
  | Accepted [@name "accepted"]
  | Ready [@name "ready"]
  | Running [@name "running"]
  | Completed [@name "completed"]
  | Failed [@name "failed"]
[@@deriving yojson, show]

type worker_run =
  { worker_run_id : string
  ; worker_id : string option
  ; agent_name : string
  ; runtime_actor : string option
  ; role : string option
  ; aliases : string list
  ; primary_alias : string option
  ; provider : string option
  ; model : string option
  ; requested_provider : string option
  ; requested_model : string option
  ; resolved_provider : string option
  ; resolved_model : string option
  ; status : worker_status
  ; trace_capability : trace_capability
  ; validated : bool
  ; tool_names : string list
  ; final_text : string option
  ; stop_reason : string option
  ; error : string option
  ; failure_reason : string option
  ; accepted_at : float option
  ; ready_at : float option
  ; first_progress_at : float option
  ; started_at : float option
  ; finished_at : float option
  ; last_progress_at : float option
  ; paired_tool_result_count : int
  }
[@@deriving yojson, show]

type evidence_capabilities =
  { raw_trace : bool
  ; validated_summary : bool
  ; proof_bundle : bool
  }
[@@deriving yojson, show]

type proof_bundle =
  { session : Runtime.session
  ; report : Runtime.report
  ; proof : Runtime.proof
  ; telemetry : telemetry
  ; structured_telemetry : structured_telemetry
  ; evidence : evidence
  ; hook_summary : hook_summary list
  ; tool_catalog : tool_contract list
  ; latest_raw_trace_run : raw_trace_run option
  ; raw_trace_runs : raw_trace_run list
  ; raw_trace_summaries : raw_trace_summary list
  ; raw_trace_validations : raw_trace_validation list
  ; worker_runs : worker_run list
  ; latest_accepted_worker_run : worker_run option
  ; latest_ready_worker_run : worker_run option
  ; latest_running_worker_run : worker_run option
  ; latest_worker_run : worker_run option
  ; latest_completed_worker_run : worker_run option
  ; latest_validated_worker_run : worker_run option
  ; latest_failed_worker_run : worker_run option
  ; validated_worker_runs : worker_run list
  ; raw_trace_run_count : int
  ; validated_worker_run_count : int
  ; trace_capabilities : trace_capability list
  ; capabilities : evidence_capabilities
  }
[@@deriving yojson, show]
