(** Sessions store operations — file I/O, artifact retrieval, raw trace access.

    Read-from-store operations that bridge the runtime file layout
    with the typed Sessions domain.

    @stability Internal
    @since 0.93.1

    {2 Readers with no caller}

    Six readers below still have no caller, and
    [scripts/audit-dead-surface.py --exports] reports them every run. They are
    kept on purpose: their artifact writers were removed in v0.217.x and the
    readers were retained, recorded as frozen surfaces in
    [docs/schema-surfaces/runtime-output-surfaces.v1.json].

    - [get_report] — agent_core.runtime_report.v1
    - [get_proof] — agent_core.runtime_proof.v1
    - [get_telemetry], [get_telemetry_structured] — agent_core.runtime_telemetry_report.v1
    - [get_evidence] — agent_core.runtime_evidence_bundle.v1
    - [get_raw_trace_manifest] — agent_core.raw_trace_manifest.v1

    Anything the audit reports here beyond those six is a reader nothing
    accounts for. Thirteen were in that position and none are exported now:
    eight are gone, and five stayed as private values because the six above
    call them -- [get_named_artifact], [get_raw_trace_dir],
    [get_raw_trace_files], [latest_named_artifact] and [validate_runs]. *)

open Sessions_types

(** {1 Store construction} *)

val make_store : ?session_root:string -> unit -> (Runtime_store.t, Error.t) result

(** {1 Helpers} *)

val file_read_error : path:string -> detail:string -> Error.t
val first_some : 'a option -> 'a option -> 'a option
val primary_alias : string list -> string option
(** {1 Session access} *)

val list_sessions
  :  ?session_root:string
  -> unit
  -> (session_info list, Error.t) result

val get_session
  :  ?session_root:string
  -> string
  -> (Runtime.session, Error.t) result

(** {1 Report / Proof} *)

val get_report
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (Runtime.report, Error.t) result

val get_proof
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (Runtime.proof, Error.t) result

(** {1 Telemetry} *)

val get_telemetry
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (telemetry, Error.t) result

val get_telemetry_structured
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (structured_telemetry, Error.t) result

(** {1 Evidence} *)

val get_evidence
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (evidence, Error.t) result

val get_raw_trace_manifest
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (raw_trace_manifest, Error.t) result

(** {1 Raw trace} *)

val get_raw_trace_runs
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (raw_trace_run list, Error.t) result

val get_raw_trace_run
  :  ?session_root:string
  -> session_id:string
  -> worker_run_id:string
  -> unit
  -> (raw_trace_run, Error.t) result

val get_raw_trace_records
  :  ?session_root:string
  -> session_id:string
  -> worker_run_id:string
  -> unit
  -> (Raw_trace.record list, Error.t) result

val get_raw_trace_summary
  :  ?session_root:string
  -> session_id:string
  -> worker_run_id:string
  -> unit
  -> (raw_trace_summary, Error.t) result

val validate_raw_trace_run
  :  ?session_root:string
  -> session_id:string
  -> worker_run_id:string
  -> unit
  -> (raw_trace_validation, Error.t) result

val get_latest_raw_trace_run
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (raw_trace_run option, Error.t) result

val summarize_runs
  :  raw_trace_run list
  -> (raw_trace_summary list, Error.t) result

val get_raw_trace_summaries
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (raw_trace_summary list, Error.t) result

val get_raw_trace_validations
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (raw_trace_validation list, Error.t) result
