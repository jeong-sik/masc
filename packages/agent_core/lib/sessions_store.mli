(** Sessions store operations — file I/O, artifact retrieval, raw trace access.

    Read-from-store operations that bridge the runtime file layout
    with the typed Sessions domain.

    @stability Internal
    @since 0.93.1 *)

open Sessions_types

(** {1 Store construction} *)

val make_store : ?session_root:string -> unit -> (Runtime_store.t, Error.sdk_error) result

(** {1 Helpers} *)

val file_read_error : path:string -> detail:string -> Error.sdk_error
val first_some : 'a option -> 'a option -> 'a option
val primary_alias : string list -> string option
val latest_named_artifact : Runtime.artifact list -> string -> Runtime.artifact option

(** {1 Session access} *)

val list_sessions
  :  ?session_root:string
  -> unit
  -> (session_info list, Error.sdk_error) result

val get_session
  :  ?session_root:string
  -> string
  -> (Runtime.session, Error.sdk_error) result

val get_session_events
  :  ?session_root:string
  -> string
  -> (Runtime.event list, Error.sdk_error) result

(** {1 Report / Proof} *)

val get_report
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (Runtime.report, Error.sdk_error) result

val get_proof
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (Runtime.proof, Error.sdk_error) result

(** {1 Artifacts} *)

val get_named_artifact
  :  ?session_root:string
  -> session_id:string
  -> name:string
  -> unit
  -> (Runtime.artifact, Error.sdk_error) result

val get_optional_named_artifact
  :  ?session_root:string
  -> session_id:string
  -> name:string
  -> unit
  -> (Runtime.artifact option, Error.sdk_error) result

val list_artifacts
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (Runtime.artifact list, Error.sdk_error) result

val get_artifact_text
  :  ?session_root:string
  -> session_id:string
  -> artifact_id:string
  -> unit
  -> (string, Error.sdk_error) result

(** {1 Telemetry} *)

val get_telemetry
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (telemetry, Error.sdk_error) result

val get_telemetry_structured
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (structured_telemetry, Error.sdk_error) result

(** {1 Evidence} *)

val get_evidence
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (evidence, Error.sdk_error) result

val get_raw_trace_manifest
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (raw_trace_manifest, Error.sdk_error) result

(** {1 Hooks} *)

val get_hook_summary
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (hook_summary list, Error.sdk_error) result

(** {1 Tool catalog} *)

val get_tool_catalog
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (tool_contract list, Error.sdk_error) result

(** {1 Raw trace} *)

val get_raw_trace_dir
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (string, Error.sdk_error) result

val get_raw_trace_files
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (string list, Error.sdk_error) result

val get_raw_trace_runs
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (raw_trace_run list, Error.sdk_error) result

val get_raw_trace_run
  :  ?session_root:string
  -> session_id:string
  -> worker_run_id:string
  -> unit
  -> (raw_trace_run, Error.sdk_error) result

val get_raw_trace_records
  :  ?session_root:string
  -> session_id:string
  -> worker_run_id:string
  -> unit
  -> (Raw_trace.record list, Error.sdk_error) result

val get_raw_trace_summary
  :  ?session_root:string
  -> session_id:string
  -> worker_run_id:string
  -> unit
  -> (raw_trace_summary, Error.sdk_error) result

val validate_raw_trace_run
  :  ?session_root:string
  -> session_id:string
  -> worker_run_id:string
  -> unit
  -> (raw_trace_validation, Error.sdk_error) result

val get_latest_raw_trace_run
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (raw_trace_run option, Error.sdk_error) result

val summarize_runs
  :  raw_trace_run list
  -> (raw_trace_summary list, Error.sdk_error) result

val get_raw_trace_summaries
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (raw_trace_summary list, Error.sdk_error) result

val validate_runs
  :  raw_trace_run list
  -> (raw_trace_validation list, Error.sdk_error) result

val get_raw_trace_validations
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (raw_trace_validation list, Error.sdk_error) result

(** {1 Session mutation} *)

val rename_session
  :  ?session_root:string
  -> session_id:string
  -> title:string
  -> unit
  -> (unit, Error.sdk_error) result

val tag_session
  :  ?session_root:string
  -> session_id:string
  -> tag:string option
  -> unit
  -> (unit, Error.sdk_error) result
