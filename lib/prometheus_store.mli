(** Mutex-backed Prometheus metric store.

    This module owns the shared metric table and primitive
    register/update/query operations. [Prometheus] includes this signature
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
val register_gauge : name:string -> help:string -> ?labels:label list -> unit -> unit
val register_histogram : name:string -> help:string -> ?labels:label list -> unit -> unit
val inc_counter : string -> ?labels:label list -> ?delta:float -> unit -> unit
val set_gauge : string -> ?labels:label list -> float -> unit
val inc_gauge : string -> ?labels:label list -> ?delta:float -> unit -> unit
val dec_gauge : string -> ?labels:label list -> ?delta:float -> unit -> unit
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
