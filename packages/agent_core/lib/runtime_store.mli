(** File-based session store for the OAS runtime.

    Provides path construction, text I/O, and serialization for
    sessions, events, artifacts, reports, and proofs.

    @stability Internal
    @since 0.93.1 *)

(** Store handle wrapping a root directory. *)
type t = { root : string }

(** One loadable runtime run from the store. [path] points at the canonical
    [session.json]. Run ordering is deterministic: ascending
    [session.updated_at], then ascending [session.session_id]. *)
type run_record =
  { session : Runtime.session
  ; path : string
  }

(** Non-fatal run/window read failure. Listing APIs keep loading other runs
    and report corrupted or incomplete directories here. *)
type run_load_failure =
  { session_id : string
  ; path : string
  ; detail : string
  }

type run_listing =
  { runs : run_record list
  ; failures : run_load_failure list
  }

(** Runtime replay window selector.

    [Last_n_runs n] selects the newest [n] valid runs by the stable ordering,
    then returns them in chronological order. [Rolling_seconds s] uses the
    newest valid run's [updated_at] as the anchor and selects runs with
    [updated_at >= anchor - s]. This makes replay deterministic and avoids
    wall-clock-dependent tests. *)
type run_window =
  | Last_n_runs of int
  | Session of string
  | Rolling_seconds of float

type run_event_record =
  { event_id : string
  ; session_id : string
  ; event : Runtime.event
  }

type run_window_events =
  { runs : run_record list
  ; events : run_event_record list
  ; failures : run_load_failure list
  }

(** {1 Store creation} *)

val create : ?root:string -> unit -> (t, Error.sdk_error) result
val ensure_dir : string -> (unit, Error.sdk_error) result
val ensure_tree : t -> string -> (unit, Error.sdk_error) result

(** {1 Path constructors} *)

val sessions_dir : t -> string
val session_dir : t -> string -> string
val session_path : t -> string -> string
val events_path : t -> string -> string
val snapshots_dir : t -> string -> string
val artifacts_dir : t -> string -> string
val raw_traces_dir : t -> string -> string
val report_json_path : t -> string -> string
val report_md_path : t -> string -> string
val proof_json_path : t -> string -> string
val proof_md_path : t -> string -> string

(** {1 Text I/O} *)

val save_text : string -> string -> (unit, Error.sdk_error) result
val load_text : string -> (string, Error.sdk_error) result

(** {1 Session I/O} *)

val save_session : t -> Runtime.session -> (unit, Error.sdk_error) result
val load_session : t -> string -> (Runtime.session, Error.sdk_error) result
val list_runs : t -> (run_listing, Error.sdk_error) result
val select_run_windows : t -> run_window list -> (run_listing, Error.sdk_error) result

val read_window_events
  :  t
  -> run_window list
  -> (run_window_events, Error.sdk_error) result

(** {1 Event I/O} *)

val append_event : t -> string -> Runtime.event -> (unit, Error.sdk_error) result

val read_events
  :  t
  -> string
  -> ?after_seq:int
  -> unit
  -> (Runtime.event list, Error.sdk_error) result

(** {1 Snapshots} *)

val snapshot_path : t -> string -> seq:int -> label:string option -> string

val save_snapshot
  :  t
  -> Runtime.session
  -> label:string option
  -> (string, Error.sdk_error) result

(** {1 Artifacts} *)

val save_artifact_text
  :  t
  -> string
  -> name:string
  -> kind:string
  -> content:string
  -> (string, Error.sdk_error) result

(** {1 Reports and proofs} *)

val save_report : t -> Runtime.report -> (unit, Error.sdk_error) result
val save_proof : t -> Runtime.proof -> (unit, Error.sdk_error) result
