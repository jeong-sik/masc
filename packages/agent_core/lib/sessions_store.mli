(** Sessions store operations — file I/O, artifact retrieval, raw trace access.

    Read-from-store operations that bridge the runtime file layout
    with the typed Sessions domain.

    @stability Internal
    @since 0.93.1

    {2 Readers with no caller}

    Several readers below have no caller anywhere in the tree, and
    [scripts/audit-dead-surface.py --exports] reports them every run. Six are
    accounted for: their artifact writers were removed in v0.217.x and the
    readers were kept on purpose, recorded as frozen surfaces in
    [docs/schema-surfaces/runtime-output-surfaces.v1.json].

    - [get_report] — agent_core.runtime_report.v1
    - [get_proof] — agent_core.runtime_proof.v1
    - [get_telemetry], [get_telemetry_structured] — agent_core.runtime_telemetry_report.v1
    - [get_evidence] — agent_core.runtime_evidence_bundle.v1
    - [get_raw_trace_manifest] — agent_core.raw_trace_manifest.v1

    The rest have no caller and no such entry: [get_artifact_text],
    [get_hook_summary], [get_named_artifact], [get_optional_named_artifact],
    [get_raw_trace_dir], [get_raw_trace_files], [get_session_events],
    [get_tool_catalog], [latest_named_artifact], [list_artifacts],
    [rename_session], [tag_session], [validate_runs]. Whether those are a
    surface waiting for a consumer or weight to drop is not recorded anywhere,
    which is why they are named here rather than left for the next sweep to
    rediscover. *)

open Sessions_types

(** {1 Store construction} *)

val make_store : ?session_root:string -> unit -> (Runtime_store.t, Error.t) result

(** {1 Helpers} *)

val file_read_error : path:string -> detail:string -> Error.t
val first_some : 'a option -> 'a option -> 'a option
val primary_alias : string list -> string option
val latest_named_artifact : Runtime.artifact list -> string -> Runtime.artifact option

(** {1 Session access} *)

val list_sessions
  :  ?session_root:string
  -> unit
  -> (session_info list, Error.t) result

val get_session
  :  ?session_root:string
  -> string
  -> (Runtime.session, Error.t) result

val get_session_events
  :  ?session_root:string
  -> string
  -> (Runtime.event list, Error.t) result

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

(** {1 Artifacts} *)

val get_named_artifact
  :  ?session_root:string
  -> session_id:string
  -> name:string
  -> unit
  -> (Runtime.artifact, Error.t) result

val get_optional_named_artifact
  :  ?session_root:string
  -> session_id:string
  -> name:string
  -> unit
  -> (Runtime.artifact option, Error.t) result

val list_artifacts
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (Runtime.artifact list, Error.t) result

val get_artifact_text
  :  ?session_root:string
  -> session_id:string
  -> artifact_id:string
  -> unit
  -> (string, Error.t) result

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

(** {1 Hooks} *)

val get_hook_summary
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (hook_summary list, Error.t) result

(** {1 Tool catalog} *)

val get_tool_catalog
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (tool_contract list, Error.t) result

(** {1 Raw trace} *)

val get_raw_trace_dir
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (string, Error.t) result

val get_raw_trace_files
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (string list, Error.t) result

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

val validate_runs
  :  raw_trace_run list
  -> (raw_trace_validation list, Error.t) result

val get_raw_trace_validations
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (raw_trace_validation list, Error.t) result

(** {1 Session mutation} *)

val rename_session
  :  ?session_root:string
  -> session_id:string
  -> title:string
  -> unit
  -> (unit, Error.t) result

val tag_session
  :  ?session_root:string
  -> session_id:string
  -> tag:string option
  -> unit
  -> (unit, Error.t) result
