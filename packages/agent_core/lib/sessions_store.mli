(** Sessions store operations — file I/O, artifact retrieval, raw trace access.

    Read-from-store operations that bridge the runtime file layout
    with the typed Sessions domain.

    @stability Internal
    @since 0.93.1 *)

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
