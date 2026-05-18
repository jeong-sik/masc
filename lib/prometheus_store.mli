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

(** Encode [(name, labels)] into the table key used by {!metrics}. Same
    function as [Prometheus_key.metric_key]; re-exported here so
    [Prometheus] can call the bare name after [include Prometheus_store].
    Without this declaration the [.ml] re-export at line 5 is dropped by
    the signature, and [prometheus.ml]'s [init] helper fails to compile
    with [Unbound value metric_key] (CI: Lint Build with warnings as
    errors). *)
val metric_key : string -> label list -> string

(** The shared metric table. Exposed so [Prometheus.init] can register
    built-in metrics via [Hashtbl.add metrics key {...}]; downstream
    consumers should prefer [register_counter] / [register_gauge] /
    [register_histogram] over reaching into the table directly. *)
val metrics : (string, metric) Hashtbl.t

(** Acquire the store mutex around [f] with a deadlock-backtrace guard.
    Exposed so [Prometheus.snapshot] (and any other compound operation
    in the facade) can serialize multi-step access to {!metrics} the
    same way [register_*] / [observe_histogram] do internally. *)
val with_lock : (unit -> 'a) -> 'a

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

(** The most recent EDEADLK backtrace captured by the store lock. [None]
    until the first re-entrant lock failure. *)
val last_deadlock_backtrace_for_test : unit -> string option
