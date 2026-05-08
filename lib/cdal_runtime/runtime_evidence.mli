(** Runtime evidence: telemetry reports and evidence bundles.

    Generates structured telemetry from session events and
    collects file-level evidence with MD5 checksums.

    @stability Internal
    @since 0.93.1 *)

type telemetry_step =
  { seq : int
  ; ts : float
  ; event_name : string
  ; kind : string
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

type telemetry_report =
  { session_id : string
  ; generated_at : float
  ; step_count : int
  ; event_counts : (string * int) list
  ; event_name_counts : (string * int) list
  ; dropped_output_deltas : int
  ; persistence_failure_count : int
  ; participants_with_dropped_output_deltas : string list
  ; participants_with_persistence_failures : string list
  ; steps : telemetry_step list
  }

type evidence_file =
  { label : string
  ; path : string
  ; size_bytes : int
  ; md5 : string
  }

type evidence_bundle =
  { session_id : string
  ; generated_at : float
  ; files : evidence_file list
  ; missing_files : (string * string) list
  }

type raw_trace_manifest = Sessions.raw_trace_manifest

val now : unit -> float
val runtime_persist_failure_prefix : string
val dropped_output_deltas_marker : string
val encode_persist_failure_detail : phase:string -> string -> string

val append_dropped_output_deltas_summary
  :  summary:string
  -> dropped_output_deltas:int
  -> string

val artifact_attached_event : Runtime.artifact -> Runtime.event_kind
val base_evidence_file_specs : Runtime_store.t -> string -> (string * string) list
val build_telemetry_report : Runtime.session -> Runtime.event list -> telemetry_report
val telemetry_report_to_json : telemetry_report -> Yojson.Safe.t
val telemetry_report_to_markdown : telemetry_report -> string
val build_evidence_bundle : session_id:string -> (string * string) list -> evidence_bundle
val evidence_bundle_to_json : evidence_bundle -> Yojson.Safe.t

val build_raw_trace_manifest
  :  session_id:string
  -> latest_raw_trace_run:Sessions.raw_trace_run option
  -> raw_trace_runs:Sessions.raw_trace_run list
  -> raw_trace_summaries:Sessions.raw_trace_summary list
  -> raw_trace_validations:Sessions.raw_trace_validation list
  -> raw_trace_manifest

val raw_trace_manifest_to_json : raw_trace_manifest -> Yojson.Safe.t
