(** Per-request projection-timing tracker for dashboard shell endpoints.

    Used by [Server_dashboard_http_core] to annotate the response with
    per-projection elapsed-ms breakdowns and to expose the in-flight set
    on the diagnostics endpoint. *)

type shell_projection_timing =
  { projection_label : string
  ; projection_ms : int
  }

type shell_projection_trace_status =
  | Shell_trace_running
  | Shell_trace_finished
  | Shell_trace_failed

type shell_projection_trace =
  { trace_light : bool
  ; trace_started_at : float
  ; mutable trace_status : shell_projection_trace_status
  ; mutable trace_active : string list
  ; mutable trace_completed : shell_projection_timing list
  ; mutable trace_finished_at : float option
  }

type shell_projection_trace_snapshot =
  { snapshot_status : shell_projection_trace_status
  ; snapshot_light : bool
  ; snapshot_elapsed_ms : int
  ; snapshot_active : string list
  ; snapshot_completed : shell_projection_timing list
  ; snapshot_finished_at : float option
  }

val status_string : shell_projection_trace_status -> string
val timing_top : shell_projection_timing list -> shell_projection_timing list
val timing_json : shell_projection_timing -> Yojson.Safe.t
val timing_log : shell_projection_timing list -> string

val start : cache_key:string -> light:bool -> shell_projection_trace
val start_projection : shell_projection_trace -> string -> unit
val finish_projection : shell_projection_trace -> string -> int -> unit

val finish
  :  ?clear_active:bool
  -> shell_projection_trace
  -> shell_projection_trace_status
  -> unit

val snapshot : string -> shell_projection_trace_snapshot option
val diagnostics : string -> (string * Yojson.Safe.t) list
val log : string -> string * string * string * int
