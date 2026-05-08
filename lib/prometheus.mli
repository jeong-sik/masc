(** Prometheus-Compatible Metrics for masc-mcp.

    Lightweight metrics collection with Prometheus text format export.
    Thread-safe via [Stdlib.Mutex] — works across OCaml 5 domains and
    during module initialisation before any Eio scheduler exists.

    @since 0.4.0 *)

(** {1 Types} *)

type label = string * string

type metric_type =
  | Counter
  | Gauge
  | Histogram

type metric = {
  name : string;
  help : string;
  metric_type : metric_type;
  mutable value : float;
  labels : label list;
}

(** {1 Metric Registration} *)

val register_counter :
  name:string -> help:string -> ?labels:label list -> unit -> unit

val register_gauge :
  name:string -> help:string -> ?labels:label list -> unit -> unit

val register_histogram :
  name:string -> help:string -> ?labels:label list -> unit -> unit

(** {1 Metric Updates} *)

val inc_counter :
  string -> ?labels:label list -> ?delta:float -> unit -> unit

val set_gauge :
  string -> ?labels:label list -> float -> unit

val inc_gauge :
  string -> ?labels:label list -> ?delta:float -> unit -> unit

val dec_gauge :
  string -> ?labels:label list -> ?delta:float -> unit -> unit

val observe_histogram :
  string -> ?labels:label list -> float -> unit

(** {1 Metric Queries} *)

val get_metric_value :
  string -> ?labels:label list -> unit -> float option

val metric_value_or_zero :
  string -> ?labels:label list -> unit -> float

val metric_total : string -> float

(** {1 Metric Name Constants}

    Defined in [Prometheus_metric_names{,_b,_c}] (split for size).
    Re-exported here so callers continue to write [Prometheus.metric_X]. *)

include module type of Prometheus_metric_names
include module type of Prometheus_metric_names_b
include module type of Prometheus_metric_names_c

(** {1 Process monitoring} *)

val approximate_open_fd_count : unit -> int

val fd_warn_threshold : int

val set_tool_schema_stats : count:int -> approx_tokens:int -> unit

(** {1 Prometheus Export} *)

val type_to_string : metric_type -> string

val labels_to_string : label list -> string

val to_prometheus_text : unit -> string

(** {1 Convenience Functions} *)

val record_request : unit -> unit
val record_task_completed : unit -> unit
val record_task_failed : unit -> unit
val record_error : ?error_type:string -> unit -> unit
val set_active_agents : int -> unit
val set_pending_tasks : int -> unit
val reconcile_active_agents_gauge : string -> unit
val update_uptime : unit -> unit

(** {1 Initialisation}

    Called automatically at module load via [let () = init ()].
    Idempotent — safe to call again. *)
val init : unit -> unit

(** {1 Diagnostics — issue #10682}

    The most recent EDEADLK backtrace captured by [with_lock]. [None]
    until the first re-entrant lock failure. Set side-effectfully when
    [Stdlib.Mutex.lock metrics_mutex] raises [Sys_error]. The backtrace
    pinpoints the offending re-entrant caller without requiring repro. *)
val last_deadlock_backtrace_for_test : unit -> string option
