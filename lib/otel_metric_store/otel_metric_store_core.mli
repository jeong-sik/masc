(** Mutex-backed Otel_metric_store metric store.

    This module owns the shared metric table and primitive
    register/update/query operations. [Otel_metric_store] includes this signature
    to keep the public facade stable while the godfile is decomposed. *)

type label = string * string

type metric_type =
  | Counter
  | Gauge
  | Histogram

type metric =
  { name : string
  ; help : string
  ; metric_type : metric_type
  ; mutable value : float
  ; labels : label list
  }

val register_counter : name:string -> help:string -> ?labels:label list -> unit -> unit

(** [declare_counter name] registers the unlabeled 0-cell for [name] and
    returns [name].  Used by metric-name modules
    ([let metric_x = declare_counter "masc_..."]) so every declared counter
    exports 0 from process start instead of staying invisible until its
    first increment — without this, Grafana cannot distinguish "never
    fired" (healthy) from "not wired" (broken).  Counters only; gauges and
    histograms have no honest pre-first-sample value and stay lazy. *)
val declare_counter : string -> string

val register_gauge : name:string -> help:string -> ?labels:label list -> unit -> unit
val register_histogram : name:string -> help:string -> ?labels:label list -> unit -> unit
val inc_counter : string -> ?labels:label list -> ?delta:float -> unit -> unit
val set_gauge : string -> ?labels:label list -> float -> unit
val inc_gauge : string -> ?labels:label list -> ?delta:float -> unit -> unit
val dec_gauge : string -> ?labels:label list -> ?delta:float -> unit -> unit
val register_histogram_buckets : string -> float list -> unit
(** Register histogram bucket upper bounds for a histogram metric.
    Once registered, [observe_histogram] will automatically increment
    the corresponding [name_bucket_total] counters with [le] labels
    alongside the existing [name_count_total] counter. *)

val observe_histogram : string -> ?labels:label list -> float -> unit
val get_metric_value : string -> ?labels:label list -> unit -> float option
val metric_value_or_zero : string -> ?labels:label list -> unit -> float
val metric_total : string -> float

(** Copy all current metric rows under the store lock. Returned records are
    detached from the mutable store so renderers can format without holding
    the lock. *)
val snapshot : unit -> metric list

(** The most recent EDEADLK backtrace captured by the store lock. [None]
    until the first re-entrant lock failure. *)
val last_deadlock_backtrace_for_test : unit -> string option
