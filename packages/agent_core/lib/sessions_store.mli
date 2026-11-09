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
